-- Yaqen MCP connector, v1 (read-only) + executive report engine.
-- Design: docs/mcp/02_ARCHITECTURE.md. Every tool is a SECURITY INVOKER function, so the caller's RLS applies to
-- every row; the company always comes from my_company(), never from an input. Rollback: supabase/rollback/20261109000000_mcp_readonly_connector.down.sql
-- Depends on migrations 20261108010000..080000 (hardening), which must be deployed first.

------------------------------------------------------------------------------------------------
-- 1. OAuth tokens are read-only, enforced by the database (gap G1)
------------------------------------------------------------------------------------------------
-- A token issued by Supabase's OAuth server to an AI client carries a client_id claim. Such a token must never write.
create or replace function public.is_oauth_request() returns boolean language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ? 'client_id', false) $$;

-- (a) PostgREST pre-request hook: an OAuth token may only send GET/HEAD (GET = read-only transaction in PostgREST).
create or replace function public.pre_request() returns void language plpgsql stable set search_path = '' as $$
begin
  if public.is_oauth_request() and coalesce(current_setting('request.method', true), '') not in ('GET', 'HEAD') then
    raise exception 'OAUTH_READ_ONLY' using errcode = '42501', hint = 'Tokens issued to AI connectors can only read.';
  end if;
end $$;
grant execute on function public.pre_request() to anon, authenticated, service_role;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    execute 'alter role authenticator set pgrst.db_pre_request = ''public.pre_request''';
    perform pg_notify('pgrst', 'reload config');
  end if;
end $$;

-- (b) restrictive policies: no insert/update/delete with an OAuth token, whatever the permissive policies allow.
do $$ declare t text; begin
  foreach t in array array['companies','departments','profiles','projects','invoices','vehicles','documents','legal_cases','requests',
                           'manager_notes','rooms','room_members','room_messages','notifications'] loop
    execute format('drop policy if exists oauth_no_insert on public.%I', t);
    execute format('drop policy if exists oauth_no_update on public.%I', t);
    execute format('drop policy if exists oauth_no_delete on public.%I', t);
    execute format('create policy oauth_no_insert on public.%I as restrictive for insert to authenticated with check (not (select public.is_oauth_request()))', t);
    execute format('create policy oauth_no_update on public.%I as restrictive for update to authenticated using (not (select public.is_oauth_request())) with check (not (select public.is_oauth_request()))', t);
    execute format('create policy oauth_no_delete on public.%I as restrictive for delete to authenticated using (not (select public.is_oauth_request()))', t);
  end loop;
end $$;
drop policy if exists oauth_no_insert on storage.objects;
drop policy if exists oauth_no_update on storage.objects;
drop policy if exists oauth_no_delete on storage.objects;
create policy oauth_no_insert on storage.objects as restrictive for insert to authenticated with check (not (select public.is_oauth_request()));
create policy oauth_no_update on storage.objects as restrictive for update to authenticated using (not (select public.is_oauth_request()));
create policy oauth_no_delete on storage.objects as restrictive for delete to authenticated using (not (select public.is_oauth_request()));

-- (c) the hook must actually be installed; tools refuse to run otherwise (a forgotten deploy step fails closed)
create or replace function public.mcp_selfcheck() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from pg_catalog.pg_roles r, unnest(coalesce(r.rolconfig, '{}')) c
                 where r.rolname = 'authenticator' and c = 'pgrst.db_pre_request=public.pre_request') $$;
revoke execute on function public.mcp_selfcheck() from public, anon;
grant execute on function public.mcp_selfcheck() to authenticated, service_role;

