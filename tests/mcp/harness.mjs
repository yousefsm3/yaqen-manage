// Test harness for the MCP core against the local staging database.
// Replaces the two network hops that cannot run here, with the same semantics:
//   - Supabase GoTrue  -> HS256 JWT verification (signature, expiry, role). Session liveness is checked by the DB guard.
//   - PostgREST GET    -> psql: BEGIN READ ONLY; SET LOCAL ROLE authenticated; request.jwt.claims; request.method=GET;
//                         pre_request(); select fn(...). Same role, claims, hook and read-only transaction as production.
// What this does NOT cover: real GoTrue, real PostgREST, network, OAuth consent flow (see docs/mcp/04_TEST_REPORT.md).
import { spawn } from "node:child_process";
import { createHmac, randomUUID } from "node:crypto";

export const SECRET = "local-test-secret-not-used-anywhere-else";
const PG = ["-h", "localhost", "-p", process.env.PGPORT || "54329", "-U", "postgres", "-d", process.env.DB || "yaqen_staging", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"];

export const IDS = {
  A1: "00000000-0000-0000-0000-0000000000a1", A2: "00000000-0000-0000-0000-0000000000a2", A3: "00000000-0000-0000-0000-0000000000a3",
  A4: "00000000-0000-0000-0000-0000000000a4", B1: "00000000-0000-0000-0000-0000000000b1", B2: "00000000-0000-0000-0000-0000000000b2",
  OWNER: "00000000-0000-0000-0000-0000000000f0",
};
export const sessionOf = (uid) => "00000000-0000-0000-5e55-0000000000" + uid.slice(-2);

const b64u = (b) => Buffer.from(b).toString("base64url");
export function signJwt(claims, { secret = SECRET, alg = "HS256" } = {}) {
  const h = b64u(JSON.stringify({ alg, typ: "JWT" })), p = b64u(JSON.stringify(claims));
  const sig = alg === "none" ? "" : createHmac("sha256", secret).update(h + "." + p).digest("base64url");
  return `${h}.${p}.${sig}`;
}
export function tokenFor(uid, { session = sessionOf(uid), oauth = true, exp = Math.floor(Date.now() / 1000) + 3600, extra = {} } = {}) {
  return signJwt({ sub: uid, role: "authenticated", aud: "authenticated", session_id: session, exp, ...(oauth ? { client_id: "claude-test-client" } : {}), ...extra });
}
function verifyJwt(token) {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  let header, claims;
  try { header = JSON.parse(Buffer.from(parts[0], "base64url")); claims = JSON.parse(Buffer.from(parts[1], "base64url")); } catch { return null; }
  if (header.alg !== "HS256") return null;
  const expect = createHmac("sha256", SECRET).update(parts[0] + "." + parts[1]).digest("base64url");
  if (expect !== parts[2]) return null;
  if (typeof claims.exp !== "number" || claims.exp * 1000 < Date.now()) return null;
  if (claims.role !== "authenticated" || !/^[0-9a-f-]{36}$/i.test(claims.sub || "")) return null;
  return claims;
}

export function psql(sql) {
  return new Promise((resolve) => {
    const p = spawn("psql", PG, { stdio: ["pipe", "pipe", "pipe"] });
    let out = "", err = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    p.on("close", (code) => resolve({ code, out: out.trim(), err: err.trim() }));
    p.stdin.end(sql);
  });
}
const lit = (v) => (v === null || v === undefined ? "null" : "'" + String(v).replace(/'/g, "''") + "'");

export function makeDeps({ log = [], rpcOverride = null } = {}) {
  return {
    resourceUrl: "https://example.supabase.co/functions/v1/yaqen-mcp",
    authorizationServer: "https://example.supabase.co/auth/v1",
    async verifyToken(token) { const c = verifyJwt(token); return c ? { userId: c.sub } : null; },
    async rpc(token, fn, args) {
      if (rpcOverride) return rpcOverride(token, fn, args);
      const claims = verifyJwt(token);   // PostgREST also verifies the JWT
      if (!claims) return { error: { message: "JWT invalid", code: "PGRST301" } };
      if (!/^mcp_[a-z_]+$/.test(fn)) return { error: { message: "function not allowed in harness" } };
      const call = `select public.${fn}(${Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(", ")})::text;`;
      const sql = `begin read only;\nset local role authenticated;\nset local request.jwt.claims = ${lit(JSON.stringify(claims))};\n`
        + `set local request.method = 'GET';\nselect public.pre_request();\n${call}\ncommit;\n`;
      const r = await psql(sql);
      if (r.code !== 0) {
        const m = r.err.match(/ERROR:\s+(.*)/);
        const code = (r.err.match(/SQLSTATE[: ]+([0-9A-Z]{5})/) || [])[1];
        return { error: { message: m ? m[1] : r.err, code } };
      }
      const lines = r.out.split("\n").filter(Boolean);
      return { data: JSON.parse(lines[lines.length - 1]) };
    },
    async begin(userId, tool) {
      const r = await psql(`select public.mcp_begin(${lit(userId)}, ${lit(tool)})::text;`);
      return r.code === 0 ? JSON.parse(r.out) : { ok: false, reason: "UPSTREAM_UNAVAILABLE" };
    },
    async end(callId, ok, ms, rows, errorCode) {
      await psql(`select public.mcp_end(${callId}, ${ok}, ${ms}, ${rows}, ${lit(errorCode)});`);
    },
    async logError(message, context) { log.push({ message, context }); },
  };
}

// JSON-RPC helpers
let n = 0;
export function post(body, token, headers = {}) {
  return { method: "POST", path: "/functions/v1/yaqen-mcp", body: typeof body === "string" ? body : JSON.stringify(body),
    headers: { "content-type": "application/json", ...(token ? { authorization: "Bearer " + token } : {}), ...headers } };
}
export const call = (name, args, id = ++n) => ({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } });
export const req = (method, params, id = ++n) => ({ jsonrpc: "2.0", id, method, params });
export const uuid = randomUUID;
