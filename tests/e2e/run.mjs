// UI tests for index.html in a real Chrome, with the Supabase client replaced by tests/e2e/supabase-stub.js.
// What this proves: the page's own behaviour (rendering, escaping, which server calls it makes).
// What it does NOT prove: anything about the real Supabase API, network latency or RLS (those are the DB tests).
// Run: node tests/e2e/run.mjs   (uses /usr/bin/google-chrome)
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const req = createRequire(import.meta.url);
let pw; try { pw = req("playwright"); } catch { pw = req("/opt/npm-tools/node_modules/playwright"); }  // CI: npm i playwright
const { chromium } = pw;
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const HTML = readFileSync(process.env.HTML_FILE || path.join(ROOT, "index.html"), "utf8");  // HTML_FILE=<old copy> reproduces the "before" state
const STUB = readFileSync(path.join(ROOT, "tests/e2e/supabase-stub.js"), "utf8");
const URL = "https://yousefsm3.github.io/yaqen-manage/";

// payload that fires if it is ever parsed as HTML or as JavaScript inside an inline handler
// (three shapes: HTML tag, JS string break-out, attribute break-out from a single-quoted handler)
const X = `<img src=x onerror="window.__pwned=(window.__pwned||0)+1">'");window.__pwned=1;//x' onpointerdown='window.__pwned=(window.__pwned||0)+1' a='`;
const CID = "00000000-0000-0000-0000-0000000000a0";
const ADMIN = "00000000-0000-0000-0000-0000000000a1";
const D_FIN = "00000000-0000-0000-0000-0000000000d1", D_FLT = "00000000-0000-0000-0000-0000000000d2";
const uuid = (n) => "00000000-0000-0000-0000-" + String(n).padStart(12, "0");

function baseScenario(over = {}) {
  const invoices = Array.from({ length:120 }, (_, i) => ({ id:uuid(5000 + i), company_id:CID, department_id:D_FIN, number:"INV-" + (i + 1) + (i === 0 ? X : ""),
    party:i === 1 ? X : "شركة", kind:"صادرة", amount:1000 + i, status:"غير مدفوعة", due_date:"2026-12-01", updated_at:"2026-11-01" }));
  return {
    user:ADMIN, email:"admin@qa.test",
    tables:{
      companies:[{ id:CID, name:"QA شركة", active:true, join_code:"QAJOINAAAAAA", admin_code:"QAADMINAAAAAAAAA", ai_monthly_budget_usd:30, ai_daily_user_limit:60 }],
      departments:[{ id:D_FIN, company_id:CID, name:"المالية", icon:"💰" }, { id:D_FLT, company_id:CID, name:X, icon:"🚚" }],
      profiles:[
        { id:ADMIN, company_id:CID, full_name:"مدير QA", email:"admin@qa.test", role:"admin", status:"active", department_id:null, created_at:"2026-01-01" },
        { id:uuid(0xa2), company_id:CID, full_name:X, email:"driver@qa.test", role:"employee", status:"active", department_id:D_FLT, created_at:"2026-01-02" },
        { id:uuid(0xa9), company_id:CID, full_name:"موظف جديد " + X, email:"new@qa.test", job_title:X, role:"employee", status:"pending", department_id:null, created_at:"2026-11-07" },
      ],
      rooms:[], room_members:[], projects:[],
      manager_notes:[{ id:uuid(0xe1), company_id:CID, department_id:D_FIN, subject:X, body:X, status:"مفتوحة", created_at:"2026-11-01" }],
      notifications:[{ id:1, user_id:ADMIN, company_id:CID, kind:"due", title:X, body:X, entity:"invoices", entity_id:uuid(5000), created_at:"2026-11-07", read_at:null }],
      invoices, vehicles:[], documents:[], legal_cases:[], requests:[],
      audit_log:[{ id:1, company_id:CID, at:"2026-11-07T10:00:00Z", actor:ADMIN, source:"web", action:"update", entity:"invoices", entity_id:uuid(5000), before:{ party:"a" }, after:{ party:X } }],
      wa_inbound:[{ id:uuid(0xf1), company_id:CID, profile_id:uuid(0xa2), from_phone:"966501234567", msg_type:"text", body:X, transcript:X, status:"matched", received_at:"2026-11-07" }],
    },
    rpc:{
      my_account:{ id:ADMIN, status:"active", role:"admin", company_id:CID, company_name:"QA", company_active:true, mfa_required:false, aal:"aal1" },
      dashboard_stats:{ notes_open:1, pending_members:1, people:3, vehicles:0, invoices:120 },
      company_alerts:[{ level:"high", kind:"invoice_due", entity:"invoices", entity_id:uuid(5000), department_id:D_FIN, label:X, due:"2026-11-01", days:-7, amount:1000 }],
      department_summary:[{ department_id:D_FIN, people:0, records:120 }],
      list_trash:[{ entity:"vehicles", id:uuid(0xb1), label:X, deleted_at:"2026-11-06", deleted_by:ADMIN }],
      ai_usage_summary:{ month_spent_usd:3.5, month_requests:42, budget_usd:30, daily_user_limit:60 },
      regenerate_company_codes:{ join_code:"NEWJOINCODE1" },
    },
    ai:{
      brief:{ brief:{ score:70, headline:X, kpis:[{ label:X, value:X }], risks:[{ title:X, detail:X, level:"عالي", department:X }],
        actions:[{ title:X, why:X, department:"المالية" }, { title:"t", why:"w", department:X }], insights:[X] } },
      chat:{ answer:X + "\n**" + X + "**\n- " + X },
      note_reply:{ text:X },
    },
    ...over,
  };
}