------------------------------------------------------------------------------------------------
-- 2. Guard: live session, active company account, not a platform admin (gaps G2, G5)
------------------------------------------------------------------------------------------------
create or replace function public.mcp_guard() returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_sid uuid; v_role text; v_status text; v_cid uuid;
begin
  if v_uid is null then raise exception 'MCP:NOT_AUTHENTICATED' using errcode = '28000'; end if;
  if not public.mcp_selfcheck() then raise exception 'MCP:CONFIG_INCOMPLETE' using errcode = '55000'; end if;
  begin v_sid := nullif(auth.jwt() ->> 'session_id', '')::uuid; exception when others then v_sid := null; end;
  if v_sid is null or not exists (select 1 from auth.sessions s where s.id = v_sid and s.user_id = v_uid
                                   and (s.not_after is null or s.not_after > now())) then
    raise exception 'MCP:SESSION_REVOKED' using errcode = '28000';
  end if;
  select p.role, p.status, p.company_id into v_role, v_status, v_cid from public.profiles p where p.id = v_uid;
  if v_role = 'super_admin' then raise exception 'MCP:PLATFORM_ADMIN_NOT_SUPPORTED' using errcode = '42501'; end if;
  if v_status is distinct from 'active' or v_cid is null or public.my_company() is null then
    raise exception 'MCP:ACCOUNT_INACTIVE' using errcode = '42501';
  end if;
  return v_cid;
end $$;
revoke execute on function public.mcp_guard() from public, anon;
grant execute on function public.mcp_guard() to authenticated;

-- shared helpers
create or replace function public.mcp_clamp(v int, lo int, hi int, dflt int) returns int language sql immutable as $$
  select least(greatest(coalesce(v, dflt), lo), hi) $$;
create or replace function public.mcp_text(v text, n int default 200) returns text language sql immutable as $$
  select case when v is null then null else left(regexp_replace(v, '[[:cntrl:]]', ' ', 'g'), n) end $$;

------------------------------------------------------------------------------------------------
-- 3. Usage log + rate limit (gap G3). Written only by the edge function (service role).
------------------------------------------------------------------------------------------------
create table if not exists public.mcp_usage (
  id bigserial primary key, at timestamptz not null default now(), user_id uuid not null, company_id uuid,
  tool text not null, ok boolean, ms int, result_rows int, error_code text);
create index if not exists mcp_usage_user_at on public.mcp_usage (user_id, at desc);
create index if not exists mcp_usage_company_at on public.mcp_usage (company_id, at desc);
alter table public.mcp_usage enable row level security;
revoke all on public.mcp_usage from anon, authenticated;
grant select on public.mcp_usage to authenticated;
drop policy if exists mcp_usage_admin_read on public.mcp_usage;
create policy mcp_usage_admin_read on public.mcp_usage for select to authenticated
  using (company_id = (select public.my_company()) and (select public.is_company_admin()));

