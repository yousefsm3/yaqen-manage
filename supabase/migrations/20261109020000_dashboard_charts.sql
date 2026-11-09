-- Dashboard charts (UI refresh). One read-only call that returns the series the home dashboard draws.
-- SECURITY INVOKER: every number is computed over the rows the caller may already read (RLS), exactly like
-- dashboard_stats. Nothing new becomes visible: a fleet employee gets zeros for finance, another company gets zeros.
-- Basis for money by month: invoice due_date (same basis as report_profit_comparison). No profit, no estimates.

create or replace function public.dashboard_charts(cid uuid) returns jsonb
language sql stable security invoker set search_path = 'public' as $$
  with m as (
    select generate_series(date_trunc('month', current_date) - interval '11 months', date_trunc('month', current_date), interval '1 month')::date as m
  ),
  inv as (
    select date_trunc('month', due_date)::date m, kind, status, amount, due_date
    from invoices where company_id = cid and due_date is not null
      and due_date >= (date_trunc('month', current_date) - interval '11 months')::date
      and due_date < (date_trunc('month', current_date) + interval '1 month')::date
  ),
  unpaid as (
    select amount, current_date - due_date d from invoices
    where company_id = cid and kind = 'صادرة' and status <> 'مدفوعة'
  )
  select jsonb_build_object(
    'as_of', now(),
    'monthly', (select coalesce(jsonb_agg(jsonb_build_object(
        'month', to_char(m.m, 'YYYY-MM'),
        'issued',    coalesce((select sum(amount) from inv where inv.m = m.m and kind = 'صادرة'), 0),
        'incoming',  coalesce((select sum(amount) from inv where inv.m = m.m and kind = 'واردة'), 0),
        'collected', coalesce((select sum(amount) from inv where inv.m = m.m and kind = 'صادرة' and status = 'مدفوعة'), 0)
      ) order by m.m), '[]'::jsonb) from m),
    'aging', jsonb_build_object(
        'not_due', (select coalesce(sum(amount), 0) from unpaid where d is null or d <= 0),
        'd1_30',   (select coalesce(sum(amount), 0) from unpaid where d between 1 and 30),
        'd31_60',  (select coalesce(sum(amount), 0) from unpaid where d between 31 and 60),
        'd61_90',  (select coalesce(sum(amount), 0) from unpaid where d between 61 and 90),
        'd90_plus',(select coalesce(sum(amount), 0) from unpaid where d > 90)),
    'fleet', (select coalesce(jsonb_object_agg(coalesce(status, 'بدون حالة'), n), '{}'::jsonb)
              from (select status, count(*) n from vehicles where company_id = cid group by status) x),
    'projects', (select coalesce(jsonb_object_agg(coalesce(status, 'بدون حالة'), n), '{}'::jsonb)
              from (select status, count(*) n from projects where company_id = cid group by status) x),
    'receivables_by_dept', (select coalesce(jsonb_agg(jsonb_build_object('department', coalesce(dp.name, 'بدون قسم'), 'amount', x.s) order by x.s desc), '[]'::jsonb)
              from (select department_id, sum(amount) s from invoices where company_id = cid and kind = 'صادرة' and status <> 'مدفوعة'
                    group by department_id order by sum(amount) desc limit 6) x
              left join departments dp on dp.id = x.department_id),
    'expiry', jsonb_build_object(
        'expired', (select count(*) from documents where company_id = cid and expiry_date < current_date)
                 + (select count(*) from vehicles v, lateral (values (v.registration_expiry), (v.insurance_expiry), (v.license_expiry)) w(dt)
                    where v.company_id = cid and w.dt < current_date),
        'd30',     (select count(*) from documents where company_id = cid and expiry_date between current_date and current_date + 30)
                 + (select count(*) from vehicles v, lateral (values (v.registration_expiry), (v.insurance_expiry), (v.license_expiry)) w(dt)
                    where v.company_id = cid and w.dt between current_date and current_date + 30),
        'd90',     (select count(*) from documents where company_id = cid and expiry_date between current_date + 31 and current_date + 90)
                 + (select count(*) from vehicles v, lateral (values (v.registration_expiry), (v.insurance_expiry), (v.license_expiry)) w(dt)
                    where v.company_id = cid and w.dt between current_date + 31 and current_date + 90))
  ) $$;

revoke execute on function public.dashboard_charts(uuid) from public, anon;
grant execute on function public.dashboard_charts(uuid) to authenticated;