let browser, results = [];
const ok = (name, pass, detail = "") => { results.push({ name, pass:!!pass, detail }); console.log((pass ? "PASS" : "FAIL") + " | " + name + (detail ? " | " + detail : "")); };

async function open(scn) {
  const ctx = await browser.newContext({ locale:"ar-SA" });
  const page = await ctx.newPage();
  page.setDefaultTimeout(4000);
  const errors = [], csp = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (/Content Security Policy|Refused to/.test(m.text())) csp.push(m.text()); });
  page.on("dialog", (d) => d.accept());
  await page.addInitScript((s) => { window.__SCN = s; }, scn);
  await ctx.route("**/*", (route) => {
    const u = route.request().url();
    if (u.startsWith("https://cdn.jsdelivr.net/npm/@supabase/supabase-js")) return route.fulfill({ contentType:"application/javascript", body:STUB });
    if (u.startsWith(URL)) return route.fulfill({ contentType:"text/html; charset=utf-8", body:HTML });
    return route.abort();
  });
  await page.goto(URL);
  await page.waitForTimeout(400);
  return { page, ctx, errors, csp, calls:() => page.evaluate(() => window.__CALLS) };
}
const pwned = (page) => page.evaluate(() => ({ js:window.__pwned || 0, img:document.querySelectorAll('img[src="x"]').length }));
const go = async (page, v, p) => { await page.evaluate(([v, p]) => window.App.go(v, p), [v, p ?? null]); await page.waitForTimeout(250); };

// a crash inside a scenario (e.g. an element the old page does not have) is a FAIL, not an abort
async function block(fn) { try { await fn(); } catch (e) { ok("scenario crashed", false, String(e.message).split("\n")[0].slice(0, 140)); } }

browser = await chromium.launch({ executablePath:"/usr/bin/google-chrome", args:["--no-sandbox"] });

// ---------- H1: AI output and user data never execute ----------
await block(async () => {
  const { page, ctx, errors, csp } = await open(baseScenario());
  await page.click("#briefBtn"); await page.waitForTimeout(300);
  const noteBtn = page.locator("button", { hasText:"أرسلها ملاحظة" }).first();
  ok("H1 brief rendered with payloads (button for valid department present)", await noteBtn.count() === 1);
  await noteBtn.click(); await page.waitForTimeout(200);
  const p0 = await pwned(page);
  ok("H1 clicking 'send as note' with hostile AI text runs no script", p0.js === 0 && p0.img === 0, JSON.stringify(p0));
  ok("H1 'send as note' opens form with AI text as plain text", (await page.inputValue('input[name="subject"]')) === X);
  await page.evaluate(() => window.App.close());
  await go(page, "ai"); await page.click(".chip >> nth=0"); await page.waitForTimeout(300);
  for (const v of ["home", "notes", "people", "invoices", "departments", "audit", "trash", "whatsapp", "settings", "profile"]) await go(page, v);
  await page.evaluate(() => window.Gov.bell()); await page.waitForTimeout(150);
  await page.evaluate(() => window.App.close());
  await go(page, "people");
  await page.locator(".rec").first().click(); await page.waitForTimeout(150);
  await page.evaluate(() => window.App.close());
  await go(page, "invoices"); await page.locator(".rec").first().click(); await page.waitForTimeout(250);
  const p = await pwned(page);
  ok("H1 no injected script ran on any screen", p.js === 0 && p.img === 0, JSON.stringify(p));
  ok("H1 page has no JS errors across all screens", errors.length === 0, errors.slice(0, 3).join(" / "));
  ok("H1 no CSP violations from the app itself", csp.length === 0, csp.slice(0, 2).join(" / "));
  const inline = await page.evaluate(() => [...document.querySelectorAll("*")].flatMap((e) => [...e.attributes].filter((a) => a.name.startsWith("on")).map((a) => a.value)).filter((v) => v.includes("__pwned")).length);
  ok("H1 no event-handler attribute contains user/AI data", inline === 0, String(inline));
  await ctx.close();
});