create or replace function public.mcp_begin(p_user uuid, p_tool text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_cid uuid; v_min int; v_day int; v_id bigint;
begin
  select company_id into v_cid from public.profiles where id = p_user;
  select count(*) filter (where at > now() - interval '1 minute'), count(*) into v_min, v_day
    from public.mcp_usage where user_id = p_user and at > now() - interval '1 day';
  if v_min >= 30 then return jsonb_build_object('ok', false, 'reason', 'RATE_LIMITED_MINUTE'); end if;
  if v_day >= 600 then return jsonb_build_object('ok', false, 'reason', 'RATE_LIMITED_DAY'); end if;
  insert into public.mcp_usage (user_id, company_id, tool) values (p_user, v_cid, left(p_tool, 64)) returning id into v_id;
  return jsonb_build_object('ok', true, 'call_id', v_id);
end $$;
create or replace function public.mcp_end(p_call bigint, p_ok boolean, p_ms int, p_rows int, p_error text) returns void
language sql security definer set search_path = '' as $$
  update public.mcp_usage set ok = p_ok, ms = p_ms, result_rows = p_rows, error_code = left(p_error, 64) where id = p_call $$;
revoke execute on function public.mcp_begin(uuid, text) from public, anon, authenticated;
revoke execute on function public.mcp_end(bigint, boolean, int, int, text) from public, anon, authenticated;
grant execute on function public.mcp_begin(uuid, text) to service_role;
grant execute on function public.mcp_end(bigint, boolean, int, int, text) to service_role;

------------------------------------------------------------------------------------------------
-- 4. Report engine: invoice comparison between two periods (used by the UI and by MCP)
------------------------------------------------------------------------------------------------
-- What Yaqen records today (docs/mcp/01_DISCOVERY.md): invoices with kind (صادرة = issued to clients, واردة = from suppliers),
-- amount, due_date and status. There is no issue date, no expense ledger, no payroll and no project link, so NET PROFIT IS NOT
-- COMPUTED. The report states this and shows what can be computed exactly, on a due-date basis.
create or replace function public.report_profit_comparison(a_from date, a_to date, b_from date, b_to date) returns jsonb
language plpgsql stable security invoker set search_path = 'public' as $$
declare cid uuid := public.my_company(); res jsonb; pa jsonb; pb jsonb;
begin
  if cid is null then raise exception 'REPORT:NO_COMPANY' using errcode = '42501'; end if;
  if a_from is null or a_to is null or b_from is null or b_to is null or a_from > a_to or b_from > b_to
     or a_to - a_from > 366 or b_to - b_from > 366 then
    raise exception 'REPORT:INVALID_PERIOD' using errcode = '22023';
  end if;
  select jsonb_object_agg(k, v) into pa from (
    select 'from' k, to_jsonb(a_from) v union all select 'to', to_jsonb(a_to)) x;
  select jsonb_object_agg(k, v) into pb from (
    select 'from' k, to_jsonb(b_from) v union all select 'to', to_jsonb(b_to)) x;
  with p(label, f, t) as (values ('a', a_from, a_to), ('b', b_from, b_to)),
  inv as (select i.* from invoices i where i.company_id = cid),
  per as (
    select p.label,
      coalesce(sum(i.amount) filter (where i.kind = 'صادرة'), 0) revenue,
      coalesce(sum(i.amount) filter (where i.kind = 'واردة'), 0) supplier,
      count(*) filter (where i.kind = 'صادرة') revenue_n,
      count(*) filter (where i.kind = 'واردة') supplier_n,
      coalesce(sum(i.amount) filter (where i.kind = 'صادرة' and i.status = 'مدفوعة'), 0) collected,
      coalesce(sum(i.amount) filter (where i.kind = 'صادرة' and i.status <> 'مدفوعة'), 0) outstanding,
      coalesce(sum(i.amount) filter (where i.kind = 'واردة' and i.status = 'مدفوعة'), 0) supplier_paid
    from p left join inv i on i.due_date between p.f and p.t
    group by p.label),
  parties as (
    select p.label, jsonb_agg(jsonb_build_object('party', public.mcp_text(x.party, 120), 'amount', x.amt, 'count', x.n) order by x.amt desc) top
    from p cross join lateral (
      select i.party, sum(i.amount) amt, count(*) n from inv i
      where i.kind = 'صادرة' and i.due_date between p.f and p.t group by i.party order by sum(i.amount) desc limit 5) x
    group by p.label),
  depts as (
    select p.label, jsonb_agg(jsonb_build_object('department', d.name, 'revenue', x.rev, 'supplier', x.sup) order by d.name) by_dept
    from p cross join lateral (
      select i.department_id, coalesce(sum(i.amount) filter (where i.kind = 'صادرة'), 0) rev,
             coalesce(sum(i.amount) filter (where i.kind = 'واردة'), 0) sup
      from inv i where i.due_date between p.f and p.t group by i.department_id) x
    left join departments d on d.id = x.department_id
    group by p.label)
  select jsonb_build_object(
    'report', 'profit_comparison',
    'as_of', now(),
    'data_last_updated', (select max(updated_at) from inv),
    'basis', 'invoice_due_date',
    'basis_ar', 'حسب تاريخ استحقاق الفواتير المسجلة في يقين',
    'currency', 'SAR',
    'periods', jsonb_build_object(
      'a', pa || (select jsonb_build_object('revenue_invoiced', revenue, 'supplier_invoiced', supplier, 'net_invoiced', revenue - supplier,
                   'revenue_count', revenue_n, 'supplier_count', supplier_n, 'collected', collected, 'outstanding', outstanding,
                   'supplier_paid', supplier_paid,
                   'top_clients', coalesce((select top from parties where label = 'a'), '[]'),
                   'by_department', coalesce((select by_dept from depts where label = 'a'), '[]')) from per where label = 'a'),
      'b', pb || (select jsonb_build_object('revenue_invoiced', revenue, 'supplier_invoiced', supplier, 'net_invoiced', revenue - supplier,
                   'revenue_count', revenue_n, 'supplier_count', supplier_n, 'collected', collected, 'outstanding', outstanding,
                   'supplier_paid', supplier_paid,
                   'top_clients', coalesce((select top from parties where label = 'b'), '[]'),
                   'by_department', coalesce((select by_dept from depts where label = 'b'), '[]')) from per where label = 'b')),
    'excluded_no_due_date', (select count(*) from inv where due_date is null),
    'net_profit', jsonb_build_object('available', false,
       'reasons_ar', jsonb_build_array(
         'لا يوجد في يقين دفتر مصروفات ولا رواتب ولا تكاليف مشاريع.',
         'الفواتير بدون تاريخ إصدار، فتُنسب للفترة حسب تاريخ الاستحقاق فقط.',
         'الفواتير غير مربوطة بالمشاريع، فلا يمكن حساب ربحية مشروع.'),
       'shown_instead_ar', 'الفرق بين الفواتير الصادرة والواردة المستحقة في الفترة (صافي الفوترة)، وهو ليس ربحاً محاسبياً.')
  ) into res;
  -- changes (b = comparison base, a = current): absolute and percent; percent is null when the base is zero
  res := jsonb_set(res, '{change}', (
    select jsonb_object_agg(k, jsonb_build_object('abs', av - bv, 'pct', case when bv = 0 then null else round((av - bv) / abs(bv) * 100, 1) end))
    from (select k, (res #>> array['periods','a',k])::numeric av, (res #>> array['periods','b',k])::numeric bv
          from unnest(array['revenue_invoiced','supplier_invoiced','net_invoiced','collected','outstanding']) k) z));
  return res;
end $$;
grant execute on function public.report_profit_comparison(date, date, date, date) to authenticated;

------------------------------------------------------------------------------------------------
-- 5. MCP tools (read-only). Each: guard -> bounded query under the caller's RLS -> JSON with as_of + notes.
------------------------------------------------------------------------------------------------
create or replace function public.mcp_company_overview() returns jsonb language plpgsql stable security invoker set search_path = 'public' as $$
declare cid uuid := public.mcp_guard();
begin
  return jsonb_build_object(
    'company', (select name from companies where id = cid),
    'as_of', now(),
    'scope_ar', case when public.is_company_admin() then 'كل الشركة' else 'قسمك فقط (حسب صلاحياتك)' end,
    'totals', public.dashboard_stats(cid)::jsonb,
    'alerts_by_kind', (select coalesce(jsonb_object_agg(kind, n), '{}') from (select kind, count(*) n from public.company_alerts(cid, 500) group by kind) x),
    'alerts_high', (select count(*) from public.company_alerts(cid, 500) where level = 'h'),
    'notes_ar', jsonb_build_array('الأرقام من سجلات يقين كما هي وقت الطلب.', 'المستحقات = مجموع الفواتير الصادرة غير المدفوعة.'));
end $$;

create or replace function public.mcp_projects(p_status text default null, p_late_only boolean default false, p_limit int default 20, p_offset int default 0)
returns jsonb language plpgsql stable security invoker set search_path = 'public' as $$
declare cid uuid := public.mcp_guard(); lim int := public.mcp_clamp(p_limit, 1, 50, 20); off int := public.mcp_clamp(p_offset, 0, 100000, 0);
begin
  return (with base as (
      select p.*, case when p.status <> 'مكتمل' and p.end_date < current_date then current_date - p.end_date end days_late
      from projects p where p.company_id = cid
        and (p_status is null or p.status = p_status)
        and (not coalesce(p_late_only, false) or (p.status <> 'مكتمل' and (p.status = 'متأخر' or p.end_date < current_date))))
    select jsonb_build_object('as_of', now(), 'total', (select count(*) from base), 'limit', lim, 'offset', off,
      'summary', (select jsonb_build_object('count', count(*), 'avg_progress', round(avg(progress)), 'contract_value_total', sum(contract_value),
                    'missing_contract_value', count(*) filter (where contract_value is null), 'missing_end_date', count(*) filter (where end_date is null)) from base),
      'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', public.mcp_text(name, 150), 'client', public.mcp_text(client, 100), 'po_number', po_number,
                 'status', status, 'progress_pct', progress, 'contract_value', contract_value, 'start_date', start_date, 'end_date', end_date,
                 'days_late', days_late) order by days_late desc nulls last, end_date nulls last, id)
               from (select * from base order by days_late desc nulls last, end_date nulls last, id limit lim offset off) q), '[]'),
      'notes_ar', jsonb_build_array('نسبة الإنجاز كما أدخلها الموظف، وليست محسوبة.', 'أسباب التأخير غير مسجلة في يقين.',
                                     'لا توجد ميزانيات أو تكاليف للمشاريع، فلا يمكن معرفة تجاوز الميزانية أو الربحية.')));
