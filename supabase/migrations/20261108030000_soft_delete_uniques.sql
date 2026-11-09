-- Fixes: M6 (hard deletes, no recovery), M2 (no uniqueness: duplicate plates / invoice numbers).
-- Rollback: supabase/rollback/20261108030000_soft_delete_uniques.down.sql

-- ---------- M6: soft delete ----------
do $$ declare t text; begin
  foreach t in array array['vehicles','projects','legal_cases','invoices','documents','requests','manager_notes'] loop
    execute format('alter table public.%I add column if not exists deleted_at timestamptz', t);
    execute format('alter table public.%I add column if not exists deleted_by uuid references auth.users(id) on delete set null', t);
    -- no hard deletes through the API for anybody; deletion goes through soft_delete()
    execute format('drop policy if exists %1$s_del on public.%1$s', t);
    execute format('revoke delete on public.%I from anon, authenticated', t);
  end loop;
end $$;
drop policy if exists notes_del on public.manager_notes;
alter table public.companies add column if not exists deleted_at timestamptz;

-- direct UPDATEs from the API may not flip deleted_at (only soft_delete / restore_deleted may)
create or replace function public.guard_soft_delete() returns trigger language plpgsql security invoker set search_path = 'public' as $$
begin
  if current_user in ('anon', 'authenticated') and (new.deleted_at is distinct from old.deleted_at or new.deleted_by is distinct from old.deleted_by) then
    new.deleted_at := old.deleted_at; new.deleted_by := old.deleted_by;
  end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['vehicles','projects','legal_cases','invoices','documents','requests','manager_notes'] loop
    execute format('drop trigger if exists %1$s_guard_soft_delete on public.%1$s', t);
    execute format('create trigger %1$s_guard_soft_delete before update on public.%1$s for each row execute function public.guard_soft_delete()', t);
  end loop;
end $$;

create or replace function public.soft_delete(tbl text, rid uuid) returns void
language plpgsql security definer set search_path = 'public' as $$
declare cid uuid;
begin
  if tbl not in ('vehicles','projects','legal_cases','invoices','documents','requests','manager_notes') then raise exception 'جدول غير مسموح'; end if;
  execute format('select company_id from %I where id = $1 and deleted_at is null', tbl) into cid using rid;
  if cid is null then raise exception 'السجل غير موجود'; end if;
  if not public.can_manage(cid) then raise exception 'غير مصرح: الحذف للمدير فقط'; end if;
  execute format('update %I set deleted_at = now(), deleted_by = auth.uid() where id = $1', tbl) using rid;
end $$;

create or replace function public.restore_deleted(tbl text, rid uuid) returns void
language plpgsql security definer set search_path = 'public' as $$
declare cid uuid;
begin
  if tbl not in ('vehicles','projects','legal_cases','invoices','documents','requests','manager_notes') then raise exception 'جدول غير مسموح'; end if;
  execute format('select company_id from %I where id = $1 and deleted_at is not null', tbl) into cid using rid;
  if cid is null then raise exception 'السجل غير موجود في المحذوفات'; end if;
  if not public.can_manage(cid) then raise exception 'غير مصرح'; end if;
  execute format('update %I set deleted_at = null, deleted_by = null where id = $1', tbl) using rid;
end $$;

-- trash listing for admins (deleted in the last 30 days)
create or replace function public.list_trash(cid uuid) returns table(entity text, id uuid, label text, deleted_at timestamptz, deleted_by uuid)
language plpgsql stable security definer set search_path = 'public' as $$
begin
  if not public.can_manage(cid) then raise exception 'غير مصرح'; end if;
  return query
    select 'vehicles', v.id, v.plate, v.deleted_at, v.deleted_by from vehicles v where v.company_id = cid and v.deleted_at is not null
    union all select 'projects', p.id, p.name, p.deleted_at, p.deleted_by from projects p where p.company_id = cid and p.deleted_at is not null
    union all select 'legal_cases', l.id, l.title, l.deleted_at, l.deleted_by from legal_cases l where l.company_id = cid and l.deleted_at is not null
    union all select 'invoices', i.id, i.number, i.deleted_at, i.deleted_by from invoices i where i.company_id = cid and i.deleted_at is not null
    union all select 'documents', d.id, d.name, d.deleted_at, d.deleted_by from documents d where d.company_id = cid and d.deleted_at is not null
    union all select 'requests', r.id, r.title, r.deleted_at, r.deleted_by from requests r where r.company_id = cid and r.deleted_at is not null
    union all select 'manager_notes', n.id, coalesce(n.subject, left(n.body, 60)), n.deleted_at, n.deleted_by from manager_notes n where n.company_id = cid and n.deleted_at is not null
    order by 4 desc;
end $$;

-- permanent purge after the retention window (run daily by the scheduler, see migration 0006)
create or replace function public.purge_deleted(retention interval default interval '30 days') returns int
language plpgsql security definer set search_path = 'public' as $$
declare t text; n int := 0; c int;
begin
  if current_user in ('anon', 'authenticated') and not public.is_super() then raise exception 'غير مصرح'; end if;
  foreach t in array array['vehicles','projects','legal_cases','invoices','documents','requests','manager_notes'] loop
    execute format('delete from %I where deleted_at < now() - $1', t) using retention;
    get diagnostics c = row_count; n := n + c;
  end loop;
  -- companies soft-deleted by the platform owner
  delete from auth.users where id in (select p.id from profiles p join companies co on co.id = p.company_id
                                      where co.deleted_at < now() - retention and p.role <> 'super_admin');
  delete from companies where deleted_at < now() - retention;
  return n;
end $$;

-- company deletion becomes: deactivate + mark deleted (purged after 30 days, restorable before that)
create or replace function public.delete_company(target uuid) returns void
language plpgsql security definer set search_path = 'public', 'auth' as $$
begin
  if not public.is_super() then raise exception 'غير مصرح'; end if;
  update companies set active = false, deleted_at = now() where id = target;
end $$;
create or replace function public.restore_company(target uuid) returns void
language plpgsql security definer set search_path = 'public' as $$
begin
  if not public.is_super() then raise exception 'غير مصرح'; end if;
  update companies set active = true, deleted_at = null where id = target and deleted_at is not null;
end $$;

-- ---------- M2: uniqueness (live rows only, so a deleted record does not block re-entry) ----------
create or replace function public.norm_key(t text) returns text language sql immutable parallel safe set search_path = '' as $$
  select upper(regexp_replace(coalesce(t, ''), '[\s\-_./]+', '', 'g')) $$;

create unique index if not exists vehicles_company_plate_uniq on public.vehicles (company_id, public.norm_key(plate)) where deleted_at is null;
create unique index if not exists invoices_company_out_number_uniq on public.invoices (company_id, public.norm_key(number))
  where deleted_at is null and kind = 'صادرة';
create unique index if not exists invoices_company_in_number_party_uniq on public.invoices (company_id, public.norm_key(number), lower(coalesce(trim(party), '')))
  where deleted_at is null and kind = 'واردة';
create unique index if not exists legal_cases_company_number_uniq on public.legal_cases (company_id, public.norm_key(case_number))
  where deleted_at is null and case_number is not null and case_number <> '';

do $$ declare f text; begin
  foreach f in array array['soft_delete(text,uuid)','restore_deleted(text,uuid)','list_trash(uuid)','restore_company(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
revoke execute on function public.purge_deleted(interval) from public, anon, authenticated;
revoke execute on function public.guard_soft_delete() from public, anon, authenticated;
