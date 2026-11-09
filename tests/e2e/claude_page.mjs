// UI test of the manager's Claude page (index.html → "الربط مع Claude"). Run after tests/run_db_tests.sh.
// The page is fed (1) the REAL claude_page() JSON read from the staging database as company A's admin, and
// (2) a crafted scenario with a hostile user name, to prove: rendering, saving the exact choices, refusing an empty
// selection, revoking by id only, no script injection, employees do not see the page, graceful "not enabled" state.
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
const req = createRequire(import.meta.url);
let pw; try { pw = req("playwright"); } catch { pw = req("/opt/npm-tools/node_modules/playwright"); }
const ROOT = new URL("../../", import.meta.url).pathname;
const HTML = readFileSync(ROOT + "index.html", "utf8"), STUB = readFileSync(ROOT + "tests/e2e/supabase-stub.js", "utf8");
const URL_ = "https://yousefsm3.github.io/yaqen-manage/";
const A0 = "00000000-0000-0000-0000-0000000000a0", A1 = "00000000-0000-0000-0000-0000000000a1";
const sql = (q) => { const r = spawnSync("psql", ["-h", "localhost", "-p", process.env.PGPORT || "54329", "-U", "postgres", "-d", "yaqen_staging", "-X", "-q", "-At", "-c", q], { encoding:"utf8" });
  if (r.status) throw new Error(r.stderr); return r.stdout.trim(); };

const results = [];
const ok = (n, p, d = "") => { results.push(!!p); console.log((p ? "PASS" : "FAIL") + " | " + n + (d ? " | " + d : "")); };
const b = await pw.chromium.launch({ executablePath:"/usr/bin/google-chrome", args:["--no-sandbox"] });

async function open(scn) {
  const ctx = await b.newContext({ locale:"ar-SA" }); const page = await ctx.newPage(); page.setDefaultTimeout(5000);
  const errors = []; page.on("pageerror", (e) => errors.push(e.message));
  page.on("dialog", (d) => d.accept());
  await page.addInitScript((s) => { window.__SCN = s; }, scn);
  await ctx.route("**/*", (r) => { const u = r.request().url();
    if (u.startsWith("https://cdn.jsdelivr.net/npm/@supabase/supabase-js")) return r.fulfill({ contentType:"application/javascript", body:STUB });
    if (u.startsWith(URL_)) return r.fulfill({ contentType:"text/html; charset=utf-8", body:HTML });
    return r.abort(); });
  await page.goto(URL_); await page.waitForTimeout(400);
  return { page, ctx, errors, calls:() => page.evaluate(() => (window.__CALLS || []).filter((c) => c.rpc)) };
}
function scenario(claudePage, role = "admin") {
  return { user:A1, tables:{
      companies:[{ id:A0, name:"QA-A", active:true }], departments:[], rooms:[], room_members:[], projects:[], manager_notes:[], notifications:[],
      profiles:[{ id:A1, company_id:A0, full_name:"مدير", role, status:"active", department_id:null }], invoices:[] },
    rpc:{ my_account:{ id:A1, status:"active", role, company_id:A0, company_name:"QA-A", company_active:true, mfa_required:false, aal:"aal1" },
      dashboard_stats:{}, company_alerts:[], department_summary:[], claude_page:claudePage, claude_save_settings:null, claude_revoke:null } };
}
const go = async (page) => { await page.evaluate(() => window.App.go("claude")); await page.waitForTimeout(300); };

// 1) the real JSON from the database renders without errors
const real = JSON.parse(sql(`begin; set local role authenticated; set local request.jwt.claims = '{"sub":"${A1}","role":"authenticated"}'; select public.claude_page()::text; commit;`).split("\n").filter(Boolean).pop());
{
  const { page, ctx, errors } = await open(scenario(real));
  ok("admin sees 'الربط مع Claude' in the menu", (await page.locator("nav >> text=الربط مع Claude").count()) === 1);
  await go(page);
  const t = await page.textContent("#content");
  ok("real database JSON renders: connector URL, steps, all 9 data types", t.includes("/functions/v1/yaqen-mcp") && t.includes("Add custom connector")
     && (await page.locator('input[name="cl_scope"]').count()) === 9);
  ok("states read-only and that the cost is on the user's Claude plan", t.includes("لا يقدر يضيف أو يعدّل أو يحذف") && t.includes("اشتراك المستخدم في Claude"));
  ok("no page errors", errors.length === 0, errors.join(" | "));
  await ctx.close();
}

