drop trigger if exists guard_require_mfa on public.companies;
drop function if exists public.guard_require_mfa();
create or replace function public.is_company_admin() returns boolean language sql stable security definer set search_path = 'public' as $$
  select exists(select 1 from profiles p join companies c on c.id = p.company_id
    where p.id = auth.uid() and p.role = 'admin' and p.status = 'active' and c.active) $$;
create or replace function public.my_account() returns json
language sql stable security definer set search_path = 'public' as $$
  select json_build_object('id', p.id, 'status', p.status, 'role', p.role, 'company_id', p.company_id,
    'company_name', c.name, 'company_active', c.active)
  from profiles p left join companies c on c.id = p.company_id where p.id = auth.uid() $$;
drop function if exists public.session_aal();
alter table public.companies drop column if exists require_admin_mfa;
