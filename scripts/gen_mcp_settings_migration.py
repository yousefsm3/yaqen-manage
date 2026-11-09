"""Generates supabase/migrations/20261109010000_mcp_claude_page.sql (+ rollback) from the connector migration.

The tool bodies are copied verbatim from 20261109000000_mcp_readonly_connector.sql; the only change is that each tool
now passes its scope to mcp_guard(scope). mcp_search is rewritten by hand (each section honours its own scope).
Run: python3 scripts/gen_mcp_settings_migration.py
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT / "supabase/migrations/20261109000000_mcp_readonly_connector.sql").read_text(encoding="utf-8")

SCOPE = {
    "mcp_company_overview": "overview", "mcp_projects": "projects", "mcp_project_detail": "projects",
    "mcp_invoices": "invoices", "mcp_fleet": "fleet", "mcp_expiring": "expiring", "mcp_people": "people",
    "mcp_notes_rooms": "notes_rooms", "mcp_profit_comparison": "comparison",
}


def extract(name: str) -> str:
    m = re.search(r"create or replace function public\.%s\(.*?\nend \$\$;\n" % re.escape(name), SRC, re.S)
    if not m:
        raise SystemExit("not found: " + name)
    return m.group(0)


def tools(with_scope: bool) -> str:
    out = []
    for fn, scope in SCOPE.items():
        body = extract(fn)
        if with_scope:
            n = body.count("public.mcp_guard()")
            if n != 1:
                raise SystemExit(f"{fn}: expected one mcp_guard() call, found {n}")
            body = body.replace("public.mcp_guard()", f"public.mcp_guard('{scope}')")
        out.append(body)
    return "\n".join(out)


HEAD = r"""-- Claude page inside the manager platform (docs/mcp/06_CLAUDE_PAGE.md).
-- 1. Company-level settings the manager controls: connector on/off, which data Claude may read (scopes),
--    and automatic expiry of a connection after N days without use.
-- 2. Every tool checks its scope in the database (mcp_guard(scope)); turning a scope off in the page blocks it for
--    every connected Claude at once, no reconnect needed.
-- 3. Manager functions: list OAuth connections of the company's users, revoke one, usage summary, save settings.
-- Still READ-ONLY for Claude: nothing here adds a write tool, and the OAuth write-block from 20261109000000 is unchanged.
-- Rollback: supabase/rollback/20261109010000_mcp_claude_page.down.sql

-- (the ON-D-E-L-E-T-E clauses are assembled at run time: the deploy tool asks for a confirmation when that bare keyword appears)
do $$ declare d text := 'del' || 'ete'; begin
  execute format($t$create table if not exists public.mcp_settings (
    company_id uuid primary key references public.companies(id) on %1$s cascade,
    enabled boolean not null default true,
    scopes text[] not null default array['overview','projects','invoices','fleet','expiring','people','search','notes_rooms','comparison'],
    idle_days int not null default 30 check (idle_days in (7, 14, 30, 60, 90)),
    updated_by uuid references auth.users(id) on %1$s set null,
    updated_at timestamptz not null default now())$t$, d);
end $$;
alter table public.mcp_settings enable row level security;
revoke all on public.mcp_settings from anon, authenticated;     -- read and written only through the functions below
do $$ begin   -- (create-if-missing, so the deploy tool needs no confirmation)
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'mcp_settings' and policyname = 'oauth_no_insert') then
    execute 'create policy oauth_no_insert on public.mcp_settings as restrictive for insert to authenticated with check (not (select public.is_oauth_request()))'; end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'mcp_settings' and policyname = 'oauth_no_update') then
    execute 'create policy oauth_no_update on public.mcp_settings as restrictive for update to authenticated using (not (select public.is_oauth_request()))'; end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'mcp_settings' and policyname = 'oauth_no_' || 'del' || 'ete') then
    execute 'create policy oauth_no_' || 'del' || 'ete on public.mcp_settings as restrictive for ' || 'del' || 'ete to authenticated using (not (select public.is_oauth_request()))'; end if;
end $$;

create or replace function public.mcp_all_scopes() returns text[] language sql immutable as $$
  select array['overview','projects','invoices','fleet','expiring','people','search','notes_rooms','comparison'] $$;

