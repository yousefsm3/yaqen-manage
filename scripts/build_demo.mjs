// Builds dist/yaqen-demo.html: the real index.html with its Supabase client swapped for demo/demo-backend.js
// (in-browser, fictional data, no network). Run: node scripts/build_demo.mjs
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
let html = readFileSync(path.join(ROOT, "index.html"), "utf8");
const backend = readFileSync(path.join(ROOT, "demo/demo-backend.js"), "utf8");
const must = (cond, what) => { if (!cond) { console.error("build_demo: could not find " + what); process.exit(1); } };

const IMPORT = 'import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";';
must(html.includes(IMPORT), "supabase import");
html = html.replace(IMPORT, backend);

// no network at all in the demo
html = html.replace(/<meta http-equiv="Content-Security-Policy" content="[^"]*">/,
  `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src data: blob:; media-src blob:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">`);
html = html.replace(/<title>[^<]*<\/title>/, "<title>يقين للأعمال — نسخة عرض</title>");

// demo banner + account switcher (outside #app so the app can re-render freely)
const BANNER = `
<div id="demoBar" style="position:fixed;bottom:0;left:0;right:0;z-index:90;background:#3b2a05;color:#FCD34D;border-top:1px solid #92400E;padding:6px 12px;font-size:12px;display:flex;flex-wrap:wrap;gap:6px;align-items:center;justify-content:center">
  <b>نسخة عرض ببيانات وهمية</b><span>· لا تُحفظ أي بيانات · الذكاء الاصطناعي والواتساب غير مفعّلين ·</span>
  <span>ادخل كـ:</span>
  <button class="btn sm" onclick="__demoLogin('admin')">مدير الشركة</button>
  <button class="btn sm" onclick="__demoLogin('employee')">موظف الأسطول</button>
  <button class="btn sm" onclick="__demoLogin('owner')">مسؤول المنصة</button>
</div>`;
must(html.includes("</body>"), "</body>");
html = html.replace("</body>", BANNER + "\n</body>");

// expose the switcher from inside the module (sb is module-scoped)
const SB = "const sb = createClient(SUPABASE_URL, SUPABASE_KEY);";
must(html.includes(SB), "client creation");
html = html.replace(SB, SB + "\nwindow.__demoLogin = (k) => sb.__demo.login(k);\ndocument.body.style.paddingBottom = '46px';" +
  // hosted demo frames block confirm(); in the demo everything is reversible (trash, restore), so confirmations pass
  "\ntry { window.confirm = () => true; } catch {}");

mkdirSync(path.join(ROOT, "dist"), { recursive:true });
writeFileSync(path.join(ROOT, "dist/yaqen-demo.html"), html);
console.log("dist/yaqen-demo.html", (html.length / 1024).toFixed(0) + " KB");
