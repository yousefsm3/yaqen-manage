-- Prepares an EMPTY plain-Postgres database to receive a dump of the Supabase project, for the automatic
-- restore drill (nightly) and for incident investigation. Never run against production.
-- The dump itself brings the auth, storage and public schemas; this only adds what lives outside them.
do $$ declare r text; begin
  foreach r in array array['anon','authenticated','service_role','authenticator','supabase_admin','supabase_auth_admin',
    'supabase_storage_admin','supabase_realtime_admin','supabase_replication_admin','supabase_read_only_user','dashboard_user','pgbouncer'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop;
end $$;
alter role service_role bypassrls;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;
do $$ begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then create publication supabase_realtime; end if;
end $$;
