-- Fixes: H2 (dashboard/alerts computed in the browser from whole tables; API caps at 1,000 rows -> wrong totals)
--        H4 part (AI read only the first 300 rows per table -> decisions on partial data).
-- All functions are SECURITY INVOKER: they run under the caller's RLS, so an employee only gets their department.
-- Rollback: supabase/rollback/20261108050000_server_side_queries.down.sql

create or replace function public.dashboard_stats(cid uuid) returns json
language sql stable security invoker set search_path = 'public' as $$
  select json_build_object(
    'employees',        (select count(*) from profiles where company_id = cid and status = 'active'),
    'pending_members',  (select count(*) from profiles where company_id = cid and status = 'pending'),
    'departments',      (select count(*) from departments where company_id = cid),
    'vehicles_total',   (select count(*) from vehicles where company_id = cid),
    'vehicles_active',  (select count(*) from vehicles where company_id = cid and status = 'شغالة'),
    'projects_running', (select count(*) from projects where company_id = cid and status <> 'مكتمل'),
    'projects_avg_progress', (select coalesce(round(avg(progress)), 0) from projects where company_id = cid and status <> 'مكتمل'),
    'cases_open',       (select count(*) from legal_cases where company_id = cid and status <> 'مغلقة'),
    'receivables',      (select coalesce(sum(amount), 0) from invoices where company_id = cid and kind = 'صادرة' and status <> 'مدفوعة'),
    'invoices_overdue', (select count(*) from invoices where company_id = cid and status <> 'مدفوعة' and due_date < current_date),
    'notes_open',       (select count(*) from manager_notes where company_id = cid and status = 'مفتوحة'),
    'rooms_open',       (select count(*) from rooms where company_id = cid and status = 'مفتوحة')
  ) $$;

-- alerts: same rules the browser used, computed in the database over ALL rows
create or replace function public.company_alerts(cid uuid, lim int default 100)
returns table(level text, kind text, entity text, entity_id uuid, department_id uuid, label text, due date, days int, amount numeric)
language sql stable security invoker set search_path = 'public' as $$
  with a as (
    select case when x.d < 0 or x.d <= 7 then 'h' else 'm' end lvl, 'expiry' k, 'vehicles' e, v.id, v.department_id dep,
           v.plate || ' — ' || x.what lab, x.dt due, x.d dd, null::numeric amt
    from vehicles v cross join lateral (values ('انتهاء الاستمارة', v.registration_expiry), ('انتهاء التأمين', v.insurance_expiry), ('انتهاء رخصة السائق', v.license_expiry)) w(what, dt)
    cross join lateral (select w.what, w.dt, (w.dt - current_date) d) x
    where v.company_id = cid and w.dt is not null and w.dt <= current_date + 30
    union all
    select case when d.expiry_date - current_date <= 7 then 'h' else 'm' end, 'expiry', 'documents', d.id, d.department_id,
           d.name, d.expiry_date, d.expiry_date - current_date, null
    from documents d where d.company_id = cid and d.expiry_date is not null and d.expiry_date <= current_date + 30
    union all
    select case when l.next_hearing - current_date <= 3 then 'h' else 'm' end, 'hearing', 'legal_cases', l.id, l.department_id,
           l.title, l.next_hearing, l.next_hearing - current_date, null
    from legal_cases l where l.company_id = cid and l.status <> 'مغلقة' and l.next_hearing between current_date and current_date + 14
    union all
    select 'h', 'overdue', 'invoices', i.id, i.department_id, i.number || coalesce(' — ' || i.party, ''), i.due_date, i.due_date - current_date, i.amount
    from invoices i where i.company_id = cid and i.status <> 'مدفوعة' and i.due_date < current_date
    union all
    select 'h', 'late', 'projects', p.id, p.department_id, p.name, p.end_date, p.end_date - current_date, p.contract_value
    from projects p where p.company_id = cid and p.status <> 'مكتمل' and (p.status = 'متأخر' or p.end_date < current_date)
    union all
    select 'm', 'stopped', 'vehicles', v.id, v.department_id, v.plate || ' — ' || v.status || coalesce(' — ' || v.location, ''), null, null, null
    from vehicles v where v.company_id = cid and v.status <> 'شغالة'
    union all
    select 'm', 'urgent', 'requests', r.id, r.department_id, r.title, null, null, null
    from requests r where r.company_id = cid and r.priority = 'عاجل' and r.status not in ('منجز', 'مرفوض')
    union all
    select 'l', 'note', 'manager_notes', n.id, n.department_id, coalesce(n.subject, left(n.body, 60)), n.due_date, n.due_date - current_date, null
    from manager_notes n where n.company_id = cid and n.status = 'مفتوحة'
  )
  select lvl, k, e, id, dep, lab, due, dd, amt from a
  order by case lvl when 'h' then 0 when 'm' then 1 else 2 end, dd nulls last
  limit greatest(1, least(lim, 500)) $$;