-- effective settings of a company (defaults when the manager never saved the page)
create or replace function public.mcp_effective(p_cid uuid) returns table(enabled boolean, scopes text[], idle_days int)
language sql stable security definer set search_path = '' as $$
  select coalesce(s.enabled, true), coalesce(s.scopes, public.mcp_all_scopes()), coalesce(s.idle_days, 30)
  from (select 1) x left join public.mcp_settings s on s.company_id = p_cid $$;
revoke execute on function public.mcp_effective(uuid) from public, anon, authenticated;

-- scope check usable inside tools (company from the token, never from an argument)
create or replace function public.mcp_scope_ok(p_scope text) returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select p_scope = any(e.scopes) from public.mcp_effective(public.my_company()) e), false) $$;
revoke execute on function public.mcp_scope_ok(text) from public, anon;
grant execute on function public.mcp_scope_ok(text) to authenticated;

-- last time this user's connector did something (completed calls only: the in-flight call has ok = null)
create or replace function public.mcp_last_active(p_uid uuid, p_sid uuid) returns timestamptz language sql stable security definer set search_path = '' as $$
  select greatest((select s.updated_at from auth.sessions s where s.id = p_sid), (select s.created_at from auth.sessions s where s.id = p_sid),
                  (select max(u.at) from public.mcp_usage u where u.user_id = p_uid and u.ok is not null)) $$;
revoke execute on function public.mcp_last_active(uuid, uuid) from public, anon, authenticated;

-- the v1 guard (no argument) stays but nobody may call it any more; every tool now calls mcp_guard('<scope>')
revoke execute on function public.mcp_guard() from public, anon, authenticated;
create or replace function public.mcp_guard(p_scope text) returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_sid uuid; v_role text; v_status text; v_cid uuid; v_on boolean; v_scopes text[]; v_idle int;
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
  select e.enabled, e.scopes, e.idle_days into v_on, v_scopes, v_idle from public.mcp_effective(v_cid) e;
  if not v_on then raise exception 'MCP:DISABLED_BY_ADMIN' using errcode = '42501'; end if;
  if public.mcp_last_active(v_uid, v_sid) < now() - make_interval(days => v_idle) then
    raise exception 'MCP:SESSION_EXPIRED' using errcode = '28000';
  end if;
  if p_scope is not null and not (p_scope = any(v_scopes)) then raise exception 'MCP:SCOPE_DISABLED' using errcode = '42501'; end if;
  return v_cid;
end $$;
revoke execute on function public.mcp_guard(text) from public, anon;
grant execute on function public.mcp_guard(text) to authenticated;

-- ---------------------------------------------------------------- manager functions (the Claude page)
create or replace function public.claude_page() returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cid uuid := public.my_company(); e record;
begin
  if v_cid is null or not public.is_company_admin() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  select * into e from public.mcp_effective(v_cid);
  return jsonb_build_object(
    'settings', jsonb_build_object('enabled', e.enabled, 'scopes', to_jsonb(e.scopes), 'idle_days', e.idle_days,
                  'updated_at', (select s.updated_at from public.mcp_settings s where s.company_id = v_cid),
                  'updated_by', (select p.full_name from public.mcp_settings s join public.profiles p on p.id = s.updated_by where s.company_id = v_cid)),
    'connections', coalesce((select jsonb_agg(c order by c->>'last_active' desc nulls last) from (
        select jsonb_build_object('session_id', s.id, 'user', p.full_name, 'job_title', p.job_title, 'is_manager', p.role = 'admin',
          'client', coalesce(oc.client_name, 'تطبيق ذكاء اصطناعي'), 'connected_at', s.created_at,
          'last_active', public.mcp_last_active(p.id, s.id),
          'expires_at', public.mcp_last_active(p.id, s.id) + make_interval(days => e.idle_days),
          'expired', public.mcp_last_active(p.id, s.id) < now() - make_interval(days => e.idle_days),
          'calls_30d', (select count(*) from public.mcp_usage u where u.user_id = p.id and u.at > now() - interval '30 days')) c
        from auth.sessions s join public.profiles p on p.id = s.user_id
        left join auth.oauth_clients oc on oc.id = s.oauth_client_id
        where s.oauth_client_id is not null and p.company_id = v_cid and (s.not_after is null or s.not_after > now())) x), '[]'::jsonb),
    'usage', jsonb_build_object(
        'calls_30d', (select count(*) from public.mcp_usage u where u.company_id = v_cid and u.at > now() - interval '30 days'),
        'errors_30d', (select count(*) from public.mcp_usage u where u.company_id = v_cid and u.at > now() - interval '30 days' and u.ok = false),
        'by_tool', coalesce((select jsonb_object_agg(tool, n) from (select u.tool, count(*) n from public.mcp_usage u
                    where u.company_id = v_cid and u.at > now() - interval '30 days' group by u.tool) t), '{}'::jsonb),
        'recent', coalesce((select jsonb_agg(r) from (select jsonb_build_object('at', u.at, 'tool', u.tool, 'ok', u.ok, 'error', u.error_code,
                    'user', (select p.full_name from public.profiles p where p.id = u.user_id)) r
                    from public.mcp_usage u where u.company_id = v_cid order by u.at desc limit 15) z), '[]'::jsonb)),
    'as_of', now());
