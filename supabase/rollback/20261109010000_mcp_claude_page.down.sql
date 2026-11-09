-- Rollback of 20261109010000_mcp_claude_page.sql: back to the connector exactly as in 20261109000000.
drop function if exists public.claude_page();
drop function if exists public.claude_save_settings(boolean, text[], int);
drop function if exists public.claude_revoke(uuid);
drop function if exists public.mcp_guard(text);
drop function if exists public.mcp_scope_ok(text);
drop function if exists public.mcp_last_active(uuid, uuid);
drop function if exists public.mcp_effective(uuid);
drop function if exists public.mcp_all_scopes();
drop table if exists public.mcp_settings;
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

do $$ declare f text; begin
  foreach f in array array['mcp_company_overview()', 'mcp_projects(text, boolean, int, int)', 'mcp_project_detail(uuid)',
    'mcp_invoices(text, int, text, int, int)', 'mcp_fleet(text, text, int, int)', 'mcp_expiring(int)', 'mcp_people(text, int, int)',
    'mcp_search(text, int)', 'mcp_notes_rooms(int)', 'mcp_profit_comparison(date, date, date, date)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
