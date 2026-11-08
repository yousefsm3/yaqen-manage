-- M5: optional server-enforced two-factor authentication (TOTP) for company admins.
-- When companies.require_admin_mfa is true, an admin whose session is not aal2 (no TOTP code entered)
-- loses admin powers for that session: is_company_admin() returns false, so RLS treats them as a normal employee.
-- Default false so existing admins are not locked out at deploy; the platform owner turns it on per company
-- after the admin has enrolled a factor in the UI.
alter table public.companies add column if not exists require_admin_mfa boolean not null default false;

create or replace function public.session_aal() returns text language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'aal', 'aal1') $$;

create or replace function public.is_company_admin() returns boolean language sql stable security definer set search_path = 'public' as $$
  select exists(select 1 from profiles p join companies c on c.id = p.company_id
    where p.id = auth.uid() and p.role = 'admin' and p.status = 'active' and c.active
      and (not c.require_admin_mfa or public.session_aal() = 'aal2')) $$;

-- only the platform owner may switch the requirement (protect_company already blocks other columns for admins;
-- this keeps the rule explicit for the new column)
create or replace function public.guard_require_mfa() returns trigger language plpgsql security invoker set search_path = 'public' as $$
begin
  if new.require_admin_mfa is distinct from old.require_admin_mfa
     and current_user in ('anon', 'authenticated') and not public.is_super() then
    new.require_admin_mfa := old.require_admin_mfa;
  end if;
  return new;
end $$;
drop trigger if exists guard_require_mfa on public.companies;
create trigger guard_require_mfa before update on public.companies for each row execute function public.guard_require_mfa();

-- my_account() also reports whether this session must step up to aal2
create or replace function public.my_account() returns json
language sql stable security definer set search_path = 'public' as $$
  select json_build_object('id', p.id, 'status', p.status, 'role', p.role, 'company_id', p.company_id,
    'company_name', c.name, 'company_active', c.active,
    'mfa_required', (p.role = 'admin' and coalesce(c.require_admin_mfa, false)),
    'aal', public.session_aal())
  from profiles p left join companies c on c.id = p.company_id where p.id = auth.uid() $$;
