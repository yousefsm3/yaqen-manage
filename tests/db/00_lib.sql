-- Test helpers. Lives in schema "qa", which exists only on staging test runs (never in migrations).
drop schema if exists qa cascade;
create schema qa;
grant usage on schema qa to anon, authenticated;
create table qa.results (n serial primary key, issue text, name text, ok boolean, detail text);
grant all on qa.results to anon, authenticated;
grant usage on sequence qa.results_n_seq to anon, authenticated;

-- Run SQL as a given identity, the same way PostgREST does: SET ROLE + request.jwt.claims.
-- who: a user uuid | 'anon' | 'service' (no JWT, table owner, like maintenance jobs)
create function qa.run(who text, q text, ip text default '10.0.0.1', aal text default 'aal1') returns text language plpgsql as $f$
declare r text;
begin
  begin
    perform set_config('request.headers', json_build_object('x-forwarded-for', ip)::text, true);
    if who = 'service' then
      perform set_config('request.jwt.claims', '', true);
    elsif who = 'anon' then
      set local role anon;
      perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    else
      set local role authenticated;
      perform set_config('request.jwt.claims', json_build_object('sub', who, 'role', 'authenticated', 'aal', aal)::text, true);
    end if;
    execute q into r;
    reset role;
    return coalesce(r, 'null');
  exception when others then
    reset role;
    return 'BLOCKED: ' || left(sqlerrm, 120);
  end;
end $f$;

create function qa.expect(issue text, name text, actual text, expected text) returns void language plpgsql as $f$
begin
  insert into qa.results(issue, name, ok, detail) values (issue, name, actual = expected,
    case when actual = expected then actual else 'got [' || coalesce(actual,'null') || '] expected [' || expected || ']' end);
end $f$;

-- passes when the action was refused (error) or touched 0 rows
create function qa.expect_blocked(issue text, name text, actual text) returns void language plpgsql as $f$
begin
  insert into qa.results(issue, name, ok, detail) values (issue, name,
    actual like 'BLOCKED%' or actual in ('0', 'null', ''), actual);
end $f$;

create function qa.expect_true(issue text, name text, cond boolean, detail text default '') returns void language plpgsql as $f$
begin
  insert into qa.results(issue, name, ok, detail) values (issue, name, coalesce(cond, false), detail);
end $f$;

-- EXPLAIN ANALYZE as a user; returns execution ms
create function qa.ms(who text, q text) returns numeric language plpgsql as $f$
declare j json;
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', who, 'role', 'authenticated')::text, true);
  execute 'explain (analyze, format json) ' || q into j;
  reset role;
  return round((j->0->>'Execution Time')::numeric, 1);
exception when others then reset role; return -1;
end $f$;

create function qa.has_column(t text, c text) returns boolean language sql as $$
  select exists(select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name=c) $$;
create function qa.has_table(t text) returns boolean language sql as $$
  select exists(select 1 from information_schema.tables where table_schema='public' and table_name=t) $$;
create function qa.has_function(f text) returns boolean language sql as $$
  select exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=f) $$;

-- evaluate a boolean SQL expression safely: missing tables/columns => FAIL (never a false PASS)
create function qa.check_sql(issue text, name text, q text) returns void language plpgsql as $f$
declare r boolean; err text := '';
begin
  begin execute q into r; exception when others then r := false; err := left(sqlerrm, 100); end;
  insert into qa.results(issue, name, ok, detail) values (issue, name, coalesce(r, false), err);
end $f$;
