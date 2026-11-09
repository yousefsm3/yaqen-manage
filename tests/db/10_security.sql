-- Security, permission, multi-tenancy and integrity tests.
-- Each test states the CORRECT behaviour. On the baseline some fail: that is the "before" evidence.
\set A0 '''00000000-0000-0000-0000-0000000000a0'''
\set B0 '''00000000-0000-0000-0000-0000000000b0'''
\set OWNER '''00000000-0000-0000-0000-0000000000f0'''
\set A1 '''00000000-0000-0000-0000-0000000000a1'''
\set A2 '''00000000-0000-0000-0000-0000000000a2'''
\set A3 '''00000000-0000-0000-0000-0000000000a3'''
\set A4 '''00000000-0000-0000-0000-0000000000a4'''
\set B1 '''00000000-0000-0000-0000-0000000000b1'''
\set B2 '''00000000-0000-0000-0000-0000000000b2'''

-- ================= Multi-tenancy (MT) =================
select qa.expect('MT','B employee reads company A vehicle', qa.run(:B2, $$select count(*)::text from vehicles where id='00000000-0000-0000-0000-00000000c001'$$), '0');
select qa.expect('MT','B employee reads A invoices/profiles/rooms/messages', qa.run(:B2, $$select (select count(*) from invoices where company_id='00000000-0000-0000-0000-0000000000a0')||'/'||(select count(*) from profiles where company_id='00000000-0000-0000-0000-0000000000a0')||'/'||(select count(*) from rooms where company_id='00000000-0000-0000-0000-0000000000a0')||'/'||(select count(*) from room_messages)$$), '0/0/0/0');
select qa.expect_blocked('MT','B employee inserts vehicle into A', qa.run(:B2, $$with x as (insert into vehicles(plate, company_id) values ('HACK-1','00000000-0000-0000-0000-0000000000a0') returning 1) select count(*)::text from x$$));
select qa.expect_blocked('MT','B employee updates A vehicle', qa.run(:B2, $$with x as (update vehicles set plate='HACKED' where id='00000000-0000-0000-0000-00000000c001' returning 1) select count(*)::text from x$$));
select qa.expect_blocked('MT','A driver moves own vehicle to company B', qa.run(:A2, $$with x as (update vehicles set company_id='00000000-0000-0000-0000-0000000000b0', department_id=null where id='00000000-0000-0000-0000-00000000c001' returning 1) select count(*)::text from x$$));
select qa.expect_blocked('MT','A admin deletes B user', qa.run(:A1, $$select public.admin_delete_user('00000000-0000-0000-0000-0000000000b2')::text$$));
select qa.expect_blocked('MT','A admin deletes company B', qa.run(:A1, $$select public.delete_company('00000000-0000-0000-0000-0000000000b0')::text$$));
select qa.expect_blocked('MT','A admin renames company B', qa.run(:A1, $$with x as (update companies set name='pwned' where id='00000000-0000-0000-0000-0000000000b0' returning 1) select count(*)::text from x$$));
select qa.expect_blocked('MT','B employee lists A room files', qa.run(:B2, $$select count(*)::text from storage.objects where bucket_id='rooms'$$));
select qa.expect_blocked('MT','B employee joins A room', qa.run(:B2, $$with x as (insert into room_members values ('00000000-0000-0000-0000-0000000000e0','00000000-0000-0000-0000-0000000000b2', now()) returning 1) select count(*)::text from x$$));
select qa.expect_blocked('MT','A admin adds B employee to A room', qa.run(:A1, $$with x as (insert into room_members values ('00000000-0000-0000-0000-0000000000e0','00000000-0000-0000-0000-0000000000b2', now()) returning 1) select count(*)::text from x$$));
select qa.expect('MT','anon reads any business table', qa.run('anon', $$select ((select count(*) from vehicles)+(select count(*) from invoices)+(select count(*) from profiles)+(select count(*) from companies)+(select count(*) from room_messages))::text$$), '0');
select qa.expect('MT','owner (super) sees both companies', qa.run(:OWNER, $$select count(*)::text from companies where id in ('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000b0')$$), '2');