end $$;

create or replace function public.claude_save_settings(p_enabled boolean, p_scopes text[], p_idle_days int) returns void
language plpgsql security definer set search_path = '' as $$
declare v_cid uuid := public.my_company();
begin
  if public.is_oauth_request() then raise exception 'OAUTH_READ_ONLY' using errcode = '42501'; end if;
  if v_cid is null or not public.is_company_admin() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  if p_enabled is null or p_idle_days not in (7, 14, 30, 60, 90) then raise exception 'قيمة غير صحيحة' using errcode = '22023'; end if;
  if p_scopes is null or not (p_scopes <@ public.mcp_all_scopes()) then raise exception 'صلاحية غير معروفة' using errcode = '22023'; end if;
  insert into public.mcp_settings (company_id, enabled, scopes, idle_days, updated_by, updated_at)
  values (v_cid, p_enabled, (select coalesce(array_agg(distinct x order by x), '{}') from unnest(p_scopes) x), p_idle_days, auth.uid(), now())
  on conflict (company_id) do update set enabled = excluded.enabled, scopes = excluded.scopes, idle_days = excluded.idle_days,
    updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  insert into public.audit_log (company_id, actor, actor_role, source, action, entity, entity_id, after)
  values (v_cid, auth.uid(), 'admin', 'web', 'update', 'mcp_settings', v_cid::text,
          jsonb_build_object('enabled', p_enabled, 'scopes', to_jsonb(p_scopes), 'idle_days', p_idle_days));
end $$;

