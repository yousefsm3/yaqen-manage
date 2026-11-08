do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobname) from cron.job where jobname in ('yaqen-daily-notifications','yaqen-purge-deleted','yaqen-trim-events');
  end if;
end $$;
drop function if exists public.health();
drop function if exists public.log_client_error(text, jsonb);
drop table if exists public.system_events;
drop function if exists public.generate_notifications();
drop table if exists public.notifications;
drop function if exists public.ai_usage_summary(uuid);
drop function if exists public.record_ai_usage(uuid, uuid, text, text, int, int, numeric, boolean);
drop function if exists public.ai_quota_ok(uuid, uuid);
drop table if exists public.ai_usage;
alter table public.companies drop column if exists ai_daily_user_limit, drop column if exists ai_monthly_budget_usd;