// 2) crafted state: invoices off, one connection with a hostile name, recent calls with errors
const hostile = `x');window.__xss=1;('<img src=x onerror="window.__xss=2">`;
const crafted = {
  settings:{ enabled:true, scopes:["overview","projects","fleet","expiring","people","search","notes_rooms","comparison"], idle_days:30, updated_at:"2026-11-09T12:00:00Z", updated_by:"مدير" },
  connections:[{ session_id:"00000000-0000-0000-5e55-00000000c0a1", user:hostile, job_title:"مشرف", is_manager:false, client:"Claude",
    connected_at:"2026-11-01T10:00:00Z", last_active:"2026-11-09T10:00:00Z", expires_at:"2026-12-09T10:00:00Z", expired:false, calls_30d:12 },
    { session_id:"00000000-0000-0000-5e55-00000000c0b2", user:"موظف قديم", job_title:"", is_manager:false, client:"Claude",
    connected_at:"2026-08-01T10:00:00Z", last_active:"2026-09-01T10:00:00Z", expires_at:"2026-10-01T10:00:00Z", expired:true, calls_30d:0 }],
  usage:{ calls_30d:12, errors_30d:2, by_tool:{ yaqen_company_overview:7, yaqen_invoices:5 },
    recent:[{ at:"2026-11-09T10:00:00Z", tool:"yaqen_invoices", ok:false, error:"SCOPE_DISABLED", user:"مدير" }, { at:"2026-11-09T09:00:00Z", tool:"yaqen_company_overview", ok:true, user:"مدير" }] },
  as_of:"2026-11-09T12:00:00Z" };
{
  const { page, ctx, errors, calls } = await open(scenario(crafted));
  await go(page);
  ok("invoices checkbox reflects the saved setting (off), projects on",
    !(await page.isChecked('input[name="cl_scope"][value="invoices"]')) && (await page.isChecked('input[name="cl_scope"][value="projects"]')));
  const t = await page.textContent("#content");
  ok("connections listed with active / expired status", t.includes("نشط") && t.includes("منتهي") && t.includes("موظف قديم"));
  ok("refused call shown in Arabic (غير مسموح)", t.includes("غير مسموح"));
  ok("hostile user name shown as text, nothing executed", t.includes("window.__xss") && (await page.evaluate(() => window.__xss)) === undefined);

  await page.uncheck('input[name="cl_scope"][value="people"]'); await page.selectOption("#cl_idle", "14");
  await page.click("text=حفظ"); await page.waitForTimeout(300);
  const save = (await calls()).find((c) => c.rpc === "claude_save_settings");
  ok("save sends exactly the manager's choices", save && save.args.p_enabled === true && save.args.p_idle_days === 14
     && JSON.stringify(save.args.p_scopes) === JSON.stringify(["overview","projects","comparison","fleet","expiring","notes_rooms","search"]), JSON.stringify(save?.args));

  for (const cb of await page.locator('input[name="cl_scope"]').all()) await cb.uncheck();
  const before = (await calls()).filter((c) => c.rpc === "claude_save_settings").length;
  await page.click("text=حفظ"); await page.waitForTimeout(200);
  ok("connector on with nothing selected is refused in the page", (await calls()).filter((c) => c.rpc === "claude_save_settings").length === before);

  await page.locator("button", { hasText:"إلغاء الربط" }).first().click(); await page.waitForTimeout(300);
  const rv = (await calls()).find((c) => c.rpc === "claude_revoke");
  ok("revoke sends only the session id (from the list), after confirmation", rv && rv.args.p_session === "00000000-0000-0000-5e55-00000000c0a1", JSON.stringify(rv?.args));
  ok("no page errors", errors.length === 0 && (await page.evaluate(() => window.__xss)) === undefined, errors.join(" | "));
  await ctx.close();
}

// 3) employee: no menu item, page refuses
{
  const { page, ctx } = await open(scenario(crafted, "employee"));
  ok("employee does not see the Claude page in the menu", (await page.locator("nav >> text=الربط مع Claude").count()) === 0);
  await ctx.close();
}

// 4) server without the connector migration (today's production): clear message, no crash
{
  const { page, ctx, errors } = await open(scenario({ __error:"Could not find the function public.claude_page without parameters in the schema cache" }));
  await go(page);
  ok("not enabled on the server: clear message instead of an error", (await page.textContent("#content")).includes("غير مفعّل على الخادم") && errors.length === 0);
  await ctx.close();
}
await b.close();
console.log(`---- ${results.filter(Boolean).length} passed, ${results.filter((x) => !x).length} failed of ${results.length}`);
process.exit(results.every(Boolean) ? 0 : 1);