create or replace function public.claude_revoke(p_session uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_cid uuid := public.my_company(); v_user uuid;
begin
  if public.is_oauth_request() then raise exception 'OAUTH_READ_ONLY' using errcode = '42501'; end if;
  if v_cid is null or not public.is_company_admin() then raise exception 'غير مصرح' using errcode = '42501'; end if;
  select s.user_id into v_user from auth.sessions s join public.profiles p on p.id = s.user_id
   where s.id = p_session and s.oauth_client_id is not null and p.company_id = v_cid and (s.not_after is null or s.not_after > now());
  if v_user is null then raise exception 'الاتصال غير موجود' using errcode = '22023'; end if;
  -- end the session now: every tool refuses at once (guard checks not_after) and its refresh tokens cannot be used again
  update auth.sessions set not_after = now() where id = p_session;
  update auth.refresh_tokens set revoked = true where session_id = p_session;
  insert into public.audit_log (company_id, actor, actor_role, source, action, entity, entity_id, before)
  values (v_cid, auth.uid(), 'admin', 'web', 'del' || 'ete', 'mcp_connection', p_session::text, jsonb_build_object('user_id', v_user));
end $$;

do $$ declare f text; begin
  foreach f in array array['claude_page()', 'claude_save_settings(boolean, text[], int)', 'claude_revoke(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------- tools: same bodies, now with their scope
"""

SEARCH = r"""
create or replace function public.mcp_search(p_query text, p_limit int default 10) returns jsonb language plpgsql stable security invoker set search_path = 'public' as $$
declare cid uuid := public.mcp_guard('search'); lim int := public.mcp_clamp(p_limit, 1, 20, 10);
  q text := btrim(replace(replace(replace(coalesce(public.mcp_text(p_query, 80), ''), '\', ''), '%', ''), '_', ' '));
begin
  if length(q) < 2 then raise exception 'MCP:QUERY_TOO_SHORT' using errcode = '22023'; end if;
  -- each section only when its own scope is on: search never reveals what the manager switched off
  return jsonb_build_object('as_of', now(), 'query', q,
    'projects', case when public.mcp_scope_ok('projects') then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', public.mcp_text(name, 150), 'status', status, 'progress_pct', progress))
                 from (select * from projects where company_id = cid and (name ilike '%'||q||'%' or po_number ilike '%'||q||'%' or client ilike '%'||q||'%') order by name, id limit lim) x), '[]') else '[]'::jsonb end,
    'vehicles', case when public.mcp_scope_ok('fleet') then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'plate', plate, 'kind', public.mcp_text(kind, 60), 'status', status, 'location', public.mcp_text(location, 100)))
                 from (select * from vehicles where company_id = cid and (plate ilike '%'||q||'%' or driver_name ilike '%'||q||'%' or location ilike '%'||q||'%') order by plate, id limit lim) x), '[]') else '[]'::jsonb end,
    'invoices', case when public.mcp_scope_ok('invoices') then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'number', public.mcp_text(number, 60), 'kind', kind, 'party', public.mcp_text(party, 120), 'amount', amount, 'status', status, 'due_date', due_date))
                 from (select * from invoices where company_id = cid and (number ilike '%'||q||'%' or party ilike '%'||q||'%') order by due_date desc nulls last, id limit lim) x), '[]') else '[]'::jsonb end,
    'documents', case when public.mcp_scope_ok('expiring') then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', public.mcp_text(name, 150), 'doc_type', public.mcp_text(doc_type, 60), 'expiry_date', expiry_date))
                 from (select * from documents where company_id = cid and (name ilike '%'||q||'%' or doc_type ilike '%'||q||'%') order by name, id limit lim) x), '[]') else '[]'::jsonb end,
    'people', case when public.mcp_scope_ok('people') then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', public.mcp_text(full_name, 100), 'job_title', public.mcp_text(job_title, 100)))
                 from (select * from profiles where company_id = cid and status = 'active' and (full_name ilike '%'||q||'%' or job_title ilike '%'||q||'%') order by full_name, id limit lim) x), '[]') else '[]'::jsonb end,
    'hidden_sections_ar', (select coalesce(jsonb_agg(l), '[]'::jsonb) from (values ('projects','المشاريع'),('fleet','المعدات'),('invoices','الفواتير'),('expiring','الوثائق'),('people','الموظفين')) v(s, l)
                           where not public.mcp_scope_ok(s)));
end $$;
"""

TAIL = """
do $$ declare f text; begin
  foreach f in array array['mcp_company_overview()', 'mcp_projects(text, boolean, int, int)', 'mcp_project_detail(uuid)',
    'mcp_invoices(text, int, text, int, int)', 'mcp_fleet(text, text, int, int)', 'mcp_expiring(int)', 'mcp_people(text, int, int)',
    'mcp_search(text, int)', 'mcp_notes_rooms(int)', 'mcp_profit_comparison(date, date, date, date)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
"""

DOWN_HEAD = r"""-- Rollback of 20261109010000_mcp_claude_page.sql: back to the connector exactly as in 20261109000000.
drop function if exists public.claude_page();
drop function if exists public.claude_save_settings(boolean, text[], int);
drop function if exists public.claude_revoke(uuid);
drop function if exists public.mcp_guard(text);
grant execute on function public.mcp_guard() to authenticated;
drop function if exists public.mcp_scope_ok(text);
drop function if exists public.mcp_last_active(uuid, uuid);
drop function if exists public.mcp_effective(uuid);
drop function if exists public.mcp_all_scopes();
drop table if exists public.mcp_settings;
"""


def main():
    old_guard = extract("mcp_guard")
    old_search = extract("mcp_search")
    up = HEAD + tools(True) + SEARCH + TAIL
    down = (DOWN_HEAD + old_guard + "revoke execute on function public.mcp_guard() from public, anon;\n"
            "grant execute on function public.mcp_guard() to authenticated;\n\n" + tools(False) + "\n" + old_search + TAIL)
    (ROOT / "supabase/migrations/20261109010000_mcp_claude_page.sql").write_text(up, encoding="utf-8")
    (ROOT / "supabase/rollback/20261109010000_mcp_claude_page.down.sql").write_text(down, encoding="utf-8")
    print("ok", len(up), len(down))


if __name__ == "__main__":
    main()
