-- the company admin opens the dashboard: stats + alerts + department summary, under RLS
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0001-000000000001","role":"authenticated","aal":"aal1"}', true);
SET LOCAL ROLE authenticated;
SELECT public.dashboard_stats('00000000-0000-0000-0000-00000000aaaa');
SELECT count(*) FROM public.company_alerts('00000000-0000-0000-0000-00000000aaaa', 300);
SELECT count(*) FROM public.department_summary('00000000-0000-0000-0000-00000000aaaa');
END;