-- ================= Permissions (PERM) =================
select qa.expect('PERM','A driver (fleet) reads finance invoice', qa.run(:A2, $$select count(*)::text from invoices$$), '0');
select qa.expect('PERM','A finance (assigned by admin) reads finance invoice', qa.run(:A4, $$select count(*)::text from invoices$$), '1');
select qa.expect('PERM','A driver promotes self to admin', qa.run(:A2, $$with x as (update profiles set role='admin' where id='00000000-0000-0000-0000-0000000000a2' returning role) select role from x$$), 'employee');
select qa.expect_blocked('PERM','A driver creates department', qa.run(:A2, $$with x as (insert into departments(company_id,name) values ('00000000-0000-0000-0000-0000000000a0','x') returning 1) select count(*)::text from x$$));
select qa.expect('PERM','A driver marks manager note done / edits manager text', qa.run(:A2, $$with x as (update manager_notes set status='منجزة', body='edited' where id='00000000-0000-0000-0000-0000000000d1' returning status||'|'||body) select * from x$$), 'مفتوحة|جدد التأمين');
select qa.expect_blocked('PERM','A driver deletes admin message', qa.run(:A2, $$with x as (delete from room_messages where id='00000000-0000-0000-0000-0000000000e1' returning 1) select count(*)::text from x$$));

-- ================= C3: self-selected department / join codes =================
select qa.expect('C3','employee who picked Finance at sign-up reads finance invoice', qa.run(:A3, $$select count(*)::text from invoices$$), '0');
select qa.expect('C3','employee who picked a department at sign-up has no department until admin assigns', (select coalesce(department_id::text,'none') from profiles where id='00000000-0000-0000-0000-0000000000a3'), 'none');
select qa.check_sql('C3','new join-code sign-up is pending admin approval', $$select status = 'pending' from profiles where id='00000000-0000-0000-0000-0000000000a3'$$);
select qa.expect('C3','pending employee sees own company data', qa.run(:A3, $$select ((select count(*) from vehicles)+(select count(*) from departments)+(select count(*) from rooms))::text$$), '0');
select qa.expect_true('C3','admin code is single-use (rotated after the admin signed up)', (select admin_code from companies where id='00000000-0000-0000-0000-0000000000a0') <> 'QAADMINAAAAAAAAA', 'admin_code still the original');
-- brute force: 30 wrong guesses from one IP, then the 31st (even a correct one) is refused
do $$ declare i int; begin
  for i in 1..30 loop perform qa.run('anon', format($q$select coalesce(public.lookup_company('WRONG%s')::text,'none')$q$, i), '6.6.6.6'); end loop;
end $$;
select qa.expect_true('C3','lookup_company refuses after 30 failed guesses from one IP', qa.run('anon', $$select coalesce(public.lookup_company('QAJOINAAAAAA')::text,'none')$$, '6.6.6.6') like 'BLOCKED%', 'still answering after 30 failures');
select qa.expect_true('C3','lookup_company still works for a normal user from another IP', qa.run('anon', $$select coalesce(public.lookup_company('QAJOINBBBBBB')->>'name','none')$$, '7.7.7.7') = 'QA-B', '');
select qa.expect_true('C3','lookup_company does not reveal department ids to anonymous callers', coalesce(qa.run('anon', $$select (public.lookup_company('QAJOINBBBBBB')->'departments'->0->>'id') is null$$, '8.8.8.8'),'') = 'true', '');

-- ================= M4: code strength =================
insert into companies (id, name) values ('00000000-0000-0000-0000-0000000000c0','QA-C');
select qa.expect_true('M4','new company codes come from a CSPRNG (join >= 12, admin >= 16 chars)',
  (select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid=d.adrelid and a.attnum=d.adnum where d.adrelid='public.companies'::regclass and a.attname='join_code') ~ '(gen_random_bytes|secure_code)'
  and (not qa.has_function('secure_code') or pg_get_functiondef('public.secure_code'::regproc) like '%gen_random_bytes%')
  and (select length(join_code) >= 12 and length(admin_code) >= 16 from companies where id='00000000-0000-0000-0000-0000000000c0'),
  (select join_code||' / '||admin_code from companies where id='00000000-0000-0000-0000-0000000000c0'));
