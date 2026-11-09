-- Fixes: H3 (no audit trail, created_by spoofable).
-- Append-only audit_log written only by triggers; created_by is always the real caller.
-- Rollback: supabase/rollback/20261108020000_audit_log.down.sql

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  company_id uuid,
  actor uuid,
  actor_role text,
  source text not null default 'web',        -- web | ai | system (ai/system set server-side, see audit_source())
  action text not null,                      -- insert | update | delete | soft_delete | restore
  entity text not null,
  entity_id text,
  before jsonb,
  after jsonb
);
create index if not exists audit_log_company_at_idx on public.audit_log (company_id, at desc);
create index if not exists audit_log_entity_idx on public.audit_log (entity, entity_id);
create index if not exists audit_log_actor_idx on public.audit_log (actor, at desc);

alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;            -- read only; no insert/update/delete for any API role
create policy audit_read on public.audit_log for select to authenticated
  using ((select public.is_super()) or (company_id = (select public.my_company()) and (select public.is_company_admin())));

-- who/what is acting. 'ai' / 'system' only from trusted server contexts (service role or no JWT).
create or replace function public.audit_source() returns text language sql stable set search_path = '' as $$
  select case
    when auth.uid() is null then 'system'
    when coalesce(current_setting('request.jwt.claims', true), '{}')::jsonb ->> 'role' = 'service_role' then 'ai'
    else 'web' end $$;

create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = 'public' as $$
declare
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  b jsonb; a jsonb; act text; k text; cid uuid;
begin
  if tg_op = 'UPDATE' then
    b := '{}'; a := '{}';
    for k in select jsonb_object_keys(n) loop
      if (o -> k) is distinct from (n -> k) and k not in ('updated_at', 'last_message_at') then
        b := b || jsonb_build_object(k, o -> k); a := a || jsonb_build_object(k, n -> k);
      end if;
    end loop;
    if a = '{}'::jsonb then return null; end if;           -- nothing meaningful changed
    act := case when (a ? 'deleted_at') and (n ->> 'deleted_at') is not null then 'soft_delete'
                when (a ? 'deleted_at') then 'restore' else 'update' end;
  elsif tg_op = 'INSERT' then act := 'insert'; a := n;
  else act := 'delete'; b := o;
  end if;
  cid := coalesce((coalesce(n, o) ->> 'company_id')::uuid,
                  case when tg_table_name = 'companies' then (coalesce(n, o) ->> 'id')::uuid end,
                  case when tg_table_name in ('room_members', 'room_messages')
                       then (select company_id from rooms where id = (coalesce(n, o) ->> 'room_id')::uuid) end);
  insert into audit_log (company_id, actor, actor_role, source, action, entity, entity_id, before, after)
  values (cid, auth.uid(), (select role from profiles where id = auth.uid()), public.audit_source(), act, tg_table_name,
          coalesce(coalesce(n, o) ->> 'id', (coalesce(n, o) ->> 'room_id') || ':' || (coalesce(n, o) ->> 'user_id')), b, a);
  return null;
end $$;

-- created_by is server-assigned on insert and immutable afterwards
create or replace function public.enforce_created_by() returns trigger
language plpgsql security invoker set search_path = 'public' as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.created_by := auth.uid(); end if;
  else
    new.created_by := old.created_by;
  end if;
  return new;
end $$;

do $$ declare t text; begin
  foreach t in array array['companies','departments','profiles','vehicles','projects','legal_cases','invoices','documents',
                           'requests','manager_notes','rooms','room_members'] loop
    execute format('drop trigger if exists %1$s_audit on public.%1$s', t);
    execute format('create trigger %1$s_audit after insert or update or delete on public.%1$s for each row execute function public.audit_row()', t);
  end loop;
  -- chat messages: audit deletions only (content is already in the table)
  drop trigger if exists room_messages_audit on public.room_messages;
  create trigger room_messages_audit after delete on public.room_messages for each row execute function public.audit_row();
  foreach t in array array['vehicles','projects','legal_cases','invoices','documents','requests','manager_notes','rooms'] loop
    execute format('drop trigger if exists %1$s_created_by on public.%1$s', t);
    execute format('create trigger %1$s_created_by before insert or update on public.%1$s for each row execute function public.enforce_created_by()', t);
  end loop;
end $$;

revoke execute on function public.audit_row(), public.enforce_created_by(), public.audit_source() from public, anon, authenticated;
