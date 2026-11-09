// UI test of oauth/consent.html (production project) with supabase-js stubbed (no network). Run: node tests/e2e/consent_page.mjs
import { chromium } from "playwright";
import { readFileSync } from "node:fs";
const html = readFileSync(new URL("../../oauth/consent.html", import.meta.url), "utf8");
const stub = `
let session = null; window.__calls = [];
export function createClient(){ return { auth: {
  async getSession(){ return { data: { session } }; },
  async signInWithPassword({email,password}){ window.__calls.push(['login',email]);
    if (password !== 'right') return { data:{session:null}, error:{message:'bad'} };
    session = { user:{ email } }; return { data:{ session }, error:null }; },
  async signOut(){ session = null; },
  oauth: {
    async getAuthorizationDetails(id){ window.__calls.push(['details',id]);
      return { data:{ authorization_id:id, client:{ name:'Claude <img src=x onerror="window.__xss=1">' }, scope:'openid' }, error:null }; },
    async approveAuthorization(id){ window.__calls.push(['approve',id]); return { data:{ redirect_url:'https://claude.ai/api/mcp/auth_callback?code=abc' }, error:null }; },
    async denyAuthorization(id){ window.__calls.push(['deny',id]); return { data:{ redirect_url:'https://claude.ai/api/mcp/auth_callback?error=access_denied' }, error:null }; },
  } } }; }`;
const results = []; const ok = (name, cond, detail = "") => results.push([cond ? "PASS" : "FAIL", name, detail]);
const browser = await chromium.launch({ executablePath: "/usr/bin/google-chrome", args: ["--no-sandbox"] });
async function page(q) {
  const p = await browser.newPage();
  await p.route("https://manage.example/**", (r) => r.fulfill({ contentType: "text/html", body: html }));
  await p.route("https://cdn.jsdelivr.net/**", (r) => r.fulfill({ contentType: "text/javascript", body: stub }));
  await p.route("https://fonts.googleapis.com/**", (r) => r.fulfill({ contentType: "text/css", body: "" }));
  await p.route("https://claude.ai/**", (r) => r.fulfill({ contentType: "text/html", body: "callback" }));
  await p.goto("https://manage.example/oauth/consent.html" + q);
  return p;
}
let p = await page("");
ok("no authorization_id -> clear error", (await p.textContent("#card")).includes("الرابط ناقص"));
p = await page("?authorization_id=auth-123");
await p.waitForSelector("input[type=email]");
ok("not signed in -> login form", true);
await p.fill("input[type=email]", "manager.a@trial.yaqen.test"); await p.fill("input[type=password]", "wrong"); await p.click("button.ok");
await p.waitForFunction(() => document.querySelector(".err")?.textContent.length > 0);
ok("wrong password -> error, stays on login", (await p.textContent(".err")).includes("غير صحيحة"));
await p.fill("input[type=password]", "right"); await p.click("button.ok");
await p.waitForSelector("button.no");
const text = await p.textContent("#card");
ok("consent shows read-only promise", text.includes("قراءة فقط"));
ok("consent shows the signed-in account", text.includes("manager.a@trial.yaqen.test"));
ok("client name rendered as text (no XSS)", (await p.evaluate(() => window.__xss)) === undefined && text.includes("<img"));
await Promise.all([p.waitForURL("https://claude.ai/**"), p.click("button.ok")]);
ok("approve -> redirected to the URL returned by Supabase", p.url().includes("code=abc"));
p = await page("?authorization_id=auth-456");
await p.fill("input[type=email]", "x@y.z"); await p.fill("input[type=password]", "right"); await p.click("button.ok");
await p.waitForSelector("button.no");
await Promise.all([p.waitForURL("https://claude.ai/**"), p.click("button.no")]);
ok("deny -> redirected with access_denied", p.url().includes("access_denied"));
await browser.close();
for (const r of results) console.log(r.join(" | "));
const f = results.filter((r) => r[0] === "FAIL").length;
console.log(`---- ${results.length - f} passed, ${f} failed of ${results.length}`);
process.exit(f ? 1 : 0);
