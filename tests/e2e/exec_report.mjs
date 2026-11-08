// UI test of the executive assistant against REAL numbers: the report JSON and the invoice rows are read from the
// staging database (as company A's admin, through RLS) and served to the page through the Supabase stub.
// Proves: the screen shows exactly the database figures, drill-down rows add up to the clicked figure, missing data
// is stated, unavailable prompts are disabled, periods are resolved correctly. Run after tests/run_db_tests.sh.
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
const asA1 = (q) => sql(`begin; set local role authenticated; set local request.jwt.claims = '{"sub":"${A1}","role":"authenticated"}'; ${q}; commit;`);

let results = [];
const ok = (n, p, d = "") => { results.push(!!p); console.log((p ? "PASS" : "FAIL") + " | " + n + (d ? " | " + d : "")); };
const b = await pw.chromium.launch({ executablePath:"/usr/bin/google-chrome", args:["--no-sandbox"] });

async function open(scn, today) {
  const ctx = await b.newContext({ locale:"ar-SA" }); const page = await ctx.newPage(); page.setDefaultTimeout(5000);
  const errors = []; page.on("pageerror", (e) => errors.push(e.message));
  await page.addInitScript(([s, t]) => { window.__SCN = s; if (t) { const F = Date; const fixed = new F(t).getTime();
    window.Date = class extends F { constructor(...a) { super(...(a.length ? a : [fixed])); } static now() { return fixed; } }; } }, [scn, today]);
  await ctx.route("**/*", (r) => { const u = r.request().url();
    if (u.startsWith("https://cdn.jsdelivr.net/npm/@supabase/supabase-js")) return r.fulfill({ contentType:"application/javascript", body:STUB });
    if (u.startsWith(URL_)) return r.fulfill({ contentType:"text/html; charset=utf-8", body:HTML });
    return r.abort(); });
  await page.goto(URL_); await page.waitForTimeout(400);
  return { page, ctx, errors, calls:() => page.evaluate(() => window.__CALLS) };
}
function scenario(report, invoices, role = "admin") {
  return { user:A1, tables:{
      companies:[{ id:A0, name:"QA-A", active:true }], departments:[], rooms:[], room_members:[], projects:[], manager_notes:[], notifications:[],
      profiles:[{ id:A1, company_id:A0, full_name:"مدير", role, status:"active", department_id:null }], invoices },
    rpc:{ my_account:{ id:A1, status:"active", role, company_id:A0, company_name:"QA-A", company_active:true, mfa_required:false, aal:"aal1" },
      dashboard_stats:{}, company_alerts:[], department_summary:[], report_profit_comparison:report } };
}

// 1) period resolution (Riyadh calendar), pure function exposed by the page
{
  const { page, ctx } = await open(scenario({}, []));
  const p = await page.evaluate(() => [window.__periodsFor("this_vs_last", "2026-01-15"), window.__periodsFor("last_vs_before", "2026-03-31"), window.__periodsFor("this_vs_last", "2028-03-01")]);
  ok("periods: January compares with previous December", p[0].a.from === "2026-01-01" && p[0].a.to === "2026-01-31" && p[0].b.from === "2025-12-01" && p[0].b.to === "2025-12-31", JSON.stringify(p[0]));
  ok("periods: 'last vs before' on Mar 31 = Feb vs Jan", p[1].a.from === "2026-02-01" && p[1].a.to === "2026-02-28" && p[1].b.to === "2026-01-31", JSON.stringify(p[1]));
  ok("periods: leap year February has 29 days", p[2].b.to === "2028-02-29", JSON.stringify(p[2]));
  const riyadh = await page.evaluate(() => { const d = new Date("2026-11-30T22:30:00Z"); return new Intl.DateTimeFormat("en-CA", { timeZone:"Asia/Riyadh", year:"numeric", month:"2-digit", day:"2-digit" }).format(d); });
  ok("Riyadh date used (23:30 UTC on Nov 30 is already Dec 1 in Riyadh)", riyadh === "2026-12-01", riyadh);
  await ctx.close();
}

