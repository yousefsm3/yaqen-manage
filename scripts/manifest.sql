-- Fingerprint used to prove a restore is complete: per-table row count + checksum, and object counts
-- (policies, triggers, indexes, constraints, functions). Output is stable and diffable.
select format('table|%s|%s|%s', t.relname,
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', t.relname), false, true, '')))[1]::text,
  (xpath('/row/h/text()', query_to_xml(format('select md5(coalesce(string_agg(x::text, ''|'' order by x::text), '''')) as h from public.%I x', t.relname), false, true, '')))[1]::text)
from pg_class t join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public' and t.relkind = 'r'
union all select 'objects|policies|' || count(*) from pg_policies where schemaname in ('public', 'storage')
union all select 'objects|triggers|' || count(*) from pg_trigger g join pg_class c on c.oid = g.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not g.tgisinternal
union all select 'objects|indexes|' || count(*) from pg_indexes where schemaname = 'public'
union all select 'objects|constraints|' || count(*) from pg_constraint k join pg_namespace n on n.oid = k.connamespace where n.nspname = 'public'
union all select 'objects|functions|' || count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
union all select 'objects|rls_enabled_tables|' || count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
union all select 'objects|api_table_grants|' || count(*) from information_schema.role_table_grants where table_schema = 'public' and grantee in ('anon', 'authenticated', 'service_role')
union all select 'objects|api_function_grants|' || count(*) from information_schema.role_routine_grants where routine_schema = 'public' and grantee in ('anon', 'authenticated', 'service_role')
union all select 'objects|schema_usage|' || string_agg(r, ',' order by r) from unnest(array['anon', 'authenticated', 'service_role']) r where has_schema_privilege(r, 'public', 'USAGE')
union all select 'objects|auth_users|' || coalesce((xpath('/row/c/text()', query_to_xml('select count(*) as c from auth.users', false, true, '')))[1]::text, '-') where to_regclass('auth.users') is not null
union all select 'objects|storage_objects|' || coalesce((xpath('/row/c/text()', query_to_xml('select count(*) as c from storage.objects', false, true, '')))[1]::text, '-') where to_regclass('storage.objects') is not null
order by 1;
