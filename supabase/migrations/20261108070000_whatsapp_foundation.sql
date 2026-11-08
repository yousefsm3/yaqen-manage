-- H7 (foundation): inbound WhatsApp messages land in a review queue, are matched to the sending employee
-- by phone number, and become company records only after a human approves them (no automatic writes).
-- The live connection to Meta WhatsApp Business API + speech-to-text needs the owner's accounts/keys (see docs).
-- Rollback: supabase/rollback/20261108070000_whatsapp_foundation.down.sql

-- E.164-style digits only, Saudi local numbers normalised to 966...
create or replace function public.norm_phone(p text) returns text language sql immutable parallel safe set search_path = '' as $$
  select case
    when d ~ '^05\d{8}$' then '966' || substr(d, 2)
    when d ~ '^5\d{8}$' then '966' || d
    when d ~ '^00\d+$' then substr(d, 3)
    else d end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') d) x $$;
create index if not exists profiles_phone_norm_idx on public.profiles (public.norm_phone(phone)) where phone is not null;

create table if not exists public.wa_inbound (
  id uuid primary key default gen_random_uuid(),
  received_at timestamptz not null default now(),
  wa_message_id text not null unique,                 -- idempotency: Meta retries deliveries
  from_phone text not null,
  company_id uuid references public.companies(id) on delete cascade,
  profile_id uuid references auth.users(id) on delete set null,
  msg_type text not null check (msg_type in ('text', 'image', 'document', 'audio', 'other')),
  body text,
  media_id text,
  media_mime text,
  storage_path text,
  transcript text,                                    -- from speech-to-text (needs a provider key)
  translation jsonb,
  ai_extraction jsonb,                                -- proposed record, never applied automatically
  status text not null default 'needs_review' check (status in ('needs_review', 'unmatched', 'converted', 'rejected')),
  target_entity text,
  target_id uuid,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  raw jsonb
);
create index if not exists wa_inbound_company_status_idx on public.wa_inbound (company_id, status, received_at desc);
create index if not exists wa_inbound_profile_idx on public.wa_inbound (profile_id);
create index if not exists wa_inbound_reviewed_by_idx on public.wa_inbound (reviewed_by);
alter table public.wa_inbound enable row level security;
revoke all on public.wa_inbound from anon, authenticated;
grant select on public.wa_inbound to authenticated;
create policy wa_read on public.wa_inbound for select to authenticated
  using ((select public.is_super()) or (company_id = (select public.my_company()) and (select public.is_company_admin())));

-- used by the webhook (service role only): who is this sender?
create or replace function public.match_whatsapp_sender(p text) returns json
language sql stable security definer set search_path = 'public' as $$
  select json_build_object('profile_id', p2.id, 'company_id', p2.company_id, 'department_id', p2.department_id, 'full_name', p2.full_name)
  from profiles p2 join companies c on c.id = p2.company_id
  where public.norm_phone(p2.phone) = public.norm_phone(p) and p2.status = 'active' and c.active
  order by p2.created_at limit 1 $$;
revoke execute on function public.match_whatsapp_sender(text) from public, anon, authenticated;
grant execute on function public.match_whatsapp_sender(text) to service_role;

-- admin decision on a queued message. Converting creates the record through normal RLS-checked inserts in the app;
-- this function only records the decision and links the created record.
create or replace function public.review_wa_message(mid uuid, decision text, entity text default null, eid uuid default null) returns void
language plpgsql security definer set search_path = 'public' as $$
declare cid uuid;
begin
  select company_id into cid from wa_inbound where id = mid;
  if cid is null or not public.can_manage(cid) then raise exception 'غير مصرح'; end if;
  if decision not in ('converted', 'rejected') then raise exception 'قرار غير صحيح'; end if;
  update wa_inbound set status = decision, target_entity = entity, target_id = eid, reviewed_by = auth.uid(), reviewed_at = now() where id = mid;
end $$;
revoke execute on function public.review_wa_message(uuid, text, text, uuid) from public, anon;
grant execute on function public.review_wa_message(uuid, text, text, uuid) to authenticated;
revoke execute on function public.norm_phone(text) from public, anon;
grant execute on function public.norm_phone(text) to authenticated, service_role;