// ---------- H2: server-side paging ----------
await block(async () => {
  const { page, ctx, calls } = await open(baseScenario());
  await go(page, "invoices"); await page.waitForTimeout(300);
  const cards = await page.locator(".rec").count();
  ok("H2 first page shows 50 of 120 invoices", cards === 50, String(cards));
  ok("H2 pager shows page 1 of 3 and the true total", await page.locator("text=صفحة 1 من 3").count() === 1);
  await page.click("text=التالي ←"); await page.waitForTimeout(300);
  const c = (await calls()).filter((x) => x.t === "invoices" && x.op === "select");
  ok("H2 next page requests rows 50..99 from the server", c.some((x) => x.range && x.range[0] === 50 && x.range[1] === 99), JSON.stringify(c.map((x) => x.range)));
  ok("H2 no request loads the whole invoices table", c.every((x) => x.range && x.range[1] - x.range[0] < 100));
  await page.fill("#searchBox", "INV-7"); await page.waitForTimeout(700);
  const s = (await calls()).filter((x) => x.t === "invoices" && x.filters.some((f) => f[0] === "or"));
  ok("H2 search runs on the server (ilike filter)", s.length > 0 && /number\.ilike\.\*INV-7\*/.test(s.at(-1).filters.find((f) => f[0] === "or")[1]));
  const all = await calls();
  ok("H2 dashboard numbers come from dashboard_stats/company_alerts RPCs", all.some((x) => x.rpc === "dashboard_stats") && all.some((x) => x.rpc === "company_alerts"));
  await ctx.close();
});

// ---------- C3: signup + approval ----------
await block(async () => {
  const scn = baseScenario({ user:null });
  const { page, ctx, calls } = await open(scn);
  await page.click("text=حساب جديد");
  ok("C3 signup form has no department picker", await page.locator('select[name="department_id"]').count() === 0);
  ok("M5 signup password requires 8+ characters", (await page.getAttribute('input[name="password"]', "minlength")) === "8");
  await page.fill('input[name="full_name"]', "تجربة"); await page.fill('input[name="email"]', "t@qa.test"); await page.fill('input[name="password"]', "short7!");
  await page.evaluate(() => { const f = document.querySelector('form[onsubmit*="signup"]'); f.querySelector('input[name="password"]').removeAttribute("minlength"); f.requestSubmit(); });
  await page.waitForTimeout(300);
  ok("M5 7-character password is rejected before reaching the server", !(await calls()).some((x) => x.auth === "signUp"));
  await ctx.close();
});
await block(async () => {
  const s = baseScenario(); s.rpc.my_account = { ...s.rpc.my_account, status:"pending", company_name:"QA" };
  const { page, ctx } = await open(s);
  ok("C3 pending account sees only the waiting screen", (await page.textContent("#app")).includes("بانتظار موافقة مدير الشركة") && await page.locator(".shell").count() === 0);
  await ctx.close();
});
await block(async () => {
  const s = baseScenario(); s.rpc.my_account = { ...s.rpc.my_account, status:"disabled" };
  const { page, ctx } = await open(s);
  ok("C3 disabled account is blocked", (await page.textContent("#app")).includes("حسابك موقوف"));
  await ctx.close();
});
await block(async () => {
  const { page, ctx, calls } = await open(baseScenario());
  await go(page, "people");
  ok("C3 admin sees the pending-approval list", await page.locator("text=طلبات انضمام بانتظار موافقتك (1)").count() === 1);
  await page.selectOption('form[onsubmit*="approve"] select[name="dept"]', D_FIN);
  await page.click('form[onsubmit*="approve"] button.pri'); await page.waitForTimeout(300);
  const a = (await calls()).find((x) => x.rpc === "approve_member");
  ok("C3 approve calls approve_member with the chosen department", a && a.args.dept === D_FIN && a.args.new_role === "employee", JSON.stringify(a?.args));
  await ctx.close();
});

