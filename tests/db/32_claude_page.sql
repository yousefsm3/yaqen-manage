-- Claude page (manager controls): scopes, on/off, idle expiry, connections list, revoke. Runs after 30_mcp.sql.
-- A = company QA-A (a1 admin, a2 fleet employee), B = QA-B (b1 admin).
-- the OAuth session left by 30_mcp.sql (client without a row) would show up in A's list: start clean
delete from auth.sessions where id = '00000000-0000-0000-5e55-0000000aa0a1';
insert into auth.oauth_clients (id, client_name) values ('00000000-0000-0000-c1a0-000000000001', 'Claude')
  on conflict (id) do nothing;
insert into auth.sessions (id, user_id, oauth_client_id) values
 ('00000000-0000-0000-5e55-00000000c0a1','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-c1a0-000000000001'),
 ('00000000-0000-0000-5e55-00000000c0b1','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-c1a0-000000000001');

-- o(): a Claude (OAuth) token of that admin; w(): the same person in the normal web app
create function pg_temp.o(u text, q text) returns text language sql as $$
  select qa.run(u, q, '10.0.0.1', 'aal1', jsonb_build_object('session_id', '00000000-0000-0000-5e55-00000000c0' || right(u, 2), 'client_id', 'claude-test-client')) $$;
create function pg_temp.w(u text, q text) returns text language sql as $$
  select qa.run(u, q, '10.0.0.1', 'aal1', jsonb_build_object('session_id', '00000000-0000-0000-5e55-0000000000' || right(u, 2))) $$;
\set A1 '\'00000000-0000-0000-0000-0000000000a1\''
\set A2 '\'00000000-0000-0000-0000-0000000000a2\''
\set B1 '\'00000000-0000-0000-0000-0000000000b1\''

------------------------------------------------------------------ defaults + who may open the page
select qa.expect_true('CLAUDE-P','defaults: connector on, all 9 scopes, 30 days',
  (select (j->'settings'->>'enabled')::boolean and jsonb_array_length(j->'settings'->'scopes') = 9 and (j->'settings'->>'idle_days')::int = 30
   from (select pg_temp.w(:A1, $$select public.claude_page()::text$$)::jsonb j) x));
select qa.expect_blocked('CLAUDE-P','employee cannot open the Claude page', pg_temp.w(:A2, $$select public.claude_page()::text$$));
select qa.expect_blocked('CLAUDE-P','settings table is not readable directly', pg_temp.w(:A1, $$select count(*)::text from public.mcp_settings$$));
select qa.expect_blocked('CLAUDE-P','Claude (OAuth token) cannot change the settings',
  pg_temp.o(:A1, $$select public.claude_save_settings(true, array['overview'], 30)::text$$));
select qa.expect_blocked('CLAUDE-P','Claude (OAuth token) cannot revoke connections',
  pg_temp.o(:A1, $$select public.claude_revoke('00000000-0000-0000-5e55-00000000c0b1')::text$$));
select qa.expect_blocked('CLAUDE-P','employee cannot change the settings',
  pg_temp.w(:A2, $$select public.claude_save_settings(true, array['overview'], 30)::text$$));
select qa.expect_blocked('CLAUDE-P','unknown scope rejected',
  pg_temp.w(:A1, $$select public.claude_save_settings(true, array['overview','salaries'], 30)::text$$));
select qa.expect_blocked('CLAUDE-P','idle days outside the allowed list rejected',
  pg_temp.w(:A1, $$select public.claude_save_settings(true, public.mcp_all_scopes(), 45)::text$$));

------------------------------------------------------------------ scopes are enforced in the database
select qa.expect_true('CLAUDE-P','before: Claude reads invoices', pg_temp.o(:A1, $$select public.mcp_invoices()::text$$) not like 'BLOCKED%');
select qa.expect('CLAUDE-P','manager switches invoices off',
  pg_temp.w(:A1, $$select public.claude_save_settings(true, array['overview','projects','fleet','expiring','people','search','notes_rooms','comparison'], 30)::text$$), '');
select qa.expect_true('CLAUDE-P','after: invoices tool refused with SCOPE_DISABLED',
  pg_temp.o(:A1, $$select public.mcp_invoices()::text$$) like '%MCP:SCOPE_DISABLED%');
select qa.expect_true('CLAUDE-P','after: projects tool still works', pg_temp.o(:A1, $$select public.mcp_projects()::text$$) not like 'BLOCKED%');
select qa.expect_true('CLAUDE-P','search hides invoices when the scope is off (no back door)',
  (select (j->'invoices') = '[]'::jsonb and (j->'hidden_sections_ar') ? 'الفواتير'
   from (select pg_temp.o(:A1, $$select public.mcp_search('N-1')::text$$)::jsonb j) x));
