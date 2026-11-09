import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { extractWaMessages, verifyMetaSignature } from "../_shared/ai_core.ts";

// H7 foundation: receives WhatsApp Cloud API webhooks from Meta and puts each message in the review queue
// (public.wa_inbound). Nothing becomes a business record until a company admin reviews it in the platform.
// NOT ACTIVE until the owner provides a Meta WhatsApp Business account and sets these secrets:
//   WA_VERIFY_TOKEN (any random string, also entered in Meta's dashboard), WA_APP_SECRET (Meta app secret).
// Deploy with --no-verify-jwt (Meta does not send a Supabase JWT); authenticity comes from the HMAC signature.
// Media download and speech-to-text are left out on purpose: they need a WhatsApp access token and an STT
// provider key that have not been approved yet (see docs).

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const verify = Deno.env.get("WA_VERIFY_TOKEN"), secret = Deno.env.get("WA_APP_SECRET");
  if (!verify || !secret) return new Response("not configured", { status: 503 });

  // Meta subscription handshake
  if (req.method === "GET") {
    if (url.searchParams.get("hub.mode") === "subscribe" && url.searchParams.get("hub.verify_token") === verify)
      return new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200 });
    return new Response("forbidden", { status: 403 });
  }
  if (req.method !== "POST") return new Response("method", { status: 405 });

  const raw = await req.text();
  if (raw.length > 1_000_000) return new Response("too large", { status: 413 });
  if (!(await verifyMetaSignature(raw, req.headers.get("X-Hub-Signature-256"), secret))) return new Response("bad signature", { status: 401 });

  const adm = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  let payload: unknown;
  try { payload = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }

  for (const m of extractWaMessages(payload)) {
    const { data: who } = await adm.rpc("match_whatsapp_sender", { p: m.from_phone });
    const row = { ...m, company_id: who?.company_id ?? null, profile_id: who?.profile_id ?? null, status: who?.profile_id ? "needs_review" : "unmatched" };
    // idempotent: Meta retries deliveries; wa_message_id is unique
    const { error } = await adm.from("wa_inbound").upsert(row, { onConflict: "wa_message_id", ignoreDuplicates: true });
    if (error) await adm.from("system_events").insert({ level: "error", source: "edge:whatsapp-webhook", message: error.message.slice(0, 500) });
  }
  // always 200 quickly so Meta does not retry valid deliveries
  return new Response("ok", { status: 200 });
});
