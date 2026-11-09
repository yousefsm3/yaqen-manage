-- Local staging: minimal stand-ins for the Supabase platform objects the app schema depends on.
-- This lets the real production schema + migrations run on a local Postgres 16 for testing.
-- NOT for production. Production uses the real Supabase auth/storage schemas.
-- Supabase installs extensions in schema "extensions"
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if;
end $$;
grant usage on schema extensions to anon, authenticated, service_role;

create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  raw_app_meta_data jsonb default '{}'::jsonb,
  aud text, role text,
  email_confirmed_at timestamptz,
  created_at timestamptz default now()
);
-- mirrors the columns of the real auth.sessions that the app reads (id, user_id, not_after)
create table if not exists auth.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  not_after timestamptz,
  oauth_client_id uuid,
  scopes text
);
-- mirrors the columns of the real auth.refresh_tokens used when a Claude connection is revoked
create table if not exists auth.refresh_tokens (
  id bigserial primary key,
  session_id uuid,
  revoked boolean default false
);
-- mirrors auth.oauth_clients (Supabase OAuth 2.1 server): the Claude page reads the client name
create table if not exists auth.oauth_clients (
  id uuid primary key default gen_random_uuid(),
  client_name text,
  created_at timestamptz default now(),
  deleted_at timestamptz
);
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then create role authenticator noinherit; end if;
end $$;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid $$;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;
create or replace function auth.role() returns text language sql stable as $$ select auth.jwt() ->> 'role' $$;

create schema if not exists storage;
create table if not exists storage.buckets (id text primary key, name text, public boolean default false, file_size_limit bigint);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text, owner uuid, created_at timestamptz default now()
);
create or replace function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1] $$;
alter table storage.objects enable row level security;

do $$ begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then create publication supabase_realtime; end if;
end $$;

grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema storage to anon, authenticated, service_role;
grant execute on all functions in schema auth to anon, authenticated, service_role;
alter default privileges in schema public grant select, insert, update, delete on tables to anon, authenticated, service_role;
alter default privileges in schema public grant usage, select on sequences to anon, authenticated, service_role;

-- Supabase defaults: per-role statement timeouts (verified on production: authenticated 8s, anon 3s)
alter role authenticated set statement_timeout = '8s';
alter role anon set statement_timeout = '3s';
