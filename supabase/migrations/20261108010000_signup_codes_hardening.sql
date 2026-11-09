-- Fixes: C3 (self-selected department, guessable join, no approval), M4 (weak code generation),
--        M7 (platform owner hard-coded by e-mail), L2 (maintenance blocked by protect_company).
-- Rollback: supabase/rollback/20261108010000_signup_codes_hardening.down.sql

-- ---------- M4: cryptographically secure codes ----------
-- 32-symbol alphabet (no 0/O/1/I), 5 bits per char, uniform because 256 % 32 = 0.
create or replace function public.secure_code(len int) returns text
language sql volatile set search_path = '' as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', (get_byte(b, i) % 32) + 1, 1), '' order by i)
  from (select extensions.gen_random_bytes(len) as b) x, generate_series(0, len - 1) as i
$$;
revoke execute on function public.secure_code(int) from public, anon, authenticated;

alter table public.companies alter column join_code set default public.secure_code(12);
alter table public.companies alter column admin_code set default public.secure_code(16);
-- (existing weak codes are rotated further below, AFTER protect_company is replaced:
--  the old trigger silently reverts code changes - found during the production rollout.)

-- ---------- C3: membership status + approval ----------
alter table public.profiles add column if not exists status text not null default 'active'
  check (status in ('pending', 'active', 'disabled'));
alter table public.profiles add column if not exists requested_department_id uuid references public.departments(id) on delete set null;
alter table public.profiles add column if not exists approved_by uuid references auth.users(id) on delete set null;
alter table public.profiles add column if not exists approved_at timestamptz;

-- context helpers now require an ACTIVE membership in an ACTIVE company
create or replace function public.my_company() returns uuid language sql stable security definer set search_path = 'public' as $$
  select p.company_id from profiles p join companies c on c.id = p.company_id
  where p.id = auth.uid() and p.status = 'active' and c.active $$;
create or replace function public.is_company_admin() returns boolean language sql stable security definer set search_path = 'public' as $$
  select exists(select 1 from profiles p join companies c on c.id = p.company_id
    where p.id = auth.uid() and p.role = 'admin' and p.status = 'active' and c.active) $$;
create or replace function public.my_department() returns uuid language sql stable security definer set search_path = 'public' as $$
  select department_id from profiles where id = auth.uid() and status = 'active' $$;
create or replace function public.is_super() returns boolean language sql stable security definer set search_path = 'public' as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'super_admin' and status = 'active') $$;

-- ---------- C3: brute-force protection for code lookups ----------
create table if not exists public.code_lookup_attempts (
  id bigint generated always as identity primary key,
  ip text not null,
  ok boolean not null,
  at timestamptz not null default now()
);
create index if not exists code_lookup_attempts_ip_at_idx on public.code_lookup_attempts (ip, at desc);
alter table public.code_lookup_attempts enable row level security; -- no policies: API cannot read or write it
revoke all on public.code_lookup_attempts from anon, authenticated;

create or replace function public.request_ip() returns text language sql stable set search_path = '' as $$
  select coalesce(nullif(split_part(coalesce(current_setting('request.headers', true), '{}')::json ->> 'x-forwarded-for', ',', 1), ''), 'unknown') $$;

drop function if exists public.lookup_company(text);
create function public.lookup_company(code text) returns json
language plpgsql volatile security definer set search_path = 'public' as $$
declare v_ip text := public.request_ip(); fails int; c companies%rowtype; k text := upper(trim(coalesce(code, '')));
begin
  select count(*) into fails from code_lookup_attempts where ip = v_ip and not ok and at > now() - interval '15 minutes';
  if fails >= 30 then raise exception 'TOO_MANY_ATTEMPTS' using errcode = 'P0001'; end if;
  if (select count(*) from code_lookup_attempts where not ok and at > now() - interval '1 minute') >= 2000 then
    raise exception 'TOO_MANY_ATTEMPTS' using errcode = 'P0001';
  end if;
  select * into c from companies where active and (join_code = k or admin_code = k) limit 1;
  insert into code_lookup_attempts (ip, ok) values (v_ip, c.id is not null);
  if random() < 0.01 then delete from code_lookup_attempts where at < now() - interval '2 days'; end if;
  if c.id is null then return null; end if;
  -- no department ids: employees no longer choose a department themselves
  return json_build_object('name', c.name, 'logo_url', c.logo_url, 'is_admin_code', c.admin_code = k);
