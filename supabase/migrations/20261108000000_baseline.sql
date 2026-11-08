-- BASELINE: production schema of Yaqen Manage (project zalfumkzlnpygvemxayb) as of 2026-11-08.
-- Generated from the production catalog (pg_catalog) and reordered so it replays cleanly.
-- Represents the 11 migrations applied on 2026-11-07 (core_schema .. message_translation).
-- Do NOT apply to production: production already has this schema.
set check_function_bodies = off;

-- ===== functions =====
CREATE OR REPLACE FUNCTION public.is_super() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  select exists(select 1 from profiles where id = auth.uid() and role = 'super_admin'); $function$;
CREATE OR REPLACE FUNCTION public.my_company() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  select p.company_id from profiles p join companies c on c.id = p.company_id where p.id = auth.uid() and c.active; $function$;
CREATE OR REPLACE FUNCTION public.is_company_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  select exists(select 1 from profiles p join companies c on c.id = p.company_id where p.id = auth.uid() and p.role = 'admin' and c.active); $function$;
CREATE OR REPLACE FUNCTION public.my_department() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  select department_id from profiles where id = auth.uid(); $function$;
CREATE OR REPLACE FUNCTION public.can_access(c uuid, d uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  select public.is_super() or (c = public.my_company() and (public.is_company_admin() or d = public.my_department())); $function$;
CREATE OR REPLACE FUNCTION public.can_manage(c uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  select public.is_super() or (c = public.my_company() and public.is_company_admin()); $function$;
CREATE OR REPLACE FUNCTION public.is_room_member(r uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  select exists(select 1 from room_members where room_id = r and user_id = auth.uid()); $function$;
CREATE OR REPLACE FUNCTION public.can_see_room(r uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  select exists(select 1 from rooms where id = r and (public.can_manage(company_id) or (company_id = public.my_company() and public.is_room_member(r)))); $function$;
CREATE OR REPLACE FUNCTION public.can_admin_room(r uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  select exists(select 1 from rooms where id = r and (public.can_manage(company_id) or (company_id = public.my_company() and created_by = auth.uid()))); $function$;
CREATE OR REPLACE FUNCTION public.can_post_room(r uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  select exists(select 1 from rooms where id = r and status = 'مفتوحة' and (public.can_manage(company_id) or (company_id = public.my_company() and public.is_room_member(r)))); $function$;

CREATE OR REPLACE FUNCTION public.lookup_company(code text) RETURNS json LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  select json_build_object('id', c.id, 'name', c.name, 'logo_url', c.logo_url,
    'is_admin_code', upper(trim(code)) = c.admin_code,
    'departments', coalesce((select json_agg(json_build_object('id', d.id, 'name', d.name, 'icon', d.icon) order by d.created_at) from departments d where d.company_id = c.id), '[]'::json))
  from companies c where c.active and (c.join_code = upper(trim(code)) or c.admin_code = upper(trim(code))) limit 1; $function$;

CREATE OR REPLACE FUNCTION public.seed_departments() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
  insert into departments (company_id, name, icon) values
   (new.id,'الإدارة العليا','👔'),(new.id,'المشاريع','🏗️'),(new.id,'الأسطول والمعدات','🚚'),
   (new.id,'الموارد البشرية','👥'),(new.id,'المالية','💰'),(new.id,'القانونية','⚖️'),(new.id,'السلامة والامتثال','🦺');
  return new;
end; $function$;

CREATE OR REPLACE FUNCTION public.protect_profile() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
  if public.is_super() then return new; end if;
  new.company_id := old.company_id;
  if old.role = 'super_admin' then new.role := old.role; end if;
  if new.role = 'super_admin' then new.role := old.role; end if;
  if not public.can_manage(old.company_id) then
    new.role := old.role;
    if old.department_id is not null then new.department_id := old.department_id; end if;
  end if;
  if new.department_id is not null and not exists(select 1 from departments where id = new.department_id and company_id = old.company_id) then
    new.department_id := old.department_id; end if;
  return new;
end; $function$;

CREATE OR REPLACE FUNCTION public.admin_delete_user(target uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'auth' AS $function$
declare t profiles%rowtype;
begin
  select * into t from profiles where id = target;
  if t.id is null then raise exception 'المستخدم غير موجود'; end if;
  if target = auth.uid() then raise exception 'لا يمكنك حذف حسابك'; end if;
  if t.role = 'super_admin' then raise exception 'غير مصرح'; end if;
  if not public.can_manage(t.company_id) then raise exception 'غير مصرح'; end if;
  delete from auth.users where id = target;
end; $function$;

CREATE OR REPLACE FUNCTION public.protect_company() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
  if not public.is_super() then
    new.join_code := old.join_code; new.admin_code := old.admin_code; new.active := old.active; new.notes := old.notes;
  end if;
  return new;
end; $function$;

CREATE OR REPLACE FUNCTION public.protect_note() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
  if not public.can_manage(old.company_id) then
    new.body := old.body; new.subject := old.subject; new.department_id := old.department_id;
    new.due_date := old.due_date; new.created_by := old.created_by; new.company_id := old.company_id;
    if new.status = 'منجزة' then new.status := old.status; end if;
    new.replied_by := auth.uid();
  end if;
  new.updated_at := now();
  return new;
end; $function$;

CREATE OR REPLACE FUNCTION public.check_dept_company() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
  if new.department_id is not null and not exists(select 1 from departments where id = new.department_id and company_id = new.company_id) then
    raise exception 'القسم لا يتبع هذه الشركة'; end if;
  return new;
end; $function$;

CREATE OR REPLACE FUNCTION public.delete_company(target uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'auth' AS $function$
begin
  if not public.is_super() then raise exception 'غير مصرح'; end if;
  delete from auth.users where id in (select id from profiles where company_id = target and role <> 'super_admin');
  delete from companies where id = target;
end; $function$;

CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
declare comp companies%rowtype; code text; dep uuid; r text := 'employee';
begin
  if lower(new.email) = 'yyssmmrr2@gmail.com' then
    insert into profiles (id, full_name, email, phone, role)
    values (new.id, coalesce(new.raw_user_meta_data->>'full_name','Yousef'), new.email, new.raw_user_meta_data->>'phone', 'super_admin');
    return new;
  end if;
  code := upper(trim(coalesce(new.raw_user_meta_data->>'company_code','')));
  select * into comp from companies where active and (join_code = code or admin_code = code) limit 1;
  if comp.id is null then raise exception 'INVALID_COMPANY_CODE'; end if;
  if comp.admin_code = code then r := 'admin'; end if;
  begin dep := nullif(new.raw_user_meta_data->>'department_id','')::uuid; exception when others then dep := null; end;
  if dep is not null and not exists(select 1 from departments where id = dep and company_id = comp.id) then dep := null; end if;
  insert into profiles (id, company_id, full_name, email, phone, job_title, department_id, role)
  values (new.id, comp.id, coalesce(new.raw_user_meta_data->>'full_name',''), new.email,
    new.raw_user_meta_data->>'phone', new.raw_user_meta_data->>'job_title', dep, r);
  return new;
end; $function$;

CREATE OR REPLACE FUNCTION public.room_member_check() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
  if not exists (select 1 from rooms r join profiles p on p.company_id = r.company_id where r.id = new.room_id and p.id = new.user_id) then
    raise exception 'الموظف ليس من نفس الشركة'; end if;
  return new;
end; $function$;

CREATE OR REPLACE FUNCTION public.room_touch() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin update rooms set last_message_at = now() where id = new.room_id; return new; end; $function$;

CREATE OR REPLACE FUNCTION public.room_add_creator() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
  if new.created_by is not null and exists (select 1 from profiles where id = new.created_by and company_id = new.company_id) then
    insert into room_members (room_id, user_id) values (new.id, new.created_by) on conflict do nothing;
  end if;
  return new;
end; $function$;

CREATE OR REPLACE FUNCTION public.protect_message() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
begin
  new.room_id := old.room_id; new.user_id := old.user_id; new.kind := old.kind; new.body := old.body;
  new.file_path := old.file_path; new.file_name := old.file_name; new.file_size := old.file_size;
  new.mime := old.mime; new.created_at := old.created_at;
  return new;
end; $function$;

-- ===== tables =====
create table public.companies (
  id uuid default gen_random_uuid() not null, name text not null, logo_url text,
  join_code text default upper(substr(md5((random())::text), 1, 6)) not null,
  admin_code text default upper(substr(md5((random())::text), 1, 10)) not null,
  active boolean default true not null, notes text, created_at timestamp with time zone default now());
create table public.departments (
  id uuid default gen_random_uuid() not null, company_id uuid not null, name text not null,
  icon text default '🏢'::text, created_at timestamp with time zone default now());
create table public.profiles (
  id uuid not null, company_id uuid, full_name text default ''::text not null, email text, phone text, job_title text,
  avatar_url text, department_id uuid, role text default 'employee'::text not null, created_at timestamp with time zone default now());
create table public.documents (
  id uuid default gen_random_uuid() not null, company_id uuid default my_company() not null, name text not null, doc_type text,
  expiry_date date, notes text, department_id uuid, created_by uuid default auth.uid(), updated_at timestamp with time zone default now());
create table public.invoices (
  id uuid default gen_random_uuid() not null, company_id uuid default my_company() not null, number text not null, party text,
  kind text default 'صادرة'::text, amount numeric default 0, due_date date, status text default 'غير مدفوعة'::text,
  department_id uuid, created_by uuid default auth.uid(), updated_at timestamp with time zone default now());
create table public.legal_cases (
  id uuid default gen_random_uuid() not null, company_id uuid default my_company() not null, title text not null, case_number text,
  court text, opponent text, lawyer text, status text default 'مفتوحة'::text, next_hearing date, last_update text,
  department_id uuid, created_by uuid default auth.uid(), updated_at timestamp with time zone default now());
create table public.manager_notes (
  id uuid default gen_random_uuid() not null, company_id uuid default my_company() not null, department_id uuid, subject text,
  body text not null, due_date date, status text default 'مفتوحة'::text, reply text, replied_by uuid,
  created_by uuid default auth.uid(), created_at timestamp with time zone default now(), updated_at timestamp with time zone default now());
create table public.projects (
  id uuid default gen_random_uuid() not null, company_id uuid default my_company() not null, name text not null,
  client text default 'أرامكو'::text, po_number text, contract_value numeric, progress integer default 0, status text default 'جاري'::text,
  start_date date, end_date date, notes text, department_id uuid, created_by uuid default auth.uid(), updated_at timestamp with time zone default now());
create table public.requests (
  id uuid default gen_random_uuid() not null, company_id uuid default my_company() not null, title text not null, details text,
  priority text default 'عادي'::text, status text default 'جديد'::text, department_id uuid, created_by uuid default auth.uid(),
  created_at timestamp with time zone default now(), updated_at timestamp with time zone default now());
create table public.rooms (
  id uuid default gen_random_uuid() not null, company_id uuid default my_company() not null, title text not null, description text,
  status text default 'مفتوحة'::text not null, created_by uuid default auth.uid(), created_at timestamp with time zone default now(),
  last_message_at timestamp with time zone default now());
create table public.room_members (room_id uuid not null, user_id uuid not null, added_at timestamp with time zone default now());
create table public.room_messages (
  id uuid default gen_random_uuid() not null, room_id uuid not null, user_id uuid default auth.uid(), kind text default 'text'::text not null,
  body text, file_path text, file_name text, file_size bigint, mime text, created_at timestamp with time zone default now(), translation jsonb);
create table public.vehicles (
  id uuid default gen_random_uuid() not null, company_id uuid default my_company() not null, plate text not null, kind text, model text,
  driver_name text, driver_phone text, location text, status text default 'شغالة'::text, registration_expiry date, insurance_expiry date,
  license_expiry date, notes text, department_id uuid, created_by uuid default auth.uid(), updated_at timestamp with time zone default now());

-- ===== constraints =====
alter table public.companies add constraint companies_pkey PRIMARY KEY (id);
alter table public.companies add constraint companies_join_code_key UNIQUE (join_code);
alter table public.companies add constraint companies_admin_code_key UNIQUE (admin_code);
alter table public.departments add constraint departments_pkey PRIMARY KEY (id);
alter table public.departments add constraint departments_company_id_name_key UNIQUE (company_id, name);
alter table public.documents add constraint documents_pkey PRIMARY KEY (id);
alter table public.invoices add constraint invoices_pkey PRIMARY KEY (id);
alter table public.legal_cases add constraint legal_cases_pkey PRIMARY KEY (id);
alter table public.manager_notes add constraint manager_notes_pkey PRIMARY KEY (id);
alter table public.profiles add constraint profiles_pkey PRIMARY KEY (id);
alter table public.projects add constraint projects_pkey PRIMARY KEY (id);
alter table public.requests add constraint requests_pkey PRIMARY KEY (id);
alter table public.room_members add constraint room_members_pkey PRIMARY KEY (room_id, user_id);
alter table public.room_messages add constraint room_messages_pkey PRIMARY KEY (id);
alter table public.rooms add constraint rooms_pkey PRIMARY KEY (id);
alter table public.vehicles add constraint vehicles_pkey PRIMARY KEY (id);
alter table public.departments add constraint departments_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE;
alter table public.documents add constraint documents_department_id_fkey FOREIGN KEY (department_id) REFERENCES departments(id) ON DELETE SET NULL;
alter table public.documents add constraint documents_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE;
alter table public.documents add constraint documents_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.invoices add constraint invoices_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE;
alter table public.invoices add constraint invoices_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.invoices add constraint invoices_department_id_fkey FOREIGN KEY (department_id) REFERENCES departments(id) ON DELETE SET NULL;
alter table public.legal_cases add constraint legal_cases_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE;
alter table public.legal_cases add constraint legal_cases_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.legal_cases add constraint legal_cases_department_id_fkey FOREIGN KEY (department_id) REFERENCES departments(id) ON DELETE SET NULL;
alter table public.manager_notes add constraint manager_notes_department_id_fkey FOREIGN KEY (department_id) REFERENCES departments(id) ON DELETE CASCADE;
alter table public.manager_notes add constraint manager_notes_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.manager_notes add constraint manager_notes_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE;
alter table public.manager_notes add constraint manager_notes_replied_by_fkey FOREIGN KEY (replied_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.profiles add constraint profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.profiles add constraint profiles_department_id_fkey FOREIGN KEY (department_id) REFERENCES departments(id) ON DELETE SET NULL;
alter table public.profiles add constraint profiles_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE;
alter table public.projects add constraint projects_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.projects add constraint projects_department_id_fkey FOREIGN KEY (department_id) REFERENCES departments(id) ON DELETE SET NULL;
alter table public.projects add constraint projects_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE;
alter table public.requests add constraint requests_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE;
alter table public.requests add constraint requests_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.requests add constraint requests_department_id_fkey FOREIGN KEY (department_id) REFERENCES departments(id) ON DELETE SET NULL;
alter table public.room_members add constraint room_members_room_id_fkey FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE;
alter table public.room_members add constraint room_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.room_messages add constraint room_messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.room_messages add constraint room_messages_room_id_fkey FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE;
alter table public.rooms add constraint rooms_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.rooms add constraint rooms_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE;
alter table public.vehicles add constraint vehicles_company_id_fkey FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE;
alter table public.vehicles add constraint vehicles_department_id_fkey FOREIGN KEY (department_id) REFERENCES departments(id) ON DELETE SET NULL;
alter table public.vehicles add constraint vehicles_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.invoices add constraint invoices_kind_check CHECK ((kind = ANY (ARRAY['صادرة'::text, 'واردة'::text])));
alter table public.invoices add constraint invoices_status_check CHECK ((status = ANY (ARRAY['مدفوعة'::text, 'غير مدفوعة'::text, 'متأخرة'::text])));
alter table public.legal_cases add constraint legal_cases_status_check CHECK ((status = ANY (ARRAY['مفتوحة'::text, 'قيد النظر'::text, 'مؤجلة'::text, 'مغلقة'::text])));
alter table public.manager_notes add constraint manager_notes_status_check CHECK ((status = ANY (ARRAY['مفتوحة'::text, 'تم الرد'::text, 'منجزة'::text])));
alter table public.profiles add constraint profiles_role_check CHECK ((role = ANY (ARRAY['super_admin'::text, 'admin'::text, 'employee'::text])));
alter table public.projects add constraint projects_progress_check CHECK (((progress >= 0) AND (progress <= 100)));
alter table public.projects add constraint projects_status_check CHECK ((status = ANY (ARRAY['جاري'::text, 'متأخر'::text, 'مكتمل'::text, 'معلق'::text])));
alter table public.requests add constraint requests_status_check CHECK ((status = ANY (ARRAY['جديد'::text, 'قيد التنفيذ'::text, 'معتمد'::text, 'مرفوض'::text, 'منجز'::text])));
alter table public.requests add constraint requests_priority_check CHECK ((priority = ANY (ARRAY['عاجل'::text, 'عادي'::text, 'منخفض'::text])));
alter table public.room_messages add constraint room_messages_kind_check CHECK ((kind = ANY (ARRAY['text'::text, 'image'::text, 'audio'::text, 'file'::text, 'ai'::text])));
alter table public.rooms add constraint rooms_status_check CHECK ((status = ANY (ARRAY['مفتوحة'::text, 'مغلقة'::text])));
alter table public.vehicles add constraint vehicles_status_check CHECK ((status = ANY (ARRAY['شغالة'::text, 'متوقفة'::text, 'صيانة'::text])));
CREATE INDEX room_messages_room_id_created_at_idx ON public.room_messages USING btree (room_id, created_at);

-- ===== triggers =====
CREATE TRIGGER profiles_protect BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION protect_profile();
CREATE TRIGGER companies_protect BEFORE UPDATE ON public.companies FOR EACH ROW EXECUTE FUNCTION protect_company();
CREATE TRIGGER notes_protect BEFORE UPDATE ON public.manager_notes FOR EACH ROW EXECUTE FUNCTION protect_note();
CREATE TRIGGER vehicles_dept BEFORE INSERT OR UPDATE ON public.vehicles FOR EACH ROW EXECUTE FUNCTION check_dept_company();
CREATE TRIGGER projects_dept BEFORE INSERT OR UPDATE ON public.projects FOR EACH ROW EXECUTE FUNCTION check_dept_company();
CREATE TRIGGER legal_cases_dept BEFORE INSERT OR UPDATE ON public.legal_cases FOR EACH ROW EXECUTE FUNCTION check_dept_company();
CREATE TRIGGER invoices_dept BEFORE INSERT OR UPDATE ON public.invoices FOR EACH ROW EXECUTE FUNCTION check_dept_company();
CREATE TRIGGER documents_dept BEFORE INSERT OR UPDATE ON public.documents FOR EACH ROW EXECUTE FUNCTION check_dept_company();
CREATE TRIGGER requests_dept BEFORE INSERT OR UPDATE ON public.requests FOR EACH ROW EXECUTE FUNCTION check_dept_company();
CREATE TRIGGER notes_dept BEFORE INSERT OR UPDATE ON public.manager_notes FOR EACH ROW EXECUTE FUNCTION check_dept_company();
CREATE TRIGGER companies_seed AFTER INSERT ON public.companies FOR EACH ROW EXECUTE FUNCTION seed_departments();
CREATE TRIGGER rooms_creator AFTER INSERT ON public.rooms FOR EACH ROW EXECUTE FUNCTION room_add_creator();
CREATE TRIGGER room_members_check BEFORE INSERT ON public.room_members FOR EACH ROW EXECUTE FUNCTION room_member_check();
CREATE TRIGGER room_messages_touch AFTER INSERT ON public.room_messages FOR EACH ROW EXECUTE FUNCTION room_touch();
CREATE TRIGGER room_messages_protect BEFORE UPDATE ON public.room_messages FOR EACH ROW EXECUTE FUNCTION protect_message();
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ===== RLS =====
alter table public.companies enable row level security;
alter table public.departments enable row level security;
alter table public.profiles enable row level security;
alter table public.vehicles enable row level security;
alter table public.projects enable row level security;
alter table public.legal_cases enable row level security;
alter table public.invoices enable row level security;
alter table public.documents enable row level security;
alter table public.requests enable row level security;
alter table public.manager_notes enable row level security;
alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.room_messages enable row level security;
create policy comp_read on public.companies for SELECT to authenticated using ((is_super() OR (id = my_company())));
create policy comp_ins on public.companies for INSERT to authenticated with check (is_super());
create policy comp_upd on public.companies for UPDATE to authenticated using (can_manage(id)) with check (can_manage(id));
create policy comp_del on public.companies for DELETE to authenticated using (is_super());
create policy dep_read on public.departments for SELECT to authenticated using ((is_super() OR (company_id = my_company())));
create policy dep_ins on public.departments for INSERT to authenticated with check (can_manage(company_id));
create policy dep_upd on public.departments for UPDATE to authenticated using (can_manage(company_id)) with check (can_manage(company_id));
create policy dep_del on public.departments for DELETE to authenticated using (can_manage(company_id));
create policy prof_read on public.profiles for SELECT to authenticated using (((id = auth.uid()) OR is_super() OR ((company_id = my_company()) AND (is_company_admin() OR (department_id = my_department())))));
create policy prof_upd on public.profiles for UPDATE to authenticated using (((id = auth.uid()) OR can_manage(company_id))) with check (((id = auth.uid()) OR can_manage(company_id)));
do $$ declare t text; begin
  foreach t in array array['vehicles','projects','legal_cases','invoices','documents','requests'] loop
    execute format('create policy %1$s_read on public.%1$s for select to authenticated using (can_access(company_id, department_id))', t);
    execute format('create policy %1$s_ins on public.%1$s for insert to authenticated with check (can_access(company_id, department_id))', t);
    execute format('create policy %1$s_upd on public.%1$s for update to authenticated using (can_access(company_id, department_id)) with check (can_access(company_id, department_id))', t);
    execute format('create policy %1$s_del on public.%1$s for delete to authenticated using (can_manage(company_id))', t);
  end loop; end $$;
create policy notes_read on public.manager_notes for SELECT to authenticated using (can_access(company_id, department_id));
create policy notes_ins on public.manager_notes for INSERT to authenticated with check (can_manage(company_id));
create policy notes_upd on public.manager_notes for UPDATE to authenticated using (can_access(company_id, department_id));
create policy notes_del on public.manager_notes for DELETE to authenticated using (can_manage(company_id));
create policy rooms_read on public.rooms for SELECT to authenticated using ((can_manage(company_id) OR ((company_id = my_company()) AND ((created_by = auth.uid()) OR is_room_member(id)))));
create policy rooms_ins on public.rooms for INSERT to authenticated with check (((company_id = my_company()) OR is_super()));
create policy rooms_upd on public.rooms for UPDATE to authenticated using ((can_manage(company_id) OR ((company_id = my_company()) AND (created_by = auth.uid())))) with check ((can_manage(company_id) OR ((company_id = my_company()) AND (created_by = auth.uid()))));
create policy rooms_del on public.rooms for DELETE to authenticated using ((can_manage(company_id) OR ((company_id = my_company()) AND (created_by = auth.uid()))));
create policy rm_read on public.room_members for SELECT to authenticated using (can_see_room(room_id));
create policy rm_ins on public.room_members for INSERT to authenticated with check (can_admin_room(room_id));
create policy rm_del on public.room_members for DELETE to authenticated using ((can_admin_room(room_id) OR (user_id = auth.uid())));
create policy msg_read on public.room_messages for SELECT to authenticated using (can_see_room(room_id));
create policy msg_ins on public.room_messages for INSERT to authenticated with check (((user_id = auth.uid()) AND can_post_room(room_id)));
create policy msg_upd on public.room_messages for UPDATE to authenticated using (can_see_room(room_id)) with check (can_see_room(room_id));
create policy msg_del on public.room_messages for DELETE to authenticated using (((user_id = auth.uid()) OR can_admin_room(room_id)));
create policy avatars_read on storage.objects for SELECT to public using ((bucket_id = 'avatars'::text));
create policy avatars_ins on storage.objects for INSERT to authenticated with check (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy avatars_upd on storage.objects for UPDATE to authenticated using (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy avatars_del on storage.objects for DELETE to authenticated using (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = (auth.uid())::text)));
create policy rooms_files_read on storage.objects for SELECT to authenticated using (((bucket_id = 'rooms'::text) AND can_see_room(((storage.foldername(name))[1])::uuid)));
create policy rooms_files_ins on storage.objects for INSERT to authenticated with check (((bucket_id = 'rooms'::text) AND can_post_room(((storage.foldername(name))[1])::uuid)));
create policy rooms_files_del on storage.objects for DELETE to authenticated using (((bucket_id = 'rooms'::text) AND can_admin_room(((storage.foldername(name))[1])::uuid)));

-- ===== function privileges =====
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop; end $$;
grant execute on function public.lookup_company(text) to anon, authenticated;
grant execute on function public.admin_delete_user(uuid), public.delete_company(uuid), public.is_super(), public.my_company(),
  public.is_company_admin(), public.my_department(), public.can_access(uuid, uuid), public.can_manage(uuid),
  public.is_room_member(uuid), public.can_see_room(uuid), public.can_admin_room(uuid), public.can_post_room(uuid) to authenticated;

-- ===== storage + realtime =====
insert into storage.buckets(id, name, public, file_size_limit) values ('avatars','avatars',true,null), ('rooms','rooms',false,52428800) on conflict do nothing;
alter publication supabase_realtime add table public.room_messages;
