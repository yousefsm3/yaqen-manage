-- Test fixture: 2 companies, 7 users, a little data. Runs as the DB owner (postgres).
-- Fixed ids so tests can reference them.
insert into public.companies (id, name, join_code, admin_code) values
 ('00000000-0000-0000-0000-0000000000a0','QA-A','QAJOINAAAAAA','QAADMINAAAAAAAAA'),
 ('00000000-0000-0000-0000-0000000000b0','QA-B','QAJOINBBBBBB','QAADMINBBBBBBBBB');

create temp table fx_dep as
  select company_id, name, id from public.departments where company_id in ('00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000b0');
create function pg_temp.dep(c text, n text) returns uuid language sql as $$
  select id from fx_dep where company_id = c::uuid and name = n $$;

-- platform owner: created as a plain user, then promoted directly (fixture only)
insert into auth.users (id, email, raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000f0','qa-owner@test.local','{"full_name":"QA owner","company_code":"QAJOINBBBBBB"}');

insert into auth.users (id, email, raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000a1','qa-a1@test.local','{"full_name":"A admin","company_code":"QAADMINAAAAAAAAA"}'),
 ('00000000-0000-0000-0000-0000000000a2','qa-a2@test.local', jsonb_build_object('full_name','A driver','company_code','QAJOINAAAAAA','department_id', pg_temp.dep('00000000-0000-0000-0000-0000000000a0','الأسطول والمعدات'))),
 ('00000000-0000-0000-0000-0000000000a3','qa-a3@test.local', jsonb_build_object('full_name','A self-picked finance','company_code','QAJOINAAAAAA','department_id', pg_temp.dep('00000000-0000-0000-0000-0000000000a0','المالية'))),
 ('00000000-0000-0000-0000-0000000000a4','qa-a4@test.local', jsonb_build_object('full_name','A finance (assigned)','company_code','QAJOINAAAAAA')),
 ('00000000-0000-0000-0000-0000000000b1','qa-b1@test.local','{"full_name":"B admin","company_code":"QAADMINBBBBBBBBB"}'),
 ('00000000-0000-0000-0000-0000000000b2','qa-b2@test.local','{"full_name":"B emp","company_code":"QAJOINBBBBBB"}');

-- What an admin would do after sign-up: assign departments / approve. Done directly, triggers off.
set session_replication_role = replica;
update public.profiles set role = 'super_admin', company_id = null where id = '00000000-0000-0000-0000-0000000000f0';
update public.profiles set department_id = pg_temp.dep('00000000-0000-0000-0000-0000000000a0','الأسطول والمعدات') where id = '00000000-0000-0000-0000-0000000000a2';
update public.profiles set department_id = pg_temp.dep('00000000-0000-0000-0000-0000000000a0','المالية') where id = '00000000-0000-0000-0000-0000000000a4';
update public.profiles set department_id = pg_temp.dep('00000000-0000-0000-0000-0000000000b0','الأسطول والمعدات') where id = '00000000-0000-0000-0000-0000000000b2';
do $$ begin
  if qa.has_column('profiles','status') then
    execute $q$update public.profiles set status = 'active' where id in ('00000000-0000-0000-0000-0000000000f0','00000000-0000-0000-0000-0000000000a2','00000000-0000-0000-0000-0000000000a4','00000000-0000-0000-0000-0000000000b2')$q$;
  end if;
end $$;
set session_replication_role = origin;

insert into public.vehicles (id, plate, company_id, department_id) values
 ('00000000-0000-0000-0000-00000000c001','ABC 1234','00000000-0000-0000-0000-0000000000a0', pg_temp.dep('00000000-0000-0000-0000-0000000000a0','الأسطول والمعدات')),
 ('00000000-0000-0000-0000-00000000c002','ABC 1234','00000000-0000-0000-0000-0000000000b0', pg_temp.dep('00000000-0000-0000-0000-0000000000b0','الأسطول والمعدات'));
insert into public.invoices (id, number, kind, amount, company_id, department_id) values
 ('00000000-0000-0000-0000-00000000c003','A-INV-1','صادرة',99000,'00000000-0000-0000-0000-0000000000a0', pg_temp.dep('00000000-0000-0000-0000-0000000000a0','المالية'));
insert into public.rooms (id, title, company_id, created_by) values
 ('00000000-0000-0000-0000-0000000000e0','QA room','00000000-0000-0000-0000-0000000000a0','00000000-0000-0000-0000-0000000000a1');
insert into public.room_members (room_id, user_id) values ('00000000-0000-0000-0000-0000000000e0','00000000-0000-0000-0000-0000000000a2') on conflict do nothing;
insert into public.room_messages (id, room_id, user_id, body) values
 ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000e0','00000000-0000-0000-0000-0000000000a1','قرار مهم');
insert into public.manager_notes (id, company_id, department_id, body) values
 ('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a0', pg_temp.dep('00000000-0000-0000-0000-0000000000a0','الأسطول والمعدات'),'جدد التأمين');
insert into storage.objects (bucket_id, name, owner) values
 ('rooms','00000000-0000-0000-0000-0000000000e0/secret.pdf','00000000-0000-0000-0000-0000000000a1'),
 ('avatars','00000000-0000-0000-0000-0000000000a2/1.jpg','00000000-0000-0000-0000-0000000000a2');
