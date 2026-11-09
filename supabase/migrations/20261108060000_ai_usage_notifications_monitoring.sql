-- Fixes: H4 (no AI usage limit / cost tracking), H6 (no notifications), plus error monitoring required for operations.
-- Rollback: supabase/rollback/20261108060000_ai_usage_notifications_monitoring.down.sql

-- ---------- H4: AI metering and limits ----------
alter table public.companies add column if not exists ai_monthly_budget_usd numeric not null default 30 check (ai_monthly_budget_usd >= 0);
alter table public.companies add column if not exists ai_daily_user_limit int not null default 60 check (ai_daily_user_limit >= 0);

create table if not exists public.ai_usage (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  company_id uuid references public.companies(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  mode text not null,
  model text,
  input_tokens int not null default 0,
  output_tokens int not null default 0,
  cost_usd numeric(12, 6) not null default 0,
  ok boolean not null default true
);
create index if not exists ai_usage_company_at_idx on public.ai_usage (company_id, at desc);
create index if not exists ai_usage_user_at_idx on public.ai_usage (user_id, at desc);
alter table public.ai_usage enable row level security;
revoke all on public.ai_usage from anon, authenticated;
grant select on public.ai_usage to authenticated;
create policy ai_usage_read on public.ai_usage for select to authenticated
  using ((select public.is_super()) or (company_id = (select public.my_company()) and (select public.is_company_admin())));

-- called by the AI function (service role) BEFORE calling the model
create or replace function public.ai_quota_ok(cid uuid, uid uuid) returns json
language sql stable security definer set search_path = 'public' as $$
  with c as (select ai_monthly_budget_usd b, ai_daily_user_limit l from companies where id = cid),
       m as (select coalesce(sum(cost_usd), 0) spent from ai_usage where company_id = cid and at >= date_trunc('month', now())),
       u as (select count(*) n from ai_usage where user_id = uid and at >= now() - interval '1 day')
  select json_build_object(
    'ok', (select (m.spent < c.b) and (u.n < c.l) from c, m, u),
    'reason', (select case when m.spent >= c.b then 'MONTHLY_BUDGET' when u.n >= c.l then 'DAILY_USER_LIMIT' end from c, m, u),
    'month_spent_usd', (select spent from m), 'month_budget_usd', (select b from c),
    'user_requests_24h', (select n from u), 'user_daily_limit', (select l from c)) $$;

create or replace function public.record_ai_usage(cid uuid, uid uuid, p_mode text, p_model text, p_in int, p_out int, p_cost numeric, p_ok boolean)
returns void language sql security definer set search_path = 'public' as $$
  insert into ai_usage (company_id, user_id, mode, model, input_tokens, output_tokens, cost_usd, ok)
  values (cid, uid, p_mode, p_model, coalesce(p_in, 0), coalesce(p_out, 0), coalesce(p_cost, 0), p_ok) $$;

-- admin view of this month's AI spend
create or replace function public.ai_usage_summary(cid uuid) returns json
language sql stable security invoker set search_path = 'public' as $$
  select json_build_object(
    'month_spent_usd', coalesce((select sum(cost_usd) from ai_usage where company_id = cid and at >= date_trunc('month', now())), 0),
    'month_requests',  (select count(*) from ai_usage where company_id = cid and at >= date_trunc('month', now())),
    'budget_usd', (select ai_monthly_budget_usd from companies where id = cid),
    'daily_user_limit', (select ai_daily_user_limit from companies where id = cid)) $$;

-- ---------- H6: in-app notifications ----------
create table if not exists public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  company_id uuid references public.companies(id) on delete cascade,
  kind text not null,
  title text not null,
  body text,
  entity text,
  entity_id uuid,
  dedupe_key text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  emailed_at timestamptz,
  unique (user_id, dedupe_key)
);
create index if not exists notifications_user_unread_idx on public.notifications (user_id, created_at desc) where read_at is null;
create index if not exists notifications_company_idx on public.notifications (company_id);
alter table public.notifications enable row level security;
revoke all on public.notifications from anon, authenticated;
grant select, update (read_at) on public.notifications to authenticated;
create policy notif_read on public.notifications for select to authenticated using (user_id = (select auth.uid()));
create policy notif_mark on public.notifications for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Daily job: turns alerts into notifications for company admins + members of the record's department.
-- Thresholds: 30, 7, 1 days before expiry; hearings within 3 days; overdue invoices weekly.
create or replace function public.generate_notifications() returns int
language plpgsql security definer set search_path = 'public' as $$
declare n int;
begin
  if current_user in ('anon', 'authenticated') then raise exception 'غير مصرح'; end if;
  with items as (
    select v.company_id cid, v.department_id dep, 'expiry' kind, 'vehicles' ent, v.id eid,
           w.what || ': ' || v.plate tl, 'ينتهي في ' || w.dt::text body,
           'veh:' || v.id || ':' || w.f || ':' || case when w.dt - current_date <= 1 then 1 when w.dt - current_date <= 7 then 7 else 30 end dk
    from vehicles v cross join lateral (values ('reg', 'انتهاء الاستمارة', v.registration_expiry), ('ins', 'انتهاء التأمين', v.insurance_expiry), ('lic', 'انتهاء رخصة السائق', v.license_expiry)) w(f, what, dt)
    where v.deleted_at is null and w.dt is not null and w.dt <= current_date + 30
    union all
    select d.company_id, d.department_id, 'expiry', 'documents', d.id, 'وثيقة تنتهي: ' || d.name, 'تنتهي في ' || d.expiry_date::text || ' — ' || d.name,
           'doc:' || d.id || ':' || case when d.expiry_date - current_date <= 1 then 1 when d.expiry_date - current_date <= 7 then 7 else 30 end
    from documents d where d.deleted_at is null and d.expiry_date is not null and d.expiry_date <= current_date + 30
    union all
    select l.company_id, l.department_id, 'hearing', 'legal_cases', l.id, 'جلسة قريبة: ' || l.title, 'الجلسة في ' || l.next_hearing::text,
           'hear:' || l.id || ':' || l.next_hearing
    from legal_cases l where l.deleted_at is null and l.status <> 'مغلقة' and l.next_hearing between current_date and current_date + 3
    union all
    select i.company_id, i.department_id, 'overdue', 'invoices', i.id, 'فاتورة متأخرة: ' || i.number, 'استحقت في ' || i.due_date::text || ' — ' || coalesce(i.amount, 0) || ' ر.س',
           'inv:' || i.id || ':' || to_char(current_date, 'IYYY-IW')
    from invoices i where i.deleted_at is null and i.status <> 'مدفوعة' and i.due_date < current_date
  ), targets as (
    select it.*, p.id uid from items it join companies c on c.id = it.cid and c.active and c.deleted_at is null
    join profiles p on p.company_id = it.cid and p.status = 'active' and (p.role = 'admin' or (it.dep is not null and p.department_id = it.dep))
  )
  insert into notifications (user_id, company_id, kind, title, body, entity, entity_id, dedupe_key)
  select uid, cid, kind, tl, body, ent, eid, dk from targets
  on conflict (user_id, dedupe_key) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- Monitoring ----------