end $$;

create or replace function public.mcp_project_detail(p_project_id uuid) returns jsonb language plpgsql stable security invoker set search_path = 'public' as $$
declare cid uuid := public.mcp_guard(); r projects;
begin
  select * into r from projects where id = p_project_id and company_id = cid;
  if not found then return jsonb_build_object('found', false, 'message_ar', 'المشروع غير موجود أو ليس ضمن صلاحياتك.'); end if;
  return jsonb_build_object('found', true, 'as_of', now(), 'data_last_updated', r.updated_at,
    'project', jsonb_build_object('id', r.id, 'name', public.mcp_text(r.name, 150), 'client', public.mcp_text(r.client, 100), 'po_number', r.po_number,
      'status', r.status, 'progress_pct', r.progress, 'contract_value', r.contract_value, 'start_date', r.start_date, 'end_date', r.end_date,
      'days_late', case when r.status <> 'مكتمل' and r.end_date < current_date then current_date - r.end_date end,
      'department', (select name from departments where id = r.department_id),
      'notes', jsonb_build_object('untrusted_text', public.mcp_text(r.notes, 500))),
    'unavailable_ar', jsonb_build_array('الفواتير والتكاليف المرتبطة بالمشروع: غير متاحة (لا يوجد ربط في يقين).', 'أسباب التأخير: غير مسجلة.'));
