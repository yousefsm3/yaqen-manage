-- Fixes: C1 (RLS evaluated per row: 9-11 s on 20k rows), M3 (unindexed foreign keys, per-row auth.uid()),
--        M1 (any room member could rewrite another message's translation), L1 (anonymous listing of avatar files).
-- Technique: every caller-context function is wrapped in (select ...) so Postgres evaluates it ONCE per query
-- (an InitPlan) instead of once per row, and tenant columns are indexed.
-- Rollback: supabase/rollback/20261108040000_rls_performance.down.sql

-- ---------- room visibility as arrays (evaluated once per query) ----------
create or replace function public.visible_room_ids() returns uuid[] language sql stable security definer set search_path = 'public' as $$
  select coalesce(array_agg(r.id), '{}') from rooms r
  where public.is_super()
     or (r.company_id = public.my_company()
         and (public.is_company_admin() or r.created_by = auth.uid()
              or exists (select 1 from room_members m where m.room_id = r.id and m.user_id = auth.uid()))) $$;
create or replace function public.postable_room_ids() returns uuid[] language sql stable security definer set search_path = 'public' as $$
  select coalesce(array_agg(id), '{}') from rooms where status = 'مفتوحة' and id = any(public.visible_room_ids()) $$;
create or replace function public.admin_room_ids() returns uuid[] language sql stable security definer set search_path = 'public' as $$
  select coalesce(array_agg(r.id), '{}') from rooms r
  where public.is_super() or (r.company_id = public.my_company() and (public.is_company_admin() or r.created_by = auth.uid())) $$;
create or replace function public.visible_room_folders() returns text[] language sql stable security definer set search_path = 'public' as $$
  select coalesce(array_agg(x::text), '{}') from unnest(public.visible_room_ids()) x $$;
create or replace function public.postable_room_folders() returns text[] language sql stable security definer set search_path = 'public' as $$
  select coalesce(array_agg(x::text), '{}') from unnest(public.postable_room_ids()) x $$;
create or replace function public.admin_room_folders() returns text[] language sql stable security definer set search_path = 'public' as $$
  select coalesce(array_agg(x::text), '{}') from unnest(public.admin_room_ids()) x $$;
-- kept for compatibility with existing callers (single-room checks)
create or replace function public.can_see_room(r uuid) returns boolean language sql stable security definer set search_path = 'public' as $$
  select r = any(public.visible_room_ids()) $$;
create or replace function public.can_post_room(r uuid) returns boolean language sql stable security definer set search_path = 'public' as $$
  select r = any(public.postable_room_ids()) $$;
create or replace function public.can_admin_room(r uuid) returns boolean language sql stable security definer set search_path = 'public' as $$
  select r = any(public.admin_room_ids()) $$;

-- ---------- business tables ----------
do $$ declare t text;
  vis text := '((select public.is_super()) or (company_id = (select public.my_company()) and ((select public.is_company_admin()) or department_id = (select public.my_department()))))';
begin
  foreach t in array array['vehicles','projects','legal_cases','invoices','documents','requests'] loop
    execute format('drop policy if exists %1$s_read on public.%1$s', t);
    execute format('drop policy if exists %1$s_ins on public.%1$s', t);
    execute format('drop policy if exists %1$s_upd on public.%1$s', t);
    execute format('create policy %1$s_read on public.%1$s for select to authenticated using (deleted_at is null and %2$s)', t, vis);
    execute format('create policy %1$s_ins on public.%1$s for insert to authenticated with check (%2$s)', t, vis);
    execute format('create policy %1$s_upd on public.%1$s for update to authenticated using (deleted_at is null and %2$s) with check (%2$s)', t, vis);
    -- M3 / C1 indexes: tenant + default sort, department filter, every FK
    execute format('create index if not exists %1$s_company_updated_idx on public.%1$s (company_id, updated_at desc, id) where deleted_at is null', t);
    execute format('create index if not exists %1$s_company_dept_idx on public.%1$s (company_id, department_id) where deleted_at is null', t);
    execute format('create index if not exists %1$s_department_idx on public.%1$s (department_id)', t);
    execute format('create index if not exists %1$s_created_by_idx on public.%1$s (created_by)', t);
    execute format('create index if not exists %1$s_deleted_by_idx on public.%1$s (deleted_by)', t);
  end loop;
end $$;

-- manager notes
drop policy if exists notes_read on public.manager_notes;
drop policy if exists notes_ins on public.manager_notes;
drop policy if exists notes_upd on public.manager_notes;
create policy notes_read on public.manager_notes for select to authenticated using (deleted_at is null and
  ((select public.is_super()) or (company_id = (select public.my_company()) and ((select public.is_company_admin()) or department_id = (select public.my_department())))));
create policy notes_ins on public.manager_notes for insert to authenticated with check (
  (select public.is_super()) or (company_id = (select public.my_company()) and (select public.is_company_admin())));
create policy notes_upd on public.manager_notes for update to authenticated using (deleted_at is null and
  ((select public.is_super()) or (company_id = (select public.my_company()) and ((select public.is_company_admin()) or department_id = (select public.my_department())))));
create index if not exists manager_notes_company_created_idx on public.manager_notes (company_id, created_at desc) where deleted_at is null;
create index if not exists manager_notes_department_idx on public.manager_notes (department_id);
create index if not exists manager_notes_created_by_idx on public.manager_notes (created_by);
create index if not exists manager_notes_replied_by_idx on public.manager_notes (replied_by);
create index if not exists manager_notes_deleted_by_idx on public.manager_notes (deleted_by);

-- companies / departments / profiles
drop policy if exists comp_read on public.companies;
drop policy if exists comp_ins on public.companies;
drop policy if exists comp_upd on public.companies;
drop policy if exists comp_del on public.companies;
create policy comp_read on public.companies for select to authenticated using ((select public.is_super()) or id = (select public.my_company()));
create policy comp_ins on public.companies for insert to authenticated with check ((select public.is_super()));
create policy comp_upd on public.companies for update to authenticated
  using ((select public.is_super()) or (id = (select public.my_company()) and (select public.is_company_admin())))
  with check ((select public.is_super()) or (id = (select public.my_company()) and (select public.is_company_admin())));
-- no delete policy: companies are removed only through delete_company() (soft) and purge_deleted()
revoke delete on public.companies from anon, authenticated;

drop policy if exists dep_read on public.departments;
drop policy if exists dep_ins on public.departments;
drop policy if exists dep_upd on public.departments;
drop policy if exists dep_del on public.departments;
create policy dep_read on public.departments for select to authenticated using ((select public.is_super()) or company_id = (select public.my_company()));
create policy dep_ins on public.departments for insert to authenticated with check ((select public.is_super()) or (company_id = (select public.my_company()) and (select public.is_company_admin())));
create policy dep_upd on public.departments for update to authenticated
  using ((select public.is_super()) or (company_id = (select public.my_company()) and (select public.is_company_admin())))
  with check ((select public.is_super()) or (company_id = (select public.my_company()) and (select public.is_company_admin())));
create policy dep_del on public.departments for delete to authenticated using ((select public.is_super()) or (company_id = (select public.my_company()) and (select public.is_company_admin())));

drop policy if exists prof_read on public.profiles;
drop policy if exists prof_upd on public.profiles;
create policy prof_read on public.profiles for select to authenticated using (
  id = (select auth.uid()) or (select public.is_super())
  or (company_id = (select public.my_company()) and ((select public.is_company_admin()) or (status = 'active' and department_id = (select public.my_department())))));
create policy prof_upd on public.profiles for update to authenticated
  using (id = (select auth.uid()) or (select public.is_super()) or (company_id = (select public.my_company()) and (select public.is_company_admin())))
  with check (id = (select auth.uid()) or (select public.is_super()) or (company_id = (select public.my_company()) and (select public.is_company_admin())));
create index if not exists profiles_company_idx on public.profiles (company_id, created_at, id);
create index if not exists profiles_department_idx on public.profiles (department_id);
create index if not exists profiles_requested_department_idx on public.profiles (requested_department_id);
create index if not exists profiles_approved_by_idx on public.profiles (approved_by);
create index if not exists profiles_company_status_idx on public.profiles (company_id, status);

-- rooms
drop policy if exists rooms_read on public.rooms;
drop policy if exists rooms_ins on public.rooms;
drop policy if exists rooms_upd on public.rooms;
drop policy if exists rooms_del on public.rooms;
create policy rooms_read on public.rooms for select to authenticated using (id = any((select public.visible_room_ids())::uuid[]));
create policy rooms_ins on public.rooms for insert to authenticated with check ((select public.is_super()) or company_id = (select public.my_company()));
create policy rooms_upd on public.rooms for update to authenticated using (id = any((select public.admin_room_ids())::uuid[])) with check (id = any((select public.admin_room_ids())::uuid[]));
create policy rooms_del on public.rooms for delete to authenticated using (id = any((select public.admin_room_ids())::uuid[]));
create index if not exists rooms_company_idx on public.rooms (company_id, last_message_at desc);
create index if not exists rooms_created_by_idx on public.rooms (created_by);

drop policy if exists rm_read on public.room_members;
drop policy if exists rm_ins on public.room_members;
drop policy if exists rm_del on public.room_members;
create policy rm_read on public.room_members for select to authenticated using (room_id = any((select public.visible_room_ids())::uuid[]));
create policy rm_ins on public.room_members for insert to authenticated with check (room_id = any((select public.admin_room_ids())::uuid[]));
create policy rm_del on public.room_members for delete to authenticated using (room_id = any((select public.admin_room_ids())::uuid[]) or user_id = (select auth.uid()));
create index if not exists room_members_user_idx on public.room_members (user_id);

drop policy if exists msg_read on public.room_messages;
drop policy if exists msg_ins on public.room_messages;
drop policy if exists msg_upd on public.room_messages;            -- M1: no client updates at all; translations are written by the AI function
drop policy if exists msg_del on public.room_messages;
revoke update on public.room_messages from anon, authenticated;
create policy msg_read on public.room_messages for select to authenticated using (room_id = any((select public.visible_room_ids())::uuid[]));
create policy msg_ins on public.room_messages for insert to authenticated with check (user_id = (select auth.uid()) and room_id = any((select public.postable_room_ids())::uuid[]));
create policy msg_del on public.room_messages for delete to authenticated using (user_id = (select auth.uid()) or room_id = any((select public.admin_room_ids())::uuid[]));
create index if not exists room_messages_user_idx on public.room_messages (user_id);

-- storage
drop policy if exists avatars_read on storage.objects;              -- L1: public bucket files are served by URL; no listing
drop policy if exists avatars_ins on storage.objects;
drop policy if exists avatars_upd on storage.objects;
drop policy if exists avatars_del on storage.objects;
create policy avatars_read on storage.objects for select to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_ins on storage.objects for insert to authenticated with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_upd on storage.objects for update to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_del on storage.objects for delete to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists rooms_files_read on storage.objects;
drop policy if exists rooms_files_ins on storage.objects;
drop policy if exists rooms_files_del on storage.objects;
create policy rooms_files_read on storage.objects for select to authenticated using (bucket_id = 'rooms' and (storage.foldername(name))[1] = any((select public.visible_room_folders())::text[]));
create policy rooms_files_ins on storage.objects for insert to authenticated with check (bucket_id = 'rooms' and (storage.foldername(name))[1] = any((select public.postable_room_folders())::text[]));
create policy rooms_files_del on storage.objects for delete to authenticated using (bucket_id = 'rooms' and (storage.foldername(name))[1] = any((select public.admin_room_folders())::text[]));

-- remaining unindexed foreign keys
create index if not exists departments_company_idx on public.departments (company_id);

do $$ declare f text; begin
  foreach f in array array['visible_room_ids()','postable_room_ids()','admin_room_ids()','visible_room_folders()','postable_room_folders()','admin_room_folders()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
-- old per-row helper no longer used by any policy
revoke execute on function public.can_access(uuid, uuid) from authenticated;
