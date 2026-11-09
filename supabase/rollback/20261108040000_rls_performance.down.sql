-- Restores the baseline policy definitions (slow per-row form) while keeping later columns (deleted_at, status).
do $$ declare t text; begin
  foreach t in array array['vehicles','projects','legal_cases','invoices','documents','requests'] loop
    execute format('drop policy if exists %1$s_read on public.%1$s; drop policy if exists %1$s_ins on public.%1$s; drop policy if exists %1$s_upd on public.%1$s', t);
    execute format('create policy %1$s_read on public.%1$s for select to authenticated using (deleted_at is null and can_access(company_id, department_id))', t);
    execute format('create policy %1$s_ins on public.%1$s for insert to authenticated with check (can_access(company_id, department_id))', t);
    execute format('create policy %1$s_upd on public.%1$s for update to authenticated using (can_access(company_id, department_id)) with check (can_access(company_id, department_id))', t);
    execute format('drop index if exists public.%1$s_company_updated_idx, public.%1$s_company_dept_idx, public.%1$s_department_idx, public.%1$s_created_by_idx, public.%1$s_deleted_by_idx', t);
  end loop;
end $$;
grant execute on function public.can_access(uuid, uuid) to authenticated;
drop policy if exists notes_read on public.manager_notes; drop policy if exists notes_ins on public.manager_notes; drop policy if exists notes_upd on public.manager_notes;
create policy notes_read on public.manager_notes for select to authenticated using (deleted_at is null and can_access(company_id, department_id));
create policy notes_ins on public.manager_notes for insert to authenticated with check (can_manage(company_id));
create policy notes_upd on public.manager_notes for update to authenticated using (can_access(company_id, department_id));
drop index if exists public.manager_notes_company_created_idx, public.manager_notes_department_idx, public.manager_notes_created_by_idx, public.manager_notes_replied_by_idx, public.manager_notes_deleted_by_idx;
drop policy if exists comp_read on public.companies; drop policy if exists comp_ins on public.companies; drop policy if exists comp_upd on public.companies;
create policy comp_read on public.companies for select to authenticated using ((is_super() or (id = my_company())));
create policy comp_ins on public.companies for insert to authenticated with check (is_super());
create policy comp_upd on public.companies for update to authenticated using (can_manage(id)) with check (can_manage(id));
create policy comp_del on public.companies for delete to authenticated using (is_super());
grant delete on public.companies to authenticated;
drop policy if exists dep_read on public.departments; drop policy if exists dep_ins on public.departments; drop policy if exists dep_upd on public.departments; drop policy if exists dep_del on public.departments;
create policy dep_read on public.departments for select to authenticated using ((is_super() or (company_id = my_company())));
create policy dep_ins on public.departments for insert to authenticated with check (can_manage(company_id));
create policy dep_upd on public.departments for update to authenticated using (can_manage(company_id)) with check (can_manage(company_id));
create policy dep_del on public.departments for delete to authenticated using (can_manage(company_id));
drop policy if exists prof_read on public.profiles; drop policy if exists prof_upd on public.profiles;
create policy prof_read on public.profiles for select to authenticated using (((id = auth.uid()) or is_super() or ((company_id = my_company()) and (is_company_admin() or (department_id = my_department())))));
create policy prof_upd on public.profiles for update to authenticated using (((id = auth.uid()) or can_manage(company_id))) with check (((id = auth.uid()) or can_manage(company_id)));
drop index if exists public.profiles_company_idx, public.profiles_department_idx, public.profiles_requested_department_idx, public.profiles_approved_by_idx, public.profiles_company_status_idx;
drop policy if exists rooms_read on public.rooms; drop policy if exists rooms_ins on public.rooms; drop policy if exists rooms_upd on public.rooms; drop policy if exists rooms_del on public.rooms;
create policy rooms_read on public.rooms for select to authenticated using ((can_manage(company_id) or ((company_id = my_company()) and ((created_by = auth.uid()) or is_room_member(id)))));
create policy rooms_ins on public.rooms for insert to authenticated with check (((company_id = my_company()) or is_super()));
create policy rooms_upd on public.rooms for update to authenticated using ((can_manage(company_id) or ((company_id = my_company()) and (created_by = auth.uid())))) with check ((can_manage(company_id) or ((company_id = my_company()) and (created_by = auth.uid()))));
create policy rooms_del on public.rooms for delete to authenticated using ((can_manage(company_id) or ((company_id = my_company()) and (created_by = auth.uid()))));
drop index if exists public.rooms_company_idx, public.rooms_created_by_idx;
-- restore baseline room helpers (per-row)
create or replace function public.can_see_room(r uuid) returns boolean language sql stable security definer set search_path to 'public' as $f$
  select exists(select 1 from rooms where id = r and (public.can_manage(company_id) or (company_id = public.my_company() and public.is_room_member(r)))); $f$;
