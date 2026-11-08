-- WARNING: rows that are soft-deleted become visible again after rollback (deleted_at column is dropped).
drop index if exists public.vehicles_company_plate_uniq, public.invoices_company_out_number_uniq,
  public.invoices_company_in_number_party_uniq, public.legal_cases_company_number_uniq;
drop function if exists public.norm_key(text);
drop function if exists public.restore_company(uuid), public.purge_deleted(interval), public.list_trash(uuid),
  public.restore_deleted(text, uuid), public.soft_delete(text, uuid);
create or replace function public.delete_company(target uuid) returns void language plpgsql security definer set search_path to 'public', 'auth' as $f$
begin
  if not public.is_super() then raise exception 'غير مصرح'; end if;
  delete from auth.users where id in (select id from profiles where company_id = target and role <> 'super_admin');
  delete from companies where id = target;
end; $f$;
do $$ declare t text; begin
  foreach t in array array['vehicles','projects','legal_cases','invoices','documents','requests','manager_notes'] loop
    execute format('drop trigger if exists %1$s_guard_soft_delete on public.%1$s', t);
    execute format('alter table public.%I drop column if exists deleted_by cascade, drop column if exists deleted_at cascade', t);
    execute format('grant delete on public.%I to authenticated', t);
  end loop;
  foreach t in array array['vehicles','projects','legal_cases','invoices','documents','requests'] loop
    execute format('create policy %1$s_del on public.%1$s for delete to authenticated using (can_manage(company_id))', t);
    execute format('drop policy if exists %1$s_read on public.%1$s; drop policy if exists %1$s_upd on public.%1$s', t);
    execute format('create policy %1$s_read on public.%1$s for select to authenticated using (can_access(company_id, department_id))', t);
    execute format('create policy %1$s_upd on public.%1$s for update to authenticated using (can_access(company_id, department_id)) with check (can_access(company_id, department_id))', t);
  end loop;
end $$;
drop policy if exists notes_read on public.manager_notes; drop policy if exists notes_upd on public.manager_notes;
create policy notes_read on public.manager_notes for select to authenticated using (can_access(company_id, department_id));
create policy notes_upd on public.manager_notes for update to authenticated using (can_access(company_id, department_id));
create policy notes_del on public.manager_notes for delete to authenticated using (can_manage(company_id));
alter table public.companies drop column if exists deleted_at;
drop function if exists public.guard_soft_delete();
