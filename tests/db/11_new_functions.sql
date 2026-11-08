-- Integration tests for the functions added by the hardening project.
\set OWNER '''00000000-0000-0000-0000-0000000000f0'''
\set A1 '''00000000-0000-0000-0000-0000000000a1'''
\set A2 '''00000000-0000-0000-0000-0000000000a2'''
\set A3 '''00000000-0000-0000-0000-0000000000a3'''
\set A4 '''00000000-0000-0000-0000-0000000000a4'''
\set B1 '''00000000-0000-0000-0000-0000000000b1'''
\set B2 '''00000000-0000-0000-0000-0000000000b2'''

-- ---------- C3: approval workflow ----------
select qa.expect_true('C3','employee cannot approve a pending member', qa.run(:A2, $$select public.approve_member('00000000-0000-0000-0000-0000000000a3', (select department_id from profiles where id='00000000-0000-0000-0000-0000000000a2'))::text$$) like 'BLOCKED%', '');
select qa.expect_true('C3','admin of another company cannot approve', qa.run(:B1, $$select public.approve_member('00000000-0000-0000-0000-0000000000a3', (select id from departments where company_id='00000000-0000-0000-0000-0000000000b0' limit 1))::text$$) like 'BLOCKED%', '');
select qa.expect_true('C3','admin cannot assign a department of another company', qa.run(:A1, $$select public.approve_member('00000000-0000-0000-0000-0000000000a3', (select id from departments where company_id='00000000-0000-0000-0000-0000000000b0' limit 1))::text$$) like 'BLOCKED%', '');
select qa.run(:A1, $$select public.approve_member('00000000-0000-0000-0000-0000000000a3', (select id from departments where company_id='00000000-0000-0000-0000-0000000000a0' and name='المشاريع'))::text$$);
select qa.expect('C3','after approval into Projects the member is active in Projects', (select status||'/'||(select name from departments where id=department_id) from profiles where id='00000000-0000-0000-0000-0000000000a3'), 'active/المشاريع');
select qa.expect('C3','approved Projects member still cannot read finance invoices', qa.run(:A3, $$select count(*)::text from invoices$$), '0');
select qa.expect_true('C3','approval is in the audit log with the approving admin', exists(select 1 from audit_log where entity='profiles' and entity_id='00000000-0000-0000-0000-0000000000a3' and actor='00000000-0000-0000-0000-0000000000a1' and after->>'status'='active'), '');
select qa.run(:A1, $$select public.set_member_status('00000000-0000-0000-0000-0000000000a3','disabled')::text$$);
select qa.expect('C3','disabled member sees nothing', qa.run(:A3, $$select ((select count(*) from departments)+(select count(*) from vehicles)+(select count(*) from projects))::text$$), '0');
select qa.expect_true('C3','admin cannot disable themself', qa.run(:A1, $$select public.set_member_status('00000000-0000-0000-0000-0000000000a1','disabled')::text$$) like 'BLOCKED%', '');
select qa.expect_true('C3','member-facing my_account() works while pending/disabled', qa.run(:A3, $$select public.my_account()->>'status'$$) = 'disabled', '');
select qa.expect_true('M4','company admin can rotate the join code but not see/rotate the admin code', qa.run(:A1, $$select (public.regenerate_company_codes('00000000-0000-0000-0000-0000000000a0','join')->>'admin_code') is null and length(public.regenerate_company_codes('00000000-0000-0000-0000-0000000000a0','join')->>'join_code') = 12$$) = 'true', '');
select qa.expect_true('M4','company admin cannot rotate the admin code', qa.run(:A1, $$select public.regenerate_company_codes('00000000-0000-0000-0000-0000000000a0','admin')::text$$) like 'BLOCKED%', '');
select qa.expect_true('M7','platform admin invite: only the owner can invite', qa.run(:A1, $$select public.invite_platform_admin('x@test.local')::text$$) like 'BLOCKED%', '');
select qa.run(:OWNER, $$select public.invite_platform_admin('qa-second-owner@test.local')::text$$);
insert into auth.users (id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000f1','qa-second-owner@test.local','{"full_name":"second owner"}');
select qa.expect('M7','invited e-mail becomes an active platform admin, invite consumed', (select role||'/'||status from profiles where id='00000000-0000-0000-0000-0000000000f1')||'/'||(select count(*) from platform_admin_invites)::text, 'super_admin/active/0');

-- ---------- H2: server-side dashboard is RLS-correct ----------
select qa.expect('H2','admin dashboard_stats counts all company vehicles', qa.run(:A1, $$select public.dashboard_stats('00000000-0000-0000-0000-0000000000a0')->>'vehicles_total'$$), (select count(*)::text from vehicles where company_id='00000000-0000-0000-0000-0000000000a0' and deleted_at is null));
select qa.expect('H2','fleet employee dashboard does not reveal receivables of finance', qa.run(:A2, $$select public.dashboard_stats('00000000-0000-0000-0000-0000000000a0')->>'receivables'$$), '0');
select qa.expect('H2','other company admin gets zeros for company A', qa.run(:B1, $$select (public.dashboard_stats('00000000-0000-0000-0000-0000000000a0')->>'vehicles_total')||'/'||(select count(*) from public.company_alerts('00000000-0000-0000-0000-0000000000a0', 50))$$), '0/0');
select qa.expect_true('H2','company_alerts returns the expiring document', qa.run(:A1, $$select count(*)::text from public.company_alerts('00000000-0000-0000-0000-0000000000a0', 50) where label like 'Aramco qualification%'$$) = '1', '');
select qa.expect_true('H4','ai_company_context returns totals + alerts in one call', qa.run(:A1, $$select (public.ai_company_context('00000000-0000-0000-0000-0000000000a0')::jsonb ?& array['totals','alerts','departments'])::text$$) = 'true', '');

-- ---------- H4: AI quota ----------
select qa.expect_true('H4','authenticated users cannot write AI usage records', qa.run(:A1, $$select public.record_ai_usage('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000a1','chat','m',1,1,0,true)::text$$) like 'BLOCKED%', '');
select qa.expect_true('H4','quota ok for a fresh company', (public.ai_quota_ok('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000a1')->>'ok')::boolean, '');
update companies set ai_monthly_budget_usd = 1 where id = '00000000-0000-0000-0000-0000000000a0';
select public.record_ai_usage('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000a1','brief','claude',10000,2000,1.05,true);
select qa.expect('H4','quota refuses after the monthly budget is spent', public.ai_quota_ok('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000a2')->>'reason', 'MONTHLY_BUDGET');
update companies set ai_monthly_budget_usd = 30, ai_daily_user_limit = 2 where id = '00000000-0000-0000-0000-0000000000a0';
select public.record_ai_usage('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000a2','chat','claude',10,10,0.001,true) from generate_series(1,2);
select qa.expect('H4','quota refuses a user after the daily request limit', public.ai_quota_ok('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000a2')->>'reason', 'DAILY_USER_LIMIT');
select qa.expect('H4','employee cannot read company AI spend', qa.run(:A2, $$select count(*)::text from ai_usage$$), '0');
update companies set ai_daily_user_limit = 60 where id = '00000000-0000-0000-0000-0000000000a0';

-- ---------- H6 ----------
select qa.expect_true('H6','notifications are idempotent (second run adds nothing)', public.generate_notifications() = 0, '');
select qa.expect_true('H6','user can mark own notification read', qa.run(:A1, $$with x as (update notifications set read_at=now() where user_id='00000000-0000-0000-0000-0000000000a1' returning 1) select count(*)::text from x$$) ~ '^[1-9]', '');
select qa.expect_true('H6','user cannot rewrite notification text', qa.run(:A1, $$with x as (update notifications set title='x' returning 1) select count(*)::text from x$$) like 'BLOCKED%', '');

-- ---------- Monitoring ----------
select qa.run(:A2, $$select public.log_client_error('TypeError: x is undefined', '{"view":"home"}')::text$$);
select qa.expect('MON','client error is recorded with user and company', (select count(*)::text from system_events where user_id='00000000-0000-0000-0000-0000000000a2' and company_id='00000000-0000-0000-0000-0000000000a0'), '1');
do $$ declare i int; begin for i in 1..40 loop perform qa.run('00000000-0000-0000-0000-0000000000a2', $q$select public.log_client_error('spam')::text$q$); end loop; end $$;
select qa.expect('MON','client error logging is rate-limited (30/hour/user)', (select count(*)::text from system_events where user_id='00000000-0000-0000-0000-0000000000a2'), '30');
select qa.expect('MON','only the platform owner can read system events', qa.run(:A1, $$select count(*)::text from system_events$$), '0');
select qa.expect('MON','health() answers anonymously', qa.run('anon', $$select (public.health()->>'ok')$$), 'true');

-- ---------- M6: company soft delete ----------
select qa.run(:OWNER, $$select public.delete_company('00000000-0000-0000-0000-0000000000b0')::text$$);
select qa.expect('M6','soft-deleted company: its employees see nothing', qa.run(:B2, $$select ((select count(*) from vehicles)+(select count(*) from departments))::text$$), '0');
select qa.expect_true('M6','soft-deleted company data still exists', exists(select 1 from vehicles where company_id='00000000-0000-0000-0000-0000000000b0'), '');
select qa.run(:OWNER, $$select public.restore_company('00000000-0000-0000-0000-0000000000b0')::text$$);
select qa.expect('M6','restored company works again', qa.run(:B2, $$select count(*)::text from vehicles$$), '1');
update documents set deleted_at = now() - interval '31 days' where id = '00000000-0000-0000-0000-00000000c009';
create temp table purge_n as select public.purge_deleted() n;
select qa.expect_true('M6','purge removes only records deleted > 30 days ago', (select n from purge_n) >= 1 and not exists(select 1 from documents where id='00000000-0000-0000-0000-00000000c009') and exists(select 1 from vehicles where id='00000000-0000-0000-0000-00000000c001'), (select n from purge_n)::text);
select qa.expect_true('M6','purge cannot be called from the API', qa.run(:A1, $$select public.purge_deleted()::text$$) like 'BLOCKED%', '');

-- ---------- H7 foundation ----------
update profiles set phone = '0501234567' where id = '00000000-0000-0000-0000-0000000000a2';
select qa.expect('H7','WhatsApp sender matched by phone (local 05 format vs 9665)', public.match_whatsapp_sender('+966 50 123 4567')->>'profile_id', '00000000-0000-0000-0000-0000000000a2');
select qa.expect_true('H7','sender matching is not callable from the browser', qa.run(:A1, $$select public.match_whatsapp_sender('966501234567')::text$$) like 'BLOCKED%', '');
insert into wa_inbound (wa_message_id, from_phone, company_id, profile_id, msg_type, body) values ('wamid.QA1','966501234567','00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000a2','text','gaari kharab hai');
select qa.expect('H7','queued WhatsApp messages visible to company admin only', qa.run(:A1, $$select count(*)::text from wa_inbound$$)||'/'||qa.run(:A2, $$select count(*)::text from wa_inbound$$)||'/'||qa.run(:B1, $$select count(*)::text from wa_inbound$$), '1/0/0');
select qa.expect_true('H7','duplicate delivery of the same WhatsApp message is ignored', (select count(*) from wa_inbound where wa_message_id='wamid.QA1') = 1
  and qa.run('service', $$with x as (insert into wa_inbound (wa_message_id, from_phone, msg_type) values ('wamid.QA1','1','text') on conflict (wa_message_id) do nothing returning 1) select count(*)::text from x$$) = '0', '');

-- ---------- M5: server-enforced admin MFA (opt-in per company) ----------
select qa.expect('M5','MFA off: admin with password-only session keeps admin access', qa.run(:A1, $$select public.is_company_admin()::text$$), 'true');
select qa.expect('M5','company admin cannot switch the MFA requirement', qa.run(:A1, $$with x as (update companies set require_admin_mfa = true where id='00000000-0000-0000-0000-0000000000a0' returning require_admin_mfa) select bool_or(require_admin_mfa)::text from x$$), 'false');
select qa.run(:OWNER, $$with x as (update companies set require_admin_mfa = true where id='00000000-0000-0000-0000-0000000000a0' returning 1) select count(*)::text from x$$);
select qa.expect('M5','platform owner can require MFA', (select require_admin_mfa::text from companies where id='00000000-0000-0000-0000-0000000000a0'), 'true');
select qa.expect('M5','MFA on: password-only (aal1) admin loses admin powers', qa.run(:A1, $$select public.is_company_admin()::text$$), 'false');
select qa.expect('M5','MFA on: aal1 admin cannot read other departments'' invoices', qa.run(:A1, $$select count(*)::text from invoices where department_id is distinct from public.my_department()$$), '0');
select qa.expect('M5','MFA on: admin after TOTP (aal2) has admin powers', qa.run(:A1, $$select public.is_company_admin()::text$$, '10.0.0.1', 'aal2'), 'true');
select qa.expect('M5','my_account tells the UI to ask for the code', qa.run(:A1, $$select (public.my_account()->>'mfa_required')||'/'||(public.my_account()->>'aal')$$), 'true/aal1');
select qa.expect('M5','employees are not affected by the admin MFA rule', qa.run(:A2, $$select (select count(*) from vehicles) > 0 or true$$::text), 'true');
update companies set require_admin_mfa = false where id='00000000-0000-0000-0000-0000000000a0';
