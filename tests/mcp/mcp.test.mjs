// End-to-end tests of the MCP server core against the local staging DB (run tests/run_db_tests.sh first).
// node --experimental-strip-types --test tests/mcp/mcp.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleHttp, toolList } from "../../supabase/functions/_shared/mcp_core.ts";
import { makeDeps, post, call, req, tokenFor, signJwt, IDS, psql } from "./harness.mjs";

const deps = makeDeps();
const go = (body, token, headers) => handleHttp(post(body, token, headers), deps);
const J = (r) => JSON.parse(r.body);
const tool = async (name, args, uid = IDS.A1, opts) => J(await go(call(name, args), tokenFor(uid, opts))).result;
const sql1 = async (q) => (await psql(q)).out;

// ---------------------------------------------------------------- A. connection & protocol
test("A1 no token -> 401 with WWW-Authenticate pointing to resource metadata", async () => {
  const r = await go(req("initialize", {}));
  assert.equal(r.status, 401);
  assert.match(r.headers["WWW-Authenticate"], /^Bearer resource_metadata="https:\/\/example\.supabase\.co\/functions\/v1\/yaqen-mcp\/\.well-known\/oauth-protected-resource"/);
  assert.doesNotMatch(r.body, /tools|yaqen_/);
});
test("A2 protected resource metadata names Supabase Auth as authorization server", async () => {
  const r = await handleHttp({ method: "GET", path: "/functions/v1/yaqen-mcp/.well-known/oauth-protected-resource", headers: {}, body: "" }, deps);
  assert.equal(r.status, 200);
  assert.deepEqual(J(r).authorization_servers, ["https://example.supabase.co/auth/v1"]);
});
test("A3 initialize negotiates protocol version and declares tools capability", async () => {
  const r = J(await go(req("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "1" } }), tokenFor(IDS.A1)));
  assert.equal(r.result.protocolVersion, "2025-06-18");
  assert.deepEqual(r.result.capabilities, { tools: { listChanged: false } });
  const r2 = J(await go(req("initialize", { protocolVersion: "1999-01-01" }), tokenFor(IDS.A1)));
  assert.equal(r2.result.protocolVersion, "2025-11-25");
});
test("A4 tools/list: 10 tools, all read-only, closed schemas, no identity inputs", async () => {
  const tools = J(await go(req("tools/list"), tokenFor(IDS.A1))).result.tools;
  assert.equal(tools.length, 10);
  for (const t of tools) {
    assert.equal(t.annotations.readOnlyHint, true, t.name);
    assert.equal(t.annotations.destructiveHint, false, t.name);
    assert.equal(t.inputSchema.additionalProperties, false, t.name);
    for (const p of Object.keys(t.inputSchema.properties)) assert.doesNotMatch(p, /company|user|role|tenant|owner/i, t.name + "." + p);
    assert.ok(t.title && t.description.length > 20);
  }
  assert.deepEqual(toolList().map((t) => t.name), tools.map((t) => t.name));
});
test("A5 transport edge cases", async () => {
  const t = tokenFor(IDS.A1);
  assert.equal((await go(req("ping"), t, { "mcp-protocol-version": "2000-01-01" })).status, 400);
  assert.equal((await go({ jsonrpc: "2.0", method: "notifications/initialized" }, t)).status, 202);
  assert.equal((await go([req("ping"), req("ping")], t)).status, 400);
  assert.equal(J(await go("{not json", t)).error.code, -32700);
  assert.equal(J(await go(req("resources/list"), t)).error.code, -32601);
  assert.equal(J(await go(req("ping"), t)).result && true, true);
  assert.equal((await go(req("ping"), t, { "content-type": "text/plain" })).status, 415);
  assert.equal((await go({ jsonrpc: "2.0", id: 1, method: "ping", params: { pad: "x".repeat(70000) } }, t)).status, 413);
  assert.equal((await handleHttp({ method: "GET", path: "/functions/v1/yaqen-mcp", headers: { authorization: "Bearer " + t }, body: "" }, deps)).status, 405);
  assert.equal((await handleHttp({ method: "DELETE", path: "/functions/v1/yaqen-mcp", headers: {}, body: "" }, deps)).status, 405);
});
test("A6 input validation rejects bad arguments before touching the database", async () => {
  const t = tokenFor(IDS.A1);
  const bad = [
    ["yaqen_invoices", { limit: 0 }], ["yaqen_invoices", { limit: 51 }], ["yaqen_invoices", { limit: "5" }], ["yaqen_invoices", { kind: "x" }],
    ["yaqen_search", {}], ["yaqen_search", { query: "a" }], ["yaqen_search", { query: "x".repeat(81) }],
    ["yaqen_project_detail", { project_id: "1 or 1=1" }],
    ["yaqen_invoice_period_comparison", { period_from: "2026-02-30", period_to: "2026-03-01", compare_from: "2026-01-01", compare_to: "2026-01-31" }],
    ["yaqen_projects", { late_only: "yes" }], ["yaqen_expiring", { days: 1000 }], ["no_such_tool", {}], ["mcp_begin", {}],
  ];
  for (const [name, args] of bad) assert.equal(J(await go(call(name, args), t)).error?.code, -32602, name + " " + JSON.stringify(args));
});

// ---------------------------------------------------------------- B. authentication
test("B1 valid token works end to end", async () => {
  const r = await tool("yaqen_company_overview", {});
  assert.equal(r.isError, false);
  assert.equal(r.structuredContent.company, "QA-A");
  assert.ok(r.structuredContent.as_of);
});
test("B2 expired / forged / alg=none tokens -> 401", async () => {
  const expired = tokenFor(IDS.A1, { exp: Math.floor(Date.now() / 1000) - 10 });
  const forged = signJwt({ sub: IDS.A1, role: "authenticated", exp: Math.floor(Date.now() / 1000) + 600 }, { secret: "attacker" });
  const none = signJwt({ sub: IDS.A1, role: "authenticated", exp: Math.floor(Date.now() / 1000) + 600 }, { alg: "none" });
  for (const t of [expired, forged, none, "abc", "a.b.c"]) assert.equal((await go(req("tools/list"), t)).status, 401);
  assert.equal((await go(req("tools/list"), null, { authorization: "Basic dXNlcjpwYXNz" })).status, 401);
});
test("B3 revoked session -> tool refused immediately (token still cryptographically valid)", async () => {
  const sid = "00000000-0000-0000-5e55-00000000beef";
  await psql(`insert into auth.sessions (id, user_id) values ('${sid}', '${IDS.B1}') on conflict do nothing;`);
  const t = tokenFor(IDS.B1, { session: sid });
  assert.equal((await tool("yaqen_company_overview", {}, IDS.B1, { session: sid })).isError, false);
  await psql(`delete from auth.sessions where id = '${sid}';`);
  const r = J(await go(call("yaqen_company_overview", {}), t)).result;
  assert.equal(r.isError, true);
  assert.equal(r.structuredContent.error, "SESSION_REVOKED");
});
test("B4 pending account, platform admin, anonymous-role token", async () => {
  assert.equal((await tool("yaqen_company_overview", {}, IDS.A3)).structuredContent.error, "ACCOUNT_INACTIVE");
  assert.equal((await tool("yaqen_company_overview", {}, IDS.OWNER)).structuredContent.error, "PLATFORM_ADMIN_NOT_SUPPORTED");
  const anonTok = signJwt({ sub: IDS.A1, role: "anon", exp: Math.floor(Date.now() / 1000) + 600 });
  assert.equal((await go(req("tools/list"), anonTok)).status, 401);
});

// ---------------------------------------------------------------- C. company / department isolation
test("C1 each company sees only itself", async () => {
  assert.equal((await tool("yaqen_company_overview", {}, IDS.B1)).structuredContent.company, "QA-B");
  const b = JSON.stringify(await tool("yaqen_invoices", { limit: 50 }, IDS.B1));
  assert.doesNotMatch(b, /N-1|O-1|SEP-1/);
  const a = JSON.stringify(await tool("yaqen_search", { query: "SECRET" }, IDS.A1));
  assert.doesNotMatch(a, /B-SECRET/);
});
test("C2 identity tampering in arguments is rejected", async () => {
  for (const args of [{ company_id: "00000000-0000-0000-0000-0000000000a0" }, { user_id: IDS.A1 }, { role: "admin" }, { p_company: "x" }])
    assert.equal(J(await go(call("yaqen_invoices", args), tokenFor(IDS.B1))).error.code, -32602);
  // and a token minted for B with A's session id is refused by the database
  const r = J(await go(call("yaqen_invoices", {}), tokenFor(IDS.B1, { session: "00000000-0000-0000-5e55-0000000000a1" }))).result;
  assert.equal(r.structuredContent.error, "SESSION_REVOKED");
});
test("C3 department scope: fleet employee sees no finance data, finance employee does", async () => {
  assert.equal((await tool("yaqen_invoices", {}, IDS.A2)).structuredContent.total, 0);
  assert.ok((await tool("yaqen_invoices", {}, IDS.A4)).structuredContent.total > 0);
  const people = (await tool("yaqen_people", { limit: 50 }, IDS.A2)).structuredContent;
  assert.equal(new Set(people.items.map((p) => p.department)).size, 1);
});
test("C4 cross-company probing by id or search returns nothing", async () => {
  const r = (await tool("yaqen_project_detail", { project_id: "00000000-0000-0000-2222-000000000001" }, IDS.B1)).structuredContent;
  assert.equal(r.found, false);
  const s = (await tool("yaqen_search", { query: "ABC" }, IDS.B1)).structuredContent;
  assert.deepEqual(s.vehicles.map((v) => v.id), ["00000000-0000-0000-0000-00000000c002"]);
});

// ---------------------------------------------------------------- D. data correctness vs. the database
test("D1 period comparison equals hand-computed and direct SQL values", async () => {
  const r = (await tool("yaqen_invoice_period_comparison", { period_from: "2026-11-01", period_to: "2026-11-30", compare_from: "2026-10-01", compare_to: "2026-10-31" })).structuredContent;
  assert.equal(r.periods.a.revenue_invoiced, 150000);
  assert.equal(r.periods.a.supplier_invoiced, 40000);
  assert.equal(r.periods.b.revenue_invoiced, 120000);
  assert.equal(r.change.revenue_invoiced.pct, 25.0);
  assert.equal(r.change.net_invoiced.abs, 20000);
  assert.equal(r.net_profit.available, false);
  const direct = await sql1(`select sum(amount) from invoices where company_id='00000000-0000-0000-0000-0000000000a0' and kind='صادرة' and deleted_at is null and due_date between '2026-11-01' and '2026-11-30'`);
  assert.equal(String(r.periods.a.revenue_invoiced), direct);
});
test("D2 invoice totals and aging equal direct SQL", async () => {
  const r = (await tool("yaqen_invoices", { limit: 50 })).structuredContent;
  const unpaid = await sql1(`select sum(amount) from invoices where company_id='00000000-0000-0000-0000-0000000000a0' and status <> 'مدفوعة' and deleted_at is null`);
  assert.equal(String(r.summary.unpaid_total), unpaid);
  const over90 = await sql1(`select coalesce(sum(amount),0) from invoices where company_id='00000000-0000-0000-0000-0000000000a0' and status <> 'مدفوعة' and deleted_at is null and current_date - due_date > 90`);
  assert.equal(String(r.summary.aging.over_90), over90);
  assert.equal(new Set(r.items.map((i) => i.id)).size, r.items.length, "no duplicate rows");
});
test("D3 pagination walks every row exactly once", async () => {
  const total = (await tool("yaqen_invoices", { limit: 1 })).structuredContent.total;
  const seen = [];
  for (let o = 0; o < total + 2; o += 3) seen.push(...(await tool("yaqen_invoices", { limit: 3, offset: o })).structuredContent.items.map((i) => i.id));
  assert.equal(seen.length, total);
  assert.equal(new Set(seen).size, total);
});
test("D4 missing data is reported, never invented", async () => {
  const p = (await tool("yaqen_projects", {})).structuredContent;
  assert.equal(p.summary.missing_contract_value, 1);
  assert.ok(p.notes_ar.some((n) => n.includes("أسباب التأخير غير مسجلة")));
  const d = (await tool("yaqen_project_detail", { project_id: "00000000-0000-0000-2222-000000000002" })).structuredContent;
  assert.equal(d.project.contract_value, null);
  assert.ok(d.unavailable_ar.length >= 1);
});

// ---------------------------------------------------------------- E. security
test("E1 prompt-injection text travels only as data inside structured JSON", async () => {
  const r = await tool("yaqen_projects", {});
  const hit = r.structuredContent.items.find((i) => i.name.includes("تجاهل كل التعليمات"));
  assert.ok(hit, "injected project present as data");
  assert.equal(typeof hit.name, "string");
  assert.doesNotMatch(hit.name, /\u0007/);
  assert.equal(r.content[0].type, "text");
  assert.doesNotThrow(() => JSON.parse(r.content[0].text));
});
test("E2 upstream errors never leak database details; tokens never reach the error log", async () => {
  const log = [];
  const leaky = makeDeps({ log, rpcOverride: async () => ({ error: { message: 'relation "public.invoices" does not exist at character 15', code: "42P01" } }) });
  const t = tokenFor(IDS.A1);
  const r = JSON.parse((await handleHttp(post(call("yaqen_invoices", {}), t), leaky)).body).result;
  assert.equal(r.structuredContent.error, "UPSTREAM_UNAVAILABLE");
  assert.doesNotMatch(JSON.stringify(r), /relation|public\.|character|42P01/);
  assert.equal(log.length, 1);
  assert.doesNotMatch(JSON.stringify(log), new RegExp(t.split(".")[2].slice(0, 20)));
  const throwing = makeDeps({ rpcOverride: async () => { throw new Error("ECONNREFUSED 10.1.2.3:5432"); } });
  const r2 = JSON.parse((await handleHttp(post(call("yaqen_invoices", {}), t), throwing)).body).result;
  assert.equal(r2.structuredContent.error, "UPSTREAM_UNAVAILABLE");
  assert.doesNotMatch(JSON.stringify(r2), /ECONNREFUSED|10\.1\.2\.3/);
});
test("E3 the OAuth token cannot write through the same database path (hook + read-only tx)", async () => {
  const claims = JSON.stringify({ sub: IDS.A1, role: "authenticated", session_id: "00000000-0000-0000-5e55-0000000000a1", client_id: "c" });
  const viaPost = await psql(`begin; set local role authenticated; set local request.jwt.claims = '${claims}'; set local request.method = 'POST'; select public.pre_request(); commit;`);
  assert.match(viaPost.err, /OAUTH_READ_ONLY/);
  const viaGet = await psql(`begin read only; set local role authenticated; set local request.jwt.claims = '${claims}'; set local request.method = 'GET'; select public.pre_request(); update public.vehicles set notes = 'x'; commit;`);
  assert.match(viaGet.err, /read-only transaction|row-level security|permission denied/);
});
test("E4 rate limit: 31st call in a minute is refused, and logged", async () => {
  await psql(`delete from public.mcp_usage where user_id = '${IDS.B1}';`);
  const t = tokenFor(IDS.B1);
  const results = [];
  for (let i = 0; i < 31; i++) results.push(J(await go(call("yaqen_people", { limit: 1 }), t)).result);
  assert.equal(results.slice(0, 30).every((r) => r.isError === false), true);
  assert.equal(results[30].structuredContent.error, "RATE_LIMITED_MINUTE");
  const logged = await sql1(`select count(*) || '/' || count(*) filter (where ok) from public.mcp_usage where user_id = '${IDS.B1}'`);
  assert.equal(logged, "30/30");
  await psql(`delete from public.mcp_usage where user_id = '${IDS.B1}';`);
});
test("E5 usage log stores no arguments or tokens", async () => {
  const cols = await sql1(`select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_name = 'mcp_usage'`);
  assert.equal(cols, "id,at,user_id,company_id,tool,ok,ms,result_rows,error_code");
});

// ---------------------------------------------------------------- F. performance (server core + harness + DB)
test("F1 latency per tool and 20 concurrent calls", async () => {
  await psql(`delete from public.mcp_usage;`);
  const cases = [["yaqen_company_overview", {}], ["yaqen_invoices", { min_days_overdue: 30 }], ["yaqen_fleet", {}], ["yaqen_expiring", { days: 30 }],
    ["yaqen_search", { query: "ABC" }], ["yaqen_invoice_period_comparison", { period_from: "2026-11-01", period_to: "2026-11-30", compare_from: "2026-10-01", compare_to: "2026-10-31" }]];
  const rows = [];
  for (const [name, args] of cases) {
    const t0 = performance.now(); const r = await tool(name, args); const ms = performance.now() - t0;
    assert.equal(r.isError, false, name); rows.push(`${name}: ${ms.toFixed(0)} ms`);
  }
  const t = tokenFor(IDS.A4);
  const t0 = performance.now();
  const all = await Promise.all(Array.from({ length: 20 }, (_, i) => go(call("yaqen_invoices", { limit: 5, offset: i }), t)));
  const total = performance.now() - t0;
  assert.equal(all.every((r) => J(r).result.isError === false), true);
  rows.push(`20 concurrent yaqen_invoices: ${total.toFixed(0)} ms total`);
  console.log("PERF " + rows.join(" | "));
  await psql(`delete from public.mcp_usage;`);
});