// ---------- M4 / M6 / H3 / H6 / H7 / M5 ----------
await block(async () => {
  const { page, ctx, calls } = await open(baseScenario());
  await go(page, "settings"); await page.click("text=↻ رمز جديد"); await page.waitForTimeout(300);
  let c = await calls();
  ok("M4 new join code is generated by the server (regenerate_company_codes), not the browser", c.some((x) => x.rpc === "regenerate_company_codes" && x.args.which === "join") && !c.some((x) => x.t === "companies" && x.op === "update" && x.payload?.join_code));
  await page.waitForTimeout(300);
  const usage = await page.textContent("#aiUsage");
  ok("H4 settings shows AI usage against the monthly budget", usage.includes((42).toLocaleString("ar-SA")) && usage.includes("$3.50") && usage.includes("$30"), usage.trim().slice(0, 120));
  await go(page, "invoices"); await page.locator(".rec").first().click(); await page.waitForTimeout(250);
  await page.click("form#ef button.danger"); await page.waitForTimeout(300);
  c = await calls();
  ok("M6 deleting a record is a soft delete (rpc soft_delete), never DELETE", c.some((x) => x.rpc === "soft_delete" && x.args.tbl === "invoices") && !c.some((x) => x.t === "invoices" && x.op === "delete"));
  await go(page, "trash"); await page.waitForTimeout(250);
  await page.click("text=↺ استرجاع"); await page.waitForTimeout(300);
  ok("M6 trash restore calls restore_deleted", (await calls()).some((x) => x.rpc === "restore_deleted" && x.args.tbl === "vehicles"));
  await go(page, "audit"); await page.waitForTimeout(300);
  ok("H3 audit screen lists entries from audit_log (paged)", (await page.locator("#auditBox tr").count()) === 1 && (await calls()).some((x) => x.t === "audit_log" && x.range));
  await go(page, "whatsapp"); await page.waitForTimeout(250);
  await page.click("text=✓ تمت المعالجة"); await page.waitForTimeout(250);
  ok("H7 WhatsApp queue decision goes through review_wa_message", (await calls()).some((x) => x.rpc === "review_wa_message" && x.args.decision === "converted"));
  await go(page, "home");
  ok("H6 bell shows 1 unread notification", (await page.locator('button[title="التنبيهات"] .badge').textContent()) === "1");
  await page.evaluate(() => window.Gov.bell()); await page.click("text=تحديد الكل كمقروء"); await page.waitForTimeout(300);
  ok("H6 mark-all-read updates only read_at", (await calls()).some((x) => x.t === "notifications" && x.op === "update" && Object.keys(x.payload).join() === "read_at"));
  await go(page, "notes"); await page.waitForTimeout(150);
  const del = page.locator('button', { hasText:"حذف" }).first();
  if (await del.count()) { await del.click(); await page.waitForTimeout(250); }
  c = await calls();
  ok("M6 manager note delete is soft", c.some((x) => x.rpc === "soft_delete" && x.args.tbl === "manager_notes") && !c.some((x) => x.t === "manager_notes" && x.op === "delete"));
  await ctx.close();
});
await block(async () => {
  const s = baseScenario({ aal:{ currentLevel:"aal1", nextLevel:"aal2" }, factors:[{ id:"f1", status:"verified", factor_type:"totp" }] });
  const { page, ctx, calls } = await open(s);
  ok("M5 account with authenticator must enter a code before the app opens", (await page.textContent("#app")).includes("اكتب الرمز من تطبيق المصادقة") && await page.locator(".shell").count() === 0);
  await page.fill('input[name="code"]', "000000"); await page.click("text=دخول"); await page.waitForTimeout(250);
  ok("M5 wrong code is refused", (await page.textContent("#app")).includes("الرمز غير صحيح"));
  ok("M5 code verified through Supabase MFA", (await calls()).some((x) => x.mfa === "verify"));
  await ctx.close();
});
await block(async () => {
  const s = baseScenario(); s.rpc.my_account = { ...s.rpc.my_account, mfa_required:true, aal:"aal1" };
  const { page, ctx } = await open(s);
  ok("M5 admin of a company that requires MFA is told admin powers are paused", (await page.textContent("#app")).includes("تلزم المدراء بالتحقق الثنائي"));
  await ctx.close();
});

await browser.close();
const failed = results.filter((r) => !r.pass).length;
console.log(`---- ${results.length - failed} passed, ${failed} failed of ${results.length}`);
process.exit(failed ? 1 : 0);