create or replace function public.department_summary(cid uuid)
returns table(department_id uuid, people bigint, records bigint)
language sql stable security invoker set search_path = 'public' as $$
  select d.id,
    (select count(*) from profiles p where p.department_id = d.id and p.status = 'active'),
    (select count(*) from vehicles x where x.department_id = d.id) + (select count(*) from projects x where x.department_id = d.id)
      + (select count(*) from legal_cases x where x.department_id = d.id) + (select count(*) from invoices x where x.department_id = d.id)
      + (select count(*) from documents x where x.department_id = d.id) + (select count(*) from requests x where x.department_id = d.id)
  from departments d where d.company_id = cid $$;

-- compact, COMPLETE context for the AI: totals over all rows + the most important items, not "first 300 rows"
create or replace function public.ai_company_context(cid uuid) returns json
language sql stable security invoker set search_path = 'public' as $$
  select json_build_object(
    'company', (select name from companies where id = cid),
    'today', current_date,
    'totals', public.dashboard_stats(cid),
    'departments', (select coalesce(json_agg(json_build_object('name', d.name, 'people', s.people, 'records', s.records)), '[]')
                    from public.department_summary(cid) s join departments d on d.id = s.department_id),
    'alerts', (select coalesce(json_agg(a), '[]') from public.company_alerts(cid, 120) a),
    'vehicles_by_status', (select coalesce(json_object_agg(status, n), '{}') from (select status, count(*) n from vehicles where company_id = cid group by status) x),
    'invoices_by_status', (select coalesce(json_object_agg(status, json_build_object('count', n, 'amount', amt)), '{}')
                           from (select status, count(*) n, sum(amount) amt from invoices where company_id = cid group by status) x),
    'projects', (select coalesce(json_agg(json_build_object('name', name, 'client', client, 'progress', progress, 'status', status, 'end', end_date, 'value', contract_value)
                  order by end_date nulls last), '[]') from (select * from projects where company_id = cid and status <> 'مكتمل' order by end_date nulls last limit 60) p),
    'legal_cases', (select coalesce(json_agg(json_build_object('title', title, 'status', status, 'next_hearing', next_hearing, 'lawyer', lawyer, 'last_update', left(last_update, 300))), '[]')
                    from (select * from legal_cases where company_id = cid and status <> 'مغلقة' order by next_hearing nulls last limit 40) l),
    'open_requests', (select coalesce(json_agg(json_build_object('title', title, 'priority', priority, 'status', status)), '[]')
                      from (select * from requests where company_id = cid and status not in ('منجز','مرفوض') order by created_at desc limit 40) r),
    'open_notes', (select coalesce(json_agg(json_build_object('subject', subject, 'body', left(body, 200), 'status', status, 'reply', left(reply, 200))), '[]')
                   from (select * from manager_notes where company_id = cid and status <> 'منجزة' order by created_at desc limit 30) n)
  ) $$;

do $$ declare f text; begin
  foreach f in array array['dashboard_stats(uuid)','company_alerts(uuid,int)','department_summary(uuid)','ai_company_context(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