end $$;
revoke execute on function public.lookup_company(text) from public;
grant execute on function public.lookup_company(text) to anon, authenticated;

-- ---------- M7: platform admins by invitation, not a hard-coded e-mail ----------
create table if not exists public.platform_admin_invites (
  email text primary key check (email = lower(email)),
  invited_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.platform_admin_invites enable row level security;
revoke all on public.platform_admin_invites from anon, authenticated;

-- ---------- sign-up trigger (C3 + M7) ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = 'public' as $$
declare comp companies%rowtype; k text; req uuid; is_admin_code boolean;
begin
  -- platform admin invitation (one-time)
  if exists (select 1 from platform_admin_invites where email = lower(new.email)) then
    delete from platform_admin_invites where email = lower(new.email);
    insert into profiles (id, full_name, email, phone, role, status)
    values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''), new.email, new.raw_user_meta_data->>'phone', 'super_admin', 'active');
    return new;
  end if;
  k := upper(trim(coalesce(new.raw_user_meta_data->>'company_code', '')));
  select * into comp from companies where active and (join_code = k or admin_code = k) limit 1;
  if comp.id is null then raise exception 'INVALID_COMPANY_CODE'; end if;
  is_admin_code := (comp.admin_code = k);
  begin req := nullif(new.raw_user_meta_data->>'department_id', '')::uuid; exception when others then req := null; end;
  if req is not null and not exists (select 1 from departments where id = req and company_id = comp.id) then req := null; end if;
  insert into profiles (id, company_id, full_name, email, phone, job_title, department_id, requested_department_id, role, status)
  values (new.id, comp.id, coalesce(new.raw_user_meta_data->>'full_name', ''), new.email,
    new.raw_user_meta_data->>'phone', new.raw_user_meta_data->>'job_title',
    null,                                   -- department is ASSIGNED by an admin, never self-selected
    case when is_admin_code then null else req end,
    case when is_admin_code then 'admin' else 'employee' end,
    case when is_admin_code then 'active' else 'pending' end);
  -- admin code is single-use: rotate it immediately
  if is_admin_code then update companies set admin_code = public.secure_code(16) where id = comp.id; end if;
  return new;
end $$;

-- ---------- L2 + trusted contexts in protection triggers ----------
-- SECURITY INVOKER so current_user is the real caller: API callers are anon/authenticated;
-- migrations, maintenance jobs and our own SECURITY DEFINER functions run as the owner and are trusted.
create or replace function public.protect_company() returns trigger language plpgsql security invoker set search_path = 'public' as $$
begin
  if current_user in ('anon', 'authenticated') and not public.is_super() then
    new.join_code := old.join_code; new.admin_code := old.admin_code; new.active := old.active; new.notes := old.notes;
  end if;
  return new;
end $$;

create or replace function public.protect_profile() returns trigger language plpgsql security invoker set search_path = 'public' as $$
begin
  if current_user not in ('anon', 'authenticated') then return new; end if;   -- trusted context
  if public.is_super() then return new; end if;
  new.company_id := old.company_id;
  new.approved_by := old.approved_by; new.approved_at := old.approved_at;
  if old.role = 'super_admin' or new.role = 'super_admin' then new.role := old.role; end if;
  if not public.can_manage(old.company_id) then
    -- employees may edit name / phone / job title / avatar only
    new.role := old.role; new.status := old.status; new.department_id := old.department_id;
    new.requested_department_id := old.requested_department_id;
  elsif new.id = auth.uid() then
    new.role := old.role; new.status := old.status;          -- an admin cannot demote or disable themself by accident
  end if;
  if new.department_id is not null and not exists (select 1 from departments where id = new.department_id and company_id = old.company_id) then
    new.department_id := old.department_id;
  end if;
  return new;
