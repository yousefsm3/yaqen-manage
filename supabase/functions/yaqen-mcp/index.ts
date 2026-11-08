import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { handleHttp, type McpDeps } from "../_shared/mcp_core.ts";

// Yaqen MCP connector (read-only). NOT DEPLOYED. Requires, before deployment (docs/mcp/05_OPERATIONS.md):
//  - migrations 20261108010000..20261109000000 applied (tools, guard, OAuth write-block, pre-request hook)
//  - Supabase Auth OAuth 2.1 server enabled + consent page (project setting; owner decision)
//  - deploy with --no-verify-jwt: this function validates tokens itself and must return 401 + WWW-Authenticate
// Secrets: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (platform-provided), MCP_RESOURCE_URL (optional).
const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESOURCE = Deno.env.get("MCP_RESOURCE_URL") ?? `${URL_}/functions/v1/yaqen-mcp`;

// service role: ONLY for the usage log / rate limit and error log. Never for reading business data.
const svc = createClient(URL_, SERVICE, { auth: { persistSession: false } });
const anon = createClient(URL_, ANON, { auth: { persistSession: false } });

const deps: McpDeps = {
  resourceUrl: RESOURCE,
  authorizationServer: `${URL_}/auth/v1`,
  async verifyToken(token) {
    const { data, error } = await anon.auth.getUser(token);   // GoTrue checks signature, expiry and the session
    return error || !data?.user ? null : { userId: data.user.id };
  },
  async rpc(token, fn, args) {
    const asUser = createClient(URL_, ANON, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data, error } = await asUser.rpc(fn, args, { get: true });   // GET = read-only transaction in PostgREST
    return { data, error: error ? { message: error.message, code: error.code } : null };
  },
  async begin(userId, tool) {
    const { data, error } = await svc.rpc("mcp_begin", { p_user: userId, p_tool: tool });
    return error ? { ok: false, reason: "UPSTREAM_UNAVAILABLE" } : data;
  },
  async end(callId, ok, ms, rows, errorCode) {
    await svc.rpc("mcp_end", { p_call: callId, p_ok: ok, p_ms: ms, p_rows: rows, p_error: errorCode });
  },
  async logError(message, context) {
    await svc.from("system_events").insert({ level: "error", source: "edge:yaqen-mcp", message: message.slice(0, 500), context });
  },
};

Deno.serve(async (req) => {
  const u = new URL(req.url);
  const headers: Record<string, string> = {};
  req.headers.forEach((v, k) => { headers[k] = v; });
  const body = req.method === "POST" ? await req.text() : "";
  const r = await handleHttp({ method: req.method, path: u.pathname, headers, body }, deps);
  return new Response(r.body || null, { status: r.status, headers: r.headers });
});