delete from companies where id='00000000-0000-0000-0000-0000000000c0';

-- ================= H3: audit trail / created_by =================
select qa.expect('H3','created_by cannot be spoofed on insert', qa.run(:A2, $$with x as (insert into vehicles(plate, company_id, department_id, created_by) values ('SPOOF 1','00000000-0000-0000-0000-0000000000a0',(select department_id from profiles where id='00000000-0000-0000-0000-0000000000a2'),'00000000-0000-0000-0000-0000000000a1') returning created_by) select created_by::text from x$$), '00000000-0000-0000-0000-0000000000a2');
select qa.check_sql('H3','audit log records the insert with the real actor', $$select exists(select 1 from audit_log where entity='vehicles' and action='insert' and actor='00000000-0000-0000-0000-0000000000a2' and after->>'plate'='SPOOF 1')$$);
select qa.run(:A2, $$with x as (update vehicles set location='Abqaiq' where plate='SPOOF 1' returning 1) select count(*)::text from x$$);
select qa.check_sql('H3','audit log records the update with before/after', $$select exists(select 1 from audit_log where entity='vehicles' and action='update' and actor='00000000-0000-0000-0000-0000000000a2' and after->>'location'='Abqaiq' and before->>'location' is null)$$);
select qa.expect_true('H3','company admin cannot edit the audit log', qa.has_table('audit_log') and qa.run(:A1, $$with x as (update audit_log set actor=null returning 1) select count(*)::text from x$$) ~ '^(0|BLOCKED: (permission|new row))', '');
select qa.expect_true('H3','company admin cannot delete the audit log', qa.has_table('audit_log') and qa.run(:A1, $$with x as (delete from audit_log returning 1) select count(*)::text from x$$) ~ '^(0|BLOCKED: permission)', '');
select qa.expect('H3','company admin sees only own company audit rows', qa.run(:B1, $$select count(*)::text from audit_log where company_id='00000000-0000-0000-0000-0000000000a0'$$), '0');
select qa.expect_true('H3','company admin sees own company audit rows', coalesce(nullif(qa.run(:A1, $$select count(*)::text from audit_log$$),'BLOCKED'),'0') ~ '^[1-9]', '');

-- ================= M1: translation integrity =================
select qa.expect_blocked('M1','room member overwrites translation of another user message', qa.run(:A2, $$with x as (update room_messages set translation='{"ar":"fake"}' where id='00000000-0000-0000-0000-0000000000e1' returning 1) select count(*)::text from x$$));

-- ================= M2: duplicates =================
select qa.expect_blocked('M2','duplicate plate in same company (spacing/case differs)', qa.run(:A1, $$with x as (insert into vehicles(plate, company_id) values ('abc1234','00000000-0000-0000-0000-0000000000a0') returning 1) select count(*)::text from x$$));
select qa.expect_blocked('M2','duplicate outgoing invoice number in same company', qa.run(:A1, $$with x as (insert into invoices(number, kind, company_id) values ('a-inv-1','صادرة','00000000-0000-0000-0000-0000000000a0') returning 1) select count(*)::text from x$$));
select qa.expect('M2','same incoming invoice number from two different suppliers is allowed', qa.run(:A1, $$with x as (insert into invoices(number, kind, party, company_id) values ('100','واردة','Supplier X','00000000-0000-0000-0000-0000000000a0'),('100','واردة','Supplier Y','00000000-0000-0000-0000-0000000000a0') returning 1) select count(*)::text from x$$), '2');