end $$;

-- rotate existing weak codes (6 / 10 hex chars). Must run after the new protect_company above.
update public.companies set join_code = public.secure_code(12) where length(join_code) < 12;
update public.companies set admin_code = public.secure_code(16) where length(admin_code) < 16;

-- ---------- admin actions ----------
create or replace function public.approve_member(target uuid, dept uuid, new_role text default 'employee') returns void
language plpgsql security definer set search_path = 'public' as $$
declare t profiles%rowtype;
begin
  select * into t from profiles where id = target;
  if t.id is null then raise exception 'المستخدم غير موجود'; end if;
  if not public.can_manage(t.company_id) then raise exception 'غير مصرح'; end if;
  if new_role not in ('employee', 'admin') then raise exception 'صلاحية غير صحيحة'; end if;
  if dept is null or not exists (select 1 from departments where id = dept and company_id = t.company_id) then
    raise exception 'اختر قسماً من نفس الشركة';
  end if;
  update profiles set status = 'active', department_id = dept, role = new_role, requested_department_id = null,
    approved_by = auth.uid(), approved_at = now() where id = target;
end $$;

create or replace function public.set_member_status(target uuid, new_status text) returns void
language plpgsql security definer set search_path = 'public' as $$
declare t profiles%rowtype;
begin
  select * into t from profiles where id = target;
  if t.id is null then raise exception 'المستخدم غير موجود'; end if;
  if target = auth.uid() then raise exception 'لا يمكنك تغيير حالة حسابك'; end if;
  if t.role = 'super_admin' or not public.can_manage(t.company_id) then raise exception 'غير مصرح'; end if;
  if new_status not in ('active', 'disabled') then raise exception 'حالة غير صحيحة'; end if;
  update profiles set status = new_status where id = target;
end $$;

create or replace function public.regenerate_company_codes(target uuid, which text default 'both') returns json
language plpgsql security definer set search_path = 'public' as $$
begin
  if not public.is_super() and not (which = 'join' and public.can_manage(target)) then raise exception 'غير مصرح'; end if;
  update companies set
    join_code  = case when which in ('join', 'both') then public.secure_code(12) else join_code end,
    admin_code = case when which in ('admin', 'both') then public.secure_code(16) else admin_code end
  where id = target;
  return (select json_build_object('join_code', join_code, 'admin_code', case when public.is_super() then admin_code end) from companies where id = target);
end $$;

create or replace function public.invite_platform_admin(invite_email text) returns void
language plpgsql security definer set search_path = 'public' as $$
begin
  if not public.is_super() then raise exception 'غير مصرح'; end if;
  insert into platform_admin_invites (email, invited_by) values (lower(trim(invite_email)), auth.uid()) on conflict (email) do nothing;
end $$;

-- account state for the signed-in user (works while pending, when RLS hides the company)
create or replace function public.my_account() returns json
language sql stable security definer set search_path = 'public' as $$
  select json_build_object('id', p.id, 'status', p.status, 'role', p.role, 'company_id', p.company_id,
    'company_name', c.name, 'company_active', c.active)
  from profiles p left join companies c on c.id = p.company_id where p.id = auth.uid() $$;

do $$ declare f text; begin
  foreach f in array array['approve_member(uuid,uuid,text)','set_member_status(uuid,text)','regenerate_company_codes(uuid,text)',
                           'invite_platform_admin(text)','my_account()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
revoke execute on function public.request_ip() from public, anon, authenticated;