end $$;

create or replace function public.mcp_invoices(p_kind text default null, p_min_days_overdue int default null, p_status text default null, p_limit int default 20, p_offset int default 0)
returns jsonb language plpgsql stable security invoker set search_path = 'public' as $$
declare cid uuid := public.mcp_guard(); lim int := public.mcp_clamp(p_limit, 1, 50, 20); off int := public.mcp_clamp(p_offset, 0, 100000, 0);
begin
  if p_kind is not null and p_kind not in ('صادرة', 'واردة') then raise exception 'MCP:INVALID_ARGUMENT' using errcode = '22023'; end if;
  return (with base as (
      select i.*, case when i.status <> 'مدفوعة' and i.due_date < current_date then current_date - i.due_date end days_overdue
      from invoices i where i.company_id = cid
        and (p_kind is null or i.kind = p_kind) and (p_status is null or i.status = p_status)
        and (p_min_days_overdue is null or (i.status <> 'مدفوعة' and i.due_date <= current_date - greatest(p_min_days_overdue, 0))))
    select jsonb_build_object('as_of', now(), 'total', (select count(*) from base), 'limit', lim, 'offset', off,
      'summary', (select jsonb_build_object('count', count(*), 'amount_total', coalesce(sum(amount), 0),
                   'unpaid_total', coalesce(sum(amount) filter (where status <> 'مدفوعة'), 0),
                   'aging', jsonb_build_object('1_30', coalesce(sum(amount) filter (where days_overdue between 1 and 30), 0),
                                               '31_60', coalesce(sum(amount) filter (where days_overdue between 31 and 60), 0),
                                               '61_90', coalesce(sum(amount) filter (where days_overdue between 61 and 90), 0),
                                               'over_90', coalesce(sum(amount) filter (where days_overdue > 90), 0)),
                   'missing_due_date', count(*) filter (where due_date is null)) from base),
      'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'number', public.mcp_text(number, 60), 'kind', kind, 'party', public.mcp_text(party, 120),
                 'amount', amount, 'due_date', due_date, 'status', status, 'days_overdue', days_overdue) order by days_overdue desc nulls last, due_date, id)
               from (select * from base order by days_overdue desc nulls last, due_date, id limit lim offset off) q), '[]'),
      'notes_ar', jsonb_build_array('التأخير محسوب من تاريخ الاستحقاق وحالة "مدفوعة" كما سجلها الموظف.', 'العملة: ريال سعودي، بدون فصل الضريبة.')));
end $$;

