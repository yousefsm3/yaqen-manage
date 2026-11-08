-- Rollback of the MCP connector migration. Restores the database to the state after 20261108080000.
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    execute 'alter role authenticator reset pgrst.db_pre_request';
    perform pg_notify('pgrst', 'reload config');
  end if;
end $$;
do $$ declare t text; begin
  foreach t in array array['companies','departments','profiles','projects','invoices','vehicles','documents','legal_cases','requests',
                           'manager_notes','rooms','room_members','room_messages','notifications'] loop
    execute format('drop policy if exists oauth_no_insert on public.%I', t);
    execute format('drop policy if exists oauth_no_update on public.%I', t);
    execute format('drop policy if exists oauth_no_delete on public.%I', t);
  end loop;
end $$;
drop policy if exists oauth_no_insert on storage.objects;
drop policy if exists oauth_no_update on storage.objects;
drop policy if exists oauth_no_delete on storage.objects;
drop function if exists public.mcp_company_overview(), public.mcp_projects(text, boolean, int, int), public.mcp_project_detail(uuid),
  public.mcp_invoices(text, int, text, int, int), public.mcp_fleet(text, text, int, int), public.mcp_expiring(int), public.mcp_people(text, int, int),
  public.mcp_search(text, int), public.mcp_notes_rooms(int), public.mcp_profit_comparison(date, date, date, date),
  public.report_profit_comparison(date, date, date, date), public.mcp_begin(uuid, text), public.mcp_end(bigint, boolean, int, int, text),
  public.mcp_guard(), public.mcp_selfcheck(), public.mcp_clamp(int, int, int, int), public.mcp_text(text, int), public.pre_request(), public.is_oauth_request();
drop table if exists public.mcp_usage;