-- ================= M6: soft delete & restore =================
select qa.run(:A1, $$with x as (insert into documents(id, name, company_id) values ('00000000-0000-0000-0000-00000000c009','CR certificate','00000000-0000-0000-0000-0000000000a0') returning 1) select count(*)::text from x$$);
select qa.run(:A1, $$select public.soft_delete('documents','00000000-0000-0000-0000-00000000c009')::text$$);
select qa.expect('M6','deleted record is hidden from the app', qa.run(:A1, $$select count(*)::text from documents where id='00000000-0000-0000-0000-00000000c009'$$), '0');
select qa.check_sql('M6','deleted record still exists in the database (recoverable)', $$select exists(select 1 from documents where id='00000000-0000-0000-0000-00000000c009' and deleted_at is not null)$$);
select qa.run(:A1, $$select public.restore_deleted('documents','00000000-0000-0000-0000-00000000c009')::text$$);
select qa.expect_true('M6','restore brings the record back', qa.has_column('documents','deleted_at') and qa.run(:A1, $$select count(*)::text from documents where id='00000000-0000-0000-0000-00000000c009'$$) = '1', '');
select qa.expect_blocked('M6','hard DELETE through the API is refused for company admins', qa.run(:A1, $$with x as (delete from documents where id='00000000-0000-0000-0000-00000000c009' returning 1) select count(*)::text from x$$));
select qa.expect_true('M6','employee cannot soft-delete', qa.has_function('soft_delete') and qa.run(:A2, $$select public.soft_delete('vehicles','00000000-0000-0000-0000-00000000c001')::text$$) like 'BLOCKED%', '');

-- ================= M7: platform owner not hard-coded =================
select qa.expect_true('M7','no e-mail address hard-coded in sign-up trigger', pg_get_functiondef('public.handle_new_user'::regproc) !~ '@', '');

-- ================= L1: anonymous listing of avatar files =================
select qa.expect('L1','anon lists avatar file names', qa.run('anon', $$select count(*)::text from storage.objects where bucket_id='avatars'$$), '0');

-- ================= L2: maintenance can deactivate a company =================
select qa.run('service', $$with x as (update companies set active=false where id='00000000-0000-0000-0000-0000000000b0' returning 1) select count(*)::text from x$$);
select qa.expect('L2','service/maintenance context can deactivate a company', (select active::text from companies where id='00000000-0000-0000-0000-0000000000b0'), 'false');
update companies set active = true where id='00000000-0000-0000-0000-0000000000b0';

-- ================= H4: AI usage limits (DB side) =================
select qa.expect_true('H4','AI usage is metered per company with a limit check', qa.has_table('ai_usage') and qa.has_function('ai_quota_ok'), '');

-- ================= H6: notifications =================
insert into documents(name, company_id, expiry_date) values ('Aramco qualification','00000000-0000-0000-0000-0000000000a0', current_date + 5);
do $$ begin if qa.has_function('generate_notifications') then perform public.generate_notifications(); end if; end $$;
select qa.check_sql('H6','expiring document creates a notification for company admins', $$select exists(select 1 from notifications where company_id='00000000-0000-0000-0000-0000000000a0' and user_id='00000000-0000-0000-0000-0000000000a1' and body like '%Aramco qualification%')$$);
select qa.expect_true('H6','notifications exist and are private to their user', qa.has_table('notifications') and qa.run(:A2, $$select count(*)::text from notifications where user_id='00000000-0000-0000-0000-0000000000a1'$$) = '0', '');

-- ---------- found in the production rollout: a company admin must not raise the AI budget / limits ----------
select qa.run('00000000-0000-0000-0000-0000000000a1',
  $$with u as (update companies set ai_monthly_budget_usd = 999999, ai_daily_user_limit = 999999, deleted_at = now()
               where id='00000000-0000-0000-0000-0000000000a0' returning 1) select count(*)::text from u$$);
select qa.check_sql('H4','company admin cannot raise AI budget, daily limit or set deleted_at on own company',
  $$select ai_monthly_budget_usd < 999999 and ai_daily_user_limit < 999999 and deleted_at is null from companies where id='00000000-0000-0000-0000-0000000000a0'$$);
select qa.check_sql('H4','platform owner can still change the AI budget',
  $$select (select qa.run('00000000-0000-0000-0000-0000000000f0', $q$with u as (update companies set ai_monthly_budget_usd = 45 where id='00000000-0000-0000-0000-0000000000a0' returning ai_monthly_budget_usd) select max(ai_monthly_budget_usd)::text from u$q$)) = '45'$$);
update companies set ai_monthly_budget_usd = 30 where id='00000000-0000-0000-0000-0000000000a0';
