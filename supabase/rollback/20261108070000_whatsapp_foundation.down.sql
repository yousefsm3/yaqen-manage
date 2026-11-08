drop function if exists public.review_wa_message(uuid, text, text, uuid);
drop function if exists public.match_whatsapp_sender(text);
drop table if exists public.wa_inbound;
drop index if exists public.profiles_phone_norm_idx;
drop function if exists public.norm_phone(text);
