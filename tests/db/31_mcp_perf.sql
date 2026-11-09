-- MCP tool latency on the load scenario of 20_perf.sql (1,500 employees, 20k invoices, 3k vehicles, 49 other companies).
-- Measured with EXPLAIN ANALYZE as the real user (RLS + guard). Target: < 200 ms per tool call (database time only).
insert into auth.sessions (id, user_id) values
 ('00000000-0000-0000-5e55-00000000aaa1', '00000000-0000-0000-0001-000000000001'),   -- company admin
 ('00000000-0000-0000-5e55-00000000aaa2', (select id from profiles where company_id = '00000000-0000-0000-0000-00000000aaaa' and role = 'employee'
                                           and department_id = (select department_id from invoices where company_id = '00000000-0000-0000-0000-00000000aaaa' limit 1) limit 1));
create function pg_temp.ms(sess text, q text) returns numeric language plpgsql as $f$
declare j json; u uuid;
begin
  select user_id into u from auth.sessions where id = sess::uuid;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'session_id', sess, 'client_id', 'perf')::text, true);
  execute 'explain (analyze, format json) ' || q into j;
  reset role;
  return round((j->0->>'Execution Time')::numeric, 1);
exception when others then reset role; return -1;
end $f$;
do $$ declare t record; v numeric; begin
  for t in select * from (values
    ('admin','00000000-0000-0000-5e55-00000000aaa1','select public.mcp_company_overview()'),
    ('admin','00000000-0000-0000-5e55-00000000aaa1','select public.mcp_invoices(p_min_days_overdue => 30)'),
    ('admin','00000000-0000-0000-5e55-00000000aaa1','select public.mcp_invoices(p_limit => 50, p_offset => 10000)'),
    ('admin','00000000-0000-0000-5e55-00000000aaa1','select public.mcp_fleet()'),
    ('admin','00000000-0000-0000-5e55-00000000aaa1','select public.mcp_expiring(30)'),
    ('admin','00000000-0000-0000-5e55-00000000aaa1','select public.mcp_people()'),
    ('admin','00000000-0000-0000-5e55-00000000aaa1','select public.mcp_search(''INV-19'')'),
    ('admin','00000000-0000-0000-5e55-00000000aaa1','select public.mcp_projects(p_late_only => true)'),
    ('admin','00000000-0000-0000-5e55-00000000aaa1','select public.mcp_profit_comparison(date_trunc(''month'', current_date)::date, current_date, (date_trunc(''month'', current_date) - interval ''1 month'')::date, (date_trunc(''month'', current_date) - interval ''1 day'')::date)'),
    ('finance employee','00000000-0000-0000-5e55-00000000aaa2','select public.mcp_invoices(p_min_days_overdue => 30)'),
    ('finance employee','00000000-0000-0000-5e55-00000000aaa2','select public.mcp_profit_comparison(date_trunc(''month'', current_date)::date, current_date, (date_trunc(''month'', current_date) - interval ''1 month'')::date, (date_trunc(''month'', current_date) - interval ''1 day'')::date)')
  ) x(who, sess, q) loop
    v := pg_temp.ms(t.sess, t.q);
    insert into qa.results(issue, name, ok, detail) values ('MCP-F', t.who || ': ' || left(t.q, 70), v >= 0 and v < 200, v || ' ms');
  end loop;
end $$;