select qa.expect_true('CLAUDE-P','other company unaffected (B still reads invoices)',
  pg_temp.o(:B1, $$select public.mcp_invoices()::text$$) not like 'BLOCKED%');
select qa.expect('CLAUDE-P','the change is in the audit log',
  (select count(*)::text from public.audit_log where entity = 'mcp_settings' and company_id = '00000000-0000-0000-0000-0000000000a0'), '1');

select qa.expect('CLAUDE-P','manager turns the connector off', pg_temp.w(:A1, $$select public.claude_save_settings(false, public.mcp_all_scopes(), 30)::text$$), '');
select qa.expect_true('CLAUDE-P','connector off: every tool refused with DISABLED_BY_ADMIN',
  pg_temp.o(:A1, $$select public.mcp_company_overview()::text$$) like '%MCP:DISABLED_BY_ADMIN%');
select qa.expect('CLAUDE-P','back on', pg_temp.w(:A1, $$select public.claude_save_settings(true, public.mcp_all_scopes(), 30)::text$$), '');
select qa.expect_true('CLAUDE-P','back on: overview works again', pg_temp.o(:A1, $$select public.mcp_company_overview()::text$$) not like 'BLOCKED%');

------------------------------------------------------------------ connections list
select qa.expect_true('CLAUDE-P','manager A sees A''s Claude connection with client name, not B''s',
  (select jsonb_array_length(j->'connections') = 1 and j->'connections'->0->>'client' = 'Claude'
          and j->'connections'->0->>'session_id' = '00000000-0000-0000-5e55-00000000c0a1'
   from (select pg_temp.w(:A1, $$select public.claude_page()::text$$)::jsonb j) x));

------------------------------------------------------------------ automatic expiry after N idle days
update auth.sessions set created_at = now() - interval '40 days', updated_at = now() - interval '40 days' where id = '00000000-0000-0000-5e55-00000000c0a1';
update public.mcp_usage set at = now() - interval '40 days' where user_id = '00000000-0000-0000-0000-0000000000a1';
select qa.expect_true('CLAUDE-P','unused for 40 days (limit 30): refused with SESSION_EXPIRED',
  pg_temp.o(:A1, $$select public.mcp_projects()::text$$) like '%MCP:SESSION_EXPIRED%');
select qa.expect_true('CLAUDE-P','the page marks it as expired',
  (select (j->'connections'->0->>'expired')::boolean from (select pg_temp.w(:A1, $$select public.claude_page()::text$$)::jsonb j) x));
select qa.expect('CLAUDE-P','manager raises the limit to 60 days', pg_temp.w(:A1, $$select public.claude_save_settings(true, public.mcp_all_scopes(), 60)::text$$), '');
select qa.expect_true('CLAUDE-P','within 60 days: works again', pg_temp.o(:A1, $$select public.mcp_projects()::text$$) not like 'BLOCKED%');
select qa.expect_true('CLAUDE-P','an in-flight call (ok = null) does not count as activity',
  (select public.mcp_last_active('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-5e55-00000000c0a1') < now() - interval '39 days'
   from (select public.mcp_begin('00000000-0000-0000-0000-0000000000a1', 'probe')) x));

------------------------------------------------------------------ revoke
select qa.expect_blocked('CLAUDE-P','manager B cannot revoke A''s connection',
  pg_temp.w(:B1, $$select public.claude_revoke('00000000-0000-0000-5e55-00000000c0a1')::text$$));
select qa.expect_blocked('CLAUDE-P','a normal web session cannot be revoked through this function',
  pg_temp.w(:A1, $$select public.claude_revoke('00000000-0000-0000-5e55-0000000000a2')::text$$));
select qa.expect('CLAUDE-P','manager A revokes A''s connection', pg_temp.w(:A1, $$select public.claude_revoke('00000000-0000-0000-5e55-00000000c0a1')::text$$), '');
select qa.expect_true('CLAUDE-P','after revoke: tool refused at once (SESSION_REVOKED)',
  pg_temp.o(:A1, $$select public.mcp_projects()::text$$) like '%MCP:SESSION_REVOKED%');
select qa.expect('CLAUDE-P','after revoke: list is empty',
  (select jsonb_array_length(j->'connections')::text from (select pg_temp.w(:A1, $$select public.claude_page()::text$$)::jsonb j) x), '0');
select qa.expect_true('CLAUDE-P','B''s connection untouched', exists (select 1 from auth.sessions where id = '00000000-0000-0000-5e55-00000000c0b1'));
