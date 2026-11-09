-- NOTE: codes rotated by the up-migration are not restored (old weak codes are not kept on purpose).
drop function if exists public.my_account(), public.invite_platform_admin(text), public.regenerate_company_codes(uuid, text),
  public.set_member_status(uuid, text), public.approve_member(uuid, uuid, text);
drop table if exists public.platform_admin_invites;
drop function if exists public.lookup_company(text);
create function public.lookup_company(code text) returns json language sql stable security definer set search_path to 'public' as $f$
  select json_build_object('id', c.id, 'name', c.name, 'logo_url', c.logo_url,
    'is_admin_code', upper(trim(code)) = c.admin_code,
    'departments', coalesce((select json_agg(json_build_object('id', d.id, 'name', d.name, 'icon', d.icon) order by d.created_at) from departments d where d.company_id = c.id), '[]'::json))
  from companies c where c.active and (c.join_code = upper(trim(code)) or c.admin_code = upper(trim(code))) limit 1; $f$;
grant execute on function public.lookup_company(text) to anon, authenticated;
drop table if exists public.code_lookup_attempts;
drop function if exists public.request_ip();
create or replace function public.my_company() returns uuid language sql stable security definer set search_path to 'public' as $f$
  select p.company_id from profiles p join companies c on c.id = p.company_id where p.id = auth.uid() and c.active; $f$;
create or replace function public.is_company_admin() returns boolean language sql stable security definer set search_path to 'public' as $f$
  select exists(select 1 from profiles p join companies c on c.id = p.company_id where p.id = auth.uid() and p.role = 'admin' and c.active); $f$;
create or replace function public.my_department() returns uuid language sql stable security definer set search_path to 'public' as $f$
  select department_id from profiles where id = auth.uid(); $f$;
create or replace function public.is_super() returns boolean language sql stable security definer set search_path to 'public' as $f$
  select exists(select 1 from profiles where id = auth.uid() and role = 'super_admin'); $f$;
-- sign-up trigger: restore baseline behaviour, but WITHOUT a hard-coded owner e-mail (owner account already exists)
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path to 'public' as $f$
declare comp companies%rowtype; code text; dep uuid; r text := 'employee';
begin
  code := upper(trim(coalesce(new.raw_user_meta_data->>'company_code','')));
  select * into comp from companies where active and (join_code = code or admin_code = code) limit 1;
  if comp.id is null then raise exception 'INVALID_COMPANY_CODE'; end if;
  if comp.admin_code = code then r := 'admin'; end if;
  begin dep := nullif(new.raw_user_meta_data->>'department_id','')::uuid; exception when others then dep := null; end;
  if dep is not null and not exists(select 1 from departments where id = dep and company_id = comp.id) then dep := null; end if;
  insert into profiles (id, company_id, full_name, email, phone, job_title, department_id, role)
  values (new.id, comp.id, coalesce(new.raw_user_meta_data->>'full_name',''), new.email,
    new.raw_user_meta_data->>'phone', new.raw_user_meta_data->>'job_title', dep, r);
  return new;
end; $f$;
create or replace function public.protect_company() returns trigger language plpgsql security definer set search_path to 'public' as $f$
begin
  if not public.is_super() then
    new.join_code := old.join_code; new.admin_code := old.admin_code; new.active := old.active; new.notes := old.notes;
  end if;
  return new;
end; $f$;
create or replace function public.protect_profile() returns trigger language plpgsql security definer set search_path to 'public' as $f$
begin
  if public.is_super() then return new; end if;
  new.company_id := old.company_id;
  if old.role = 'super_admin' then new.role := old.role; end if;
  if new.role = 'super_admin' then new.role := old.role; end if;
  if not public.can_manage(old.company_id) then
    new.role := old.role;
    if old.department_id is not null then new.department_id := old.department_id; end if;
  end if;
  if new.department_id is not null and not exists(select 1 from departments where id = new.department_id and company_id = old.company_id) then
    new.department_id := old.department_id; end if;
  return new;
end; $f$;
alter table public.profiles drop column if exists approved_at, drop column if exists approved_by,
  drop column if exists requested_department_id, drop column if exists status;
alter table public.companies alter column join_code set default upper(substr(md5((random())::text), 1, 6));
alter table public.companies alter column admin_code set default upper(substr(md5((random())::text), 1, 10));
drop function if exists public.secure_code(int);