create or replace function public.mcp_fleet(p_status text default null, p_location text default null, p_limit int default 20, p_offset int default 0)
returns jsonb language plpgsql stable security invoker set search_path = 'public' as $$
declare cid uuid := public.mcp_guard(); lim int := public.mcp_clamp(p_limit, 1, 50, 20); off int := public.mcp_clamp(p_offset, 0, 100000, 0);
  loc text := nullif(btrim(public.mcp_text(p_location, 80)), '');
begin
  return (with base as (
      select v.* from vehicles v where v.company_id = cid and (p_status is null or v.status = p_status)
        and (loc is null or v.location ilike '%' || replace(replace(loc, '%', ''), '_', '') || '%'))
    select jsonb_build_object('as_of', now(), 'total', (select count(*) from base), 'limit', lim, 'offset', off,
      'by_location', (select coalesce(jsonb_agg(jsonb_build_object('location', coalesce(public.mcp_text(location, 100), 'غير محدد'), 'status_counts', sc) order by location nulls last), '[]')
                      from (select location, jsonb_object_agg(status, n) sc from (select location, status, count(*) n from base group by 1, 2) x group by location) y),
      'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'plate', plate, 'kind', public.mcp_text(kind, 60), 'model', public.mcp_text(model, 80),
                 'status', status, 'location', public.mcp_text(location, 100), 'registration_expiry', registration_expiry, 'insurance_expiry', insurance_expiry,
                 'license_expiry', license_expiry) order by status desc, plate, id)
               from (select * from base order by status desc, plate, id limit lim offset off) q), '[]'),
      'notes_ar', jsonb_build_array('الموقع نص كما كتبه الموظف، وليس كياناً مستقلاً.', 'تكاليف المعدات غير مسجلة في يقين.')));
end $$;

create or replace function public.mcp_expiring(p_days int default 30) returns jsonb language plpgsql stable security invoker set search_path = 'public' as $$
declare cid uuid := public.mcp_guard(); d int := public.mcp_clamp(p_days, 1, 365, 30);
begin
  return jsonb_build_object('as_of', now(), 'within_days', d,
    'items', coalesce((select jsonb_agg(jsonb_build_object('kind', a.kind, 'entity', a.entity, 'entity_id', a.entity_id, 'label', public.mcp_text(a.label, 160),
               'due', a.due, 'days', a.days, 'level', a.level) order by a.days, a.entity_id)
             from public.company_alerts(cid, 500) a where a.kind in ('expiry', 'hearing') and a.days <= d), '[]'),
    'notes_ar', jsonb_build_array('يشمل: الاستمارات والتأمين ورخص السائقين والوثائق المنتهية أو التي تنتهي خلال المدة، وجلسات القضايا القريبة.',
                                   'القيم السالبة في days تعني أنها منتهية بالفعل.'));
end $$;

create or replace function public.mcp_people(p_department text default null, p_limit int default 20, p_offset int default 0)
returns jsonb language plpgsql stable security invoker set search_path = 'public' as $$
declare cid uuid := public.mcp_guard(); lim int := public.mcp_clamp(p_limit, 1, 50, 20); off int := public.mcp_clamp(p_offset, 0, 100000, 0);
begin
  return (with base as (
      select p.id, p.full_name, p.job_title, p.role, d.name dept from profiles p left join departments d on d.id = p.department_id
      where p.company_id = cid and p.status = 'active' and (p_department is null or d.name = p_department))
    select jsonb_build_object('as_of', now(), 'total', (select count(*) from base), 'limit', lim, 'offset', off,
      'by_department', (select coalesce(jsonb_object_agg(coalesce(dept, 'بدون قسم'), n), '{}') from (select dept, count(*) n from base group by dept) x),
      'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', public.mcp_text(full_name, 100), 'job_title', public.mcp_text(job_title, 100),
                 'department', dept, 'is_manager', role = 'admin') order by full_name, id)
               from (select * from base order by full_name, id limit lim offset off) q), '[]'),
      'notes_ar', jsonb_build_array('لا تُعرض أرقام الجوال أو البريد عبر الموصل.')));
end $$;

