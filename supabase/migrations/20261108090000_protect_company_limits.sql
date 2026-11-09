-- Found during the production rollout (2026-11-09): migration 06 added companies.ai_monthly_budget_usd and
-- ai_daily_user_limit, but protect_company() only pinned the codes / active / notes. A company admin could
-- therefore raise their own AI budget through a direct UPDATE (comp_upd allows admins to update their company),
-- and the platform owner pays the model bill. deleted_at is pinned too (soft deletion is owner-only).
-- Rollback: supabase/rollback/20261108090000_protect_company_limits.down.sql
create or replace function public.protect_company() returns trigger language plpgsql security invoker set search_path = 'public' as $$
begin
  if current_user in ('anon', 'authenticated') and not public.is_super() then
    new.join_code := old.join_code; new.admin_code := old.admin_code; new.active := old.active; new.notes := old.notes;
    new.ai_monthly_budget_usd := old.ai_monthly_budget_usd;
    new.ai_daily_user_limit := old.ai_daily_user_limit;
    new.deleted_at := old.deleted_at;
  end if;
  return new;
end $$;