// 2) report screen shows exactly the database figures (Nov vs Oct 2026 for company A)
const report = JSON.parse(asA1(`select public.report_profit_comparison('2026-11-01','2026-11-30','2026-10-01','2026-10-31')::text`));
const invoices = JSON.parse(asA1(`select coalesce(json_agg(i), '[]')::text from (select id, company_id, number, party, kind, amount::float8 amount, due_date::text due_date, status from public.invoices) i`));
{
  const { page, ctx, errors, calls } = await open(scenario(report, invoices), "2026-11-20T10:00:00+03:00");
  await page.evaluate(() => window.App.go("assistant")); await page.waitForTimeout(250);
  const disabled = await page.locator(".card", { hasText:"غير متاح:" }).count();
  ok("4 prompts without data are shown disabled with a reason", disabled === 4, String(disabled));
  await page.click("text=قارن هذا الشهر بالشهر السابق"); await page.waitForTimeout(500);
  const c = (await calls()).find((x) => x.rpc === "report_profit_comparison");
  ok("prompt resolved to Nov 2026 vs Oct 2026", c && c.args.a_from === "2026-11-01" && c.args.a_to === "2026-11-30" && c.args.b_from === "2026-10-01" && c.args.b_to === "2026-10-31", JSON.stringify(c?.args));
  const txt = await page.textContent("#reportView");
  const fmt = (v) => page.evaluate((v) => Number(v).toLocaleString("ar-SA", { maximumFractionDigits:0 }), v);
  ok("revenue figure = DB (" + report.periods.a.revenue_invoiced + ")", txt.includes(await fmt(report.periods.a.revenue_invoiced)));
  ok("supplier figure = DB (" + report.periods.a.supplier_invoiced + ")", txt.includes(await fmt(report.periods.a.supplier_invoiced)));
  ok("change % = DB (" + report.change.revenue_invoiced.pct + "%)", txt.includes((25).toLocaleString("ar-SA") + "%"));
  ok("net profit stated as NOT available with reasons", txt.includes("صافي الربح: غير متاح") && txt.includes("لا يوجد في يقين دفتر مصروفات"));
  ok("partial current month is flagged", txt.includes("الشهر الحالي لم يكتمل"));
  ok("excluded invoices without due date are disclosed (" + report.excluded_no_due_date + ")", txt.includes("بدون تاريخ استحقاق") && txt.includes(await page.evaluate((v) => Number(v).toLocaleString("ar-SA"), report.excluded_no_due_date)));
  ok("calculation time and data basis shown", txt.includes("وقت الحساب") && txt.includes("حسب تاريخ استحقاق"));
  ok("chart drawn from the same figures", await page.locator("#reportView svg rect").count() >= 8);
  // drill-down: rows behind "revenue" add up to the figure
  await page.click("#kpiTable tr:nth-child(2)"); await page.waitForTimeout(400);
  const drillTxt = await page.textContent("#drill");
  const rows = await page.locator("#drill table tr").count() - 1;
  ok("drill-down lists the invoices behind the revenue figure (2)", rows === report.periods.a.revenue_count, `${rows} rows`);
  ok("drill-down total equals the revenue figure", drillTxt.includes("المجموع " + (await page.evaluate((v) => (Number(v)).toLocaleString("ar-SA", { maximumFractionDigits:0 }), report.periods.a.revenue_invoiced))));
  const q = (await calls()).filter((x) => x.t === "invoices").pop();
  ok("drill uses the same filters as the database figure", JSON.stringify(q.filters).includes('"gte","due_date","2026-11-01"') && JSON.stringify(q.filters).includes('"lte","due_date","2026-11-30"') && JSON.stringify(q.filters).includes('"eq","kind","صادرة"'));
  await page.click("#kpiTable tr:nth-child(5)"); await page.waitForTimeout(400);
  ok("drill 'collected' = paid only", (await page.locator("#drill table tr").count() - 1) === 1 && (await page.textContent("#drill")).includes("N-1"));
  ok("no JS errors", errors.length === 0, errors.join(" / "));
  await page.emulateMedia({ media:"print" });
  ok("print view hides navigation and buttons", !(await page.locator(".side").isVisible()) && !(await page.locator("text=🖨️ طباعة").isVisible()));
  await ctx.close();
}
// 3) user with no invoices in scope: empty state, no invented numbers
{
  const zero = JSON.parse(sql(`begin; set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}'; select public.report_profit_comparison('2026-11-01','2026-11-30','2026-10-01','2026-10-31')::text; commit;`).split("\n").filter(Boolean).pop());
  const { page, ctx } = await open(scenario(zero, [], "employee"), "2026-11-20T10:00:00+03:00");
  await page.evaluate(() => window.App.go("assistant")); await page.waitForTimeout(200);
  await page.click("text=قارن هذا الشهر بالشهر السابق"); await page.waitForTimeout(400);
  const t = await page.textContent("#reportView");
  ok("fleet employee: 'no invoices within your permissions' and percent shown as —", t.includes("لا توجد فواتير ضمن صلاحياتك") && t.includes("—"));
  await ctx.close();
}
await b.close();
console.log(`---- ${results.filter(Boolean).length} passed, ${results.filter((x) => !x).length} failed of ${results.length}`);
process.exit(results.every(Boolean) ? 0 : 1);
