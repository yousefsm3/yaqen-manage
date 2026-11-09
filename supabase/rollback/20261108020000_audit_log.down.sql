-- WARNING: drops the audit trail. Export it first: \copy public.audit_log to 'audit_log_backup.csv' csv header
do $$ declare t text; begin
  foreach t in array array['companies','departments','profiles','vehicles','projects','legal_cases','invoices','documents',
                           'requests','manager_notes','rooms','room_members','room_messages'] loop
    execute format('drop trigger if exists %1$s_audit on public.%1$s', t);
  end loop;
  foreach t in array array['vehicles','projects','legal_cases','invoices','documents','requests','manager_notes','rooms'] loop
    execute format('drop trigger if exists %1$s_created_by on public.%1$s', t);
  end loop;
end $$;
drop function if exists public.enforce_created_by(), public.audit_row(), public.audit_source();
drop table if exists public.audit_log;