create or replace function public.can_admin_room(r uuid) returns boolean language sql stable security definer set search_path to 'public' as $f$
  select exists(select 1 from rooms where id = r and (public.can_manage(company_id) or (company_id = public.my_company() and created_by = auth.uid()))); $f$;
create or replace function public.can_post_room(r uuid) returns boolean language sql stable security definer set search_path to 'public' as $f$
  select exists(select 1 from rooms where id = r and status = 'مفتوحة' and (public.can_manage(company_id) or (company_id = public.my_company() and public.is_room_member(r)))); $f$;
drop policy if exists rm_read on public.room_members; drop policy if exists rm_ins on public.room_members; drop policy if exists rm_del on public.room_members;
create policy rm_read on public.room_members for select to authenticated using (can_see_room(room_id));
create policy rm_ins on public.room_members for insert to authenticated with check (can_admin_room(room_id));
create policy rm_del on public.room_members for delete to authenticated using ((can_admin_room(room_id) or (user_id = auth.uid())));
drop index if exists public.room_members_user_idx;
drop policy if exists msg_read on public.room_messages; drop policy if exists msg_ins on public.room_messages; drop policy if exists msg_del on public.room_messages;
grant update on public.room_messages to authenticated;
create policy msg_read on public.room_messages for select to authenticated using (can_see_room(room_id));
create policy msg_ins on public.room_messages for insert to authenticated with check (((user_id = auth.uid()) and can_post_room(room_id)));
create policy msg_upd on public.room_messages for update to authenticated using (can_see_room(room_id)) with check (can_see_room(room_id));
create policy msg_del on public.room_messages for delete to authenticated using (((user_id = auth.uid()) or can_admin_room(room_id)));
drop index if exists public.room_messages_user_idx, public.departments_company_idx;
drop policy if exists avatars_read on storage.objects; drop policy if exists avatars_ins on storage.objects; drop policy if exists avatars_upd on storage.objects; drop policy if exists avatars_del on storage.objects;
create policy avatars_read on storage.objects for select to public using ((bucket_id = 'avatars'::text));
create policy avatars_ins on storage.objects for insert to authenticated with check (((bucket_id = 'avatars'::text) and ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy avatars_upd on storage.objects for update to authenticated using (((bucket_id = 'avatars'::text) and ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy avatars_del on storage.objects for delete to authenticated using (((bucket_id = 'avatars'::text) and ((storage.foldername(name))[1] = (auth.uid())::text)));
drop policy if exists rooms_files_read on storage.objects; drop policy if exists rooms_files_ins on storage.objects; drop policy if exists rooms_files_del on storage.objects;
create policy rooms_files_read on storage.objects for select to authenticated using (((bucket_id = 'rooms'::text) and can_see_room(((storage.foldername(name))[1])::uuid)));
create policy rooms_files_ins on storage.objects for insert to authenticated with check (((bucket_id = 'rooms'::text) and can_post_room(((storage.foldername(name))[1])::uuid)));
create policy rooms_files_del on storage.objects for delete to authenticated using (((bucket_id = 'rooms'::text) and can_admin_room(((storage.foldername(name))[1])::uuid)));
drop function if exists public.visible_room_folders(), public.postable_room_folders(), public.admin_room_folders(),
  public.visible_room_ids(), public.postable_room_ids(), public.admin_room_ids();