create or replace function public.mcp_search(p_query text, p_limit int default 10) returns jsonb language plpgsql stable security invoker set search_path = 'public' as $$
declare cid uuid := public.mcp_guard(); lim int := public.mcp_clamp(p_limit, 1, 20, 10);
  q text := btrim(replace(replace(replace(coalesce(public.mcp_text(p_query, 80), ''), '\', ''), '%', ''), '_', ' '));
begin
  if length(q) < 2 then raise exception 'MCP:QUERY_TOO_SHORT' using errcode = '22023'; end if;
  return jsonb_build_object('as_of', now(), 'query', q,
    'projects', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', public.mcp_text(name, 150), 'status', status, 'progress_pct', progress))
                 from (select * from projects where company_id = cid and (name ilike '%'||q||'%' or po_number ilike '%'||q||'%' or client ilike '%'||q||'%') order by name, id limit lim) x), '[]'),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'plate', plate, 'kind', public.mcp_text(kind, 60), 'status', status, 'location', public.mcp_text(location, 100)))
                 from (select * from vehicles where company_id = cid and (plate ilike '%'||q||'%' or driver_name ilike '%'||q||'%' or location ilike '%'||q||'%') order by plate, id limit lim) x), '[]'),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'number', public.mcp_text(number, 60), 'kind', kind, 'party', public.mcp_text(party, 120), 'amount', amount, 'status', status, 'due_date', due_date))
                 from (select * from invoices where company_id = cid and (number ilike '%'||q||'%' or party ilike '%'||q||'%') order by due_date desc nulls last, id limit lim) x), '[]'),
    'documents', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', public.mcp_text(name, 150), 'doc_type', public.mcp_text(doc_type, 60), 'expiry_date', expiry_date))
                 from (select * from documents where company_id = cid and (name ilike '%'||q||'%' or doc_type ilike '%'||q||'%') order by name, id limit lim) x), '[]'),
    'people', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', public.mcp_text(full_name, 100), 'job_title', public.mcp_text(job_title, 100)))
                 from (select * from profiles where company_id = cid and status = 'active' and (full_name ilike '%'||q||'%' or job_title ilike '%'||q||'%') order by full_name, id limit lim) x), '[]'));
end $$;

create or replace function public.mcp_notes_rooms(p_limit int default 20) returns jsonb language plpgsql stable security invoker set search_path = 'public' as $$
declare cid uuid := public.mcp_guard(); lim int := public.mcp_clamp(p_limit, 1, 50, 20);
begin
  return jsonb_build_object('as_of', now(),
    'open_notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'subject', public.mcp_text(n.subject, 150), 'department', d.name, 'status', n.status,
                     'due_date', n.due_date, 'has_reply', n.reply is not null, 'created_at', n.created_at) order by n.due_date nulls last, n.id)
                   from (select * from manager_notes where company_id = cid and status = 'مفتوحة' order by due_date nulls last, id limit lim) n
                   left join departments d on d.id = n.department_id), '[]'),
    'rooms', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'title', public.mcp_text(r.title, 150), 'status', r.status, 'last_message_at', r.last_message_at,
                 'messages', (select count(*) from room_messages m where m.room_id = r.id)) order by r.last_message_at desc nulls last, r.id)
               from (select * from rooms where company_id = cid order by last_message_at desc nulls last, id limit lim) r), '[]'),
    'notes_ar', jsonb_build_array('نصوص رسائل الغرف لا تُعرض عبر الموصل في هذه النسخة، فقط العدد وآخر نشاط.'));
end $$;

create or replace function public.mcp_profit_comparison(p_a_from date, p_a_to date, p_b_from date, p_b_to date) returns jsonb
language plpgsql stable security invoker set search_path = 'public' as $$
begin
  perform public.mcp_guard();
  return public.report_profit_comparison(p_a_from, p_a_to, p_b_from, p_b_to);
end $$;

do $$ declare f text; begin
  foreach f in array array['mcp_company_overview()', 'mcp_projects(text, boolean, int, int)', 'mcp_project_detail(uuid)',
    'mcp_invoices(text, int, text, int, int)', 'mcp_fleet(text, text, int, int)', 'mcp_expiring(int)', 'mcp_people(text, int, int)',
    'mcp_search(text, int)', 'mcp_notes_rooms(int)', 'mcp_profit_comparison(date, date, date, date)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
