-- Performance scenario from the review report:
-- 1 company with 1,500 employees, 20,000 invoices, 3,000 vehicles, 3,000 documents; + 49 other companies.
-- Measured with EXPLAIN ANALYZE as real users through RLS. Target: < 200 ms per query.
do $$
declare c uuid; i int; deps uuid[];
begin
  insert into companies (id, name, join_code, admin_code) values ('00000000-0000-0000-0000-00000000aaaa','PERF-BIG','PFJOINBIG001','PFADMINBIG000001');
  select array_agg(id order by created_at, name) into deps from departments where company_id='00000000-0000-0000-0000-00000000aaaa';
  insert into auth.users (id, email, raw_user_meta_data)
    select ('00000000-0000-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid, 'perf'||g||'@test.local',
      jsonb_build_object('full_name','موظف '||g,'company_code', case when g=1 then 'PFADMINBIG000001' else 'PFJOINBIG001' end)
    from generate_series(1,1500) g;
  -- admin assigns departments and approves everyone (bulk, triggers off)
  set local session_replication_role = replica;
  update profiles set department_id = deps[1 + (('x'||substr(id::text, 25, 12))::bit(48)::bigint % 7)::int]
    where company_id='00000000-0000-0000-0000-00000000aaaa' and role='employee';
  if qa.has_column('profiles','status') then execute $q$update profiles set status='active' where company_id='00000000-0000-0000-0000-00000000aaaa'$q$; end if;
  set local session_replication_role = origin;
  insert into vehicles (company_id, department_id, plate, status, insurance_expiry)
    select '00000000-0000-0000-0000-00000000aaaa', deps[3], 'P '||g, (array['شغالة','متوقفة','صيانة'])[1+g%3], current_date + (g % 400) from generate_series(1,3000) g;
  insert into invoices (company_id, department_id, number, amount, due_date, status)
    select '00000000-0000-0000-0000-00000000aaaa', deps[5], 'INV-'||g, (g%100)*1000, current_date - 200 + (g % 365), (array['مدفوعة','غير مدفوعة','متأخرة'])[1+g%3] from generate_series(1,20000) g;
  insert into documents (company_id, department_id, name, expiry_date)
    select '00000000-0000-0000-0000-00000000aaaa', deps[7], 'DOC-'||g, current_date + (g % 500) from generate_series(1,3000) g;
  insert into projects (company_id, department_id, name, progress)
    select '00000000-0000-0000-0000-00000000aaaa', deps[2], 'PRJ-'||g, g%100 from generate_series(1,300) g;
  for i in 1..49 loop
    c := ('00000000-0000-0000-0002-'||lpad(to_hex(i),12,'0'))::uuid;
    insert into companies (id, name, join_code, admin_code) values (c, 'PERF-'||i, 'PFJOIN'||lpad(i::text,6,'0'), 'PFADMIN'||lpad(i::text,9,'0'));
    insert into invoices (company_id, number, amount, status) select c, 'O-'||g, g, 'مدفوعة' from generate_series(1,1000) g;
    insert into vehicles (company_id, plate) select c, 'O '||g from generate_series(1,200) g;
  end loop;
end $$;
analyze;

create temp table perf(n serial, name text, who text, ms numeric);
create function pg_temp.p(name text, who text, q text) returns void language sql as $$
  insert into perf(name, who, ms) values (name, who, qa.ms(who, q)) $$;

\set ADM '''00000000-0000-0000-0001-000000000001'''
select pg_temp.p('invoices: full list 20,000 rows (report query)', :ADM, $$select * from invoices where company_id='00000000-0000-0000-0000-00000000aaaa' order by updated_at desc$$);
select pg_temp.p('invoices: page 1 (50 rows)', :ADM, $$select * from invoices where company_id='00000000-0000-0000-0000-00000000aaaa' order by updated_at desc, id limit 50$$);
select pg_temp.p('invoices: page 200 (offset 9,950)', :ADM, $$select * from invoices where company_id='00000000-0000-0000-0000-00000000aaaa' order by updated_at desc, id limit 50 offset 9950$$);
select pg_temp.p('invoices: server search "INV-1999"', :ADM, $$select * from invoices where company_id='00000000-0000-0000-0000-00000000aaaa' and number ilike '%INV-1999%' order by updated_at desc limit 50$$);
select pg_temp.p('invoices: exact count for pager', :ADM, $$select count(*) from invoices where company_id='00000000-0000-0000-0000-00000000aaaa'$$);
select pg_temp.p('dashboard: overdue invoices sum', :ADM, $$select count(*), sum(amount) from invoices where company_id='00000000-0000-0000-0000-00000000aaaa' and status<>'مدفوعة' and due_date<current_date$$);
select pg_temp.p('vehicles: page 1', :ADM, $$select * from vehicles where company_id='00000000-0000-0000-0000-00000000aaaa' order by updated_at desc, id limit 50$$);
select pg_temp.p('vehicles: full list 3,000', :ADM, $$select * from vehicles where company_id='00000000-0000-0000-0000-00000000aaaa' order by updated_at desc$$);
select pg_temp.p('employees: page 1', :ADM, $$select * from profiles where company_id='00000000-0000-0000-0000-00000000aaaa' order by created_at, id limit 50$$);
select pg_temp.p('employees: full list 1,500', :ADM, $$select * from profiles where company_id='00000000-0000-0000-0000-00000000aaaa' order by created_at$$);
do $$ begin
  if qa.has_function('dashboard_stats') then
    perform pg_temp.p('dashboard: dashboard_stats() RPC', '00000000-0000-0000-0001-000000000001', $q$select public.dashboard_stats('00000000-0000-0000-0000-00000000aaaa')$q$);
  end if;
end $$;
-- employees in two departments
select pg_temp.p('finance employee: invoices page 1', (select p.id::text from profiles p join departments d on d.id=p.department_id where p.company_id='00000000-0000-0000-0000-00000000aaaa' and p.role='employee' and d.name='المالية' limit 1),
  $$select * from invoices where company_id='00000000-0000-0000-0000-00000000aaaa' order by updated_at desc, id limit 50$$);
select pg_temp.p('fleet employee: invoices (correct answer 0 rows)', (select p.id::text from profiles p join departments d on d.id=p.department_id where p.company_id='00000000-0000-0000-0000-00000000aaaa' and p.role='employee' and d.name='الأسطول والمعدات' limit 1),
  $$select * from invoices where company_id='00000000-0000-0000-0000-00000000aaaa' limit 50$$);

-- correctness under load: RLS still returns the right rows
select qa.expect('PERF','finance employee sees exactly the 20,000 finance invoices', qa.run((select p.id::text from profiles p join departments d on d.id=p.department_id where p.company_id='00000000-0000-0000-0000-00000000aaaa' and p.role='employee' and d.name='المالية' limit 1), $$select count(*)::text from invoices$$), '20000');
select qa.expect('PERF','fleet employee sees 0 invoices', qa.run((select p.id::text from profiles p join departments d on d.id=p.department_id where p.company_id='00000000-0000-0000-0000-00000000aaaa' and p.role='employee' and d.name='الأسطول والمعدات' limit 1), $$select count(*)::text from invoices$$), '0');
select qa.expect('PERF','big-company admin sees none of the other 49 companies invoices', qa.run('00000000-0000-0000-0001-000000000001', $$select count(*)::text from invoices where company_id <> '00000000-0000-0000-0000-00000000aaaa'$$), '0');

insert into qa.results(issue, name, ok, detail)
  select case when name like 'invoices%' or name like 'finance%' or name like 'fleet%' then 'C1' else 'H2' end,
         'PERF ' || name, ms >= 0 and ms < 200, ms || ' ms' from perf order by n;