create table if not exists public.system_events (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  level text not null check (level in ('info', 'warn', 'error')),
  source text not null,                 -- web | edge:yaqen-ai | cron | db
  message text not null,
  context jsonb,
  company_id uuid,
  user_id uuid
);
create index if not exists system_events_at_idx on public.system_events (at desc);
create index if not exists system_events_level_idx on public.system_events (level, at desc);
alter table public.system_events enable row level security;
revoke all on public.system_events from anon, authenticated;
grant select on public.system_events to authenticated;
create policy sysev_read on public.system_events for select to authenticated using ((select public.is_super()));

-- browser errors: authenticated users only, max 30 per user per hour, message truncated
create or replace function public.log_client_error(msg text, ctx jsonb default null) returns void
language plpgsql security definer set search_path = 'public' as $$
begin
  if auth.uid() is null then return; end if;
  if (select count(*) from system_events where user_id = auth.uid() and source = 'web' and at > now() - interval '1 hour') >= 30 then return; end if;
  insert into system_events (level, source, message, context, company_id, user_id)
  values ('error', 'web', left(coalesce(msg, ''), 1000), (select jsonb_object_agg(k, left(v::text, 500)) from jsonb_each(coalesce(ctx, '{}'::jsonb)) as e(k, v)),
          public.my_company(), auth.uid());
end $$;

-- uptime probe: no data, just proves API + DB answer
create or replace function public.health() returns json language sql stable set search_path = '' as $$
  select json_build_object('ok', true, 'at', now()) $$;

-- ---------- scheduler (Supabase pg_cron). Skipped where pg_cron is not installable (local staging). ----------
do $$ begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('yaqen-daily-notifications', '0 4 * * *', 'select public.generate_notifications()');   -- 07:00 Riyadh
    perform cron.schedule('yaqen-purge-deleted', '30 4 * * *', 'select public.purge_deleted(interval ''30 days'')');
    perform cron.schedule('yaqen-trim-events', '0 5 * * 0', $c$delete from public.system_events where at < now() - interval '90 days'; delete from public.code_lookup_attempts where at < now() - interval '2 days'$c$);
  else
    raise notice 'pg_cron not available: schedule generate_notifications / purge_deleted externally';
  end if;
end $$;

do $$ declare f text; begin
  foreach f in array array['ai_usage_summary(uuid)','log_client_error(text,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
revoke execute on function public.ai_quota_ok(uuid, uuid), public.record_ai_usage(uuid, uuid, text, text, int, int, numeric, boolean),
  public.generate_notifications() from public, anon, authenticated;
grant execute on function public.ai_quota_ok(uuid, uuid), public.record_ai_usage(uuid, uuid, text, text, int, int, numeric, boolean) to service_role;
grant execute on function public.health() to anon, authenticated;
