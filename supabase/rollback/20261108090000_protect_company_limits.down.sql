-- restores protect_company() as defined in 20261108010000_signup_codes_hardening.sql
create or replace function public.protect_company() returns trigger language plpgsql security invoker set search_path = 'public' as $$
begin
  if current_user in ('anon', 'authenticated') and not public.is_super() then
    new.join_code := old.join_code; new.admin_code := old.admin_code; new.active := old.active; new.notes := old.notes;
  end if;
  return new;
end $$;
