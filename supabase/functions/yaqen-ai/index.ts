import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const MODEL = Deno.env.get("AI_MODEL") ?? "claude-sonnet-5-5";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

async function claude(system: string, messages: unknown[], maxTokens = 1500) {
  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) throw new Error("NO_KEY");
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, max_tokens: maxTokens, system, messages }),
  });
  const d = await r.json();
  if (!r.ok) throw new Error(d?.error?.message ?? "AI error");
  return (d.content ?? []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("");
}

function parseJson(t: string) {
  const m = t.match(/\{[\s\S]*\}/);
  return m ? JSON.parse(m[0]) : {};
}

async function companySnapshot(sb: any, cid: string) {
  const q = async (table: string, cols: string, limit = 300) => {
    const { data } = await sb.from(table).select(cols).eq("company_id", cid).limit(limit);
    return data ?? [];
  };
  const { data: comp } = await sb.from("companies").select("name").eq("id", cid).single();
  const [deps, people, vehicles, projects, cases, invoices, docs, requests, notes] = await Promise.all([
    sb.from("departments").select("id,name").eq("company_id", cid).then((r: any) => r.data ?? []),
    q("profiles", "full_name,job_title,role,department_id"),
    q("vehicles", "plate,kind,model,driver_name,location,status,registration_expiry,insurance_expiry,license_expiry,notes,department_id"),
    q("projects", "name,client,po_number,contract_value,progress,status,start_date,end_date,notes,department_id"),
    q("legal_cases", "title,case_number,court,opponent,lawyer,status,next_hearing,last_update,department_id"),
    q("invoices", "number,party,kind,amount,due_date,status,department_id"),
    q("documents", "name,doc_type,expiry_date,notes,department_id"),
    q("requests", "title,details,priority,status,created_at,department_id"),
    q("manager_notes", "subject,body,status,reply,due_date,created_at,department_id"),
  ]);
  const depName: Record<string, string> = {};
  for (const d of deps as any[]) depName[d.id] = d.name;
  const tag = (rows: any[]) => rows.map((r) => { const { department_id, ...rest } = r; return { ...rest, القسم: depName[department_id] ?? "-" }; });
  return {
    الشركة: comp?.name,
    تاريخ_اليوم: new Date().toISOString().slice(0, 10),
    الأقسام: (deps as any[]).map((d) => d.name),
    الموظفين: tag(people as any[]),
    المركبات_والمعدات: tag(vehicles as any[]),
    المشاريع: tag(projects as any[]),
    القضايا: tag(cases as any[]),
    الفواتير: tag(invoices as any[]),
    الوثائق_والتراخيص: tag(docs as any[]),
    الطلبات: tag(requests as any[]),
    ملاحظات_المدير: tag(notes as any[]),
  };
}

const EXTRACT_FIELDS: Record<string, string> = {
  vehicles: "plate (رقم اللوحة), kind (نوع المركبة/المعدة), model (الموديل والسنة), driver_name, registration_expiry (YYYY-MM-DD), insurance_expiry (YYYY-MM-DD), license_expiry (YYYY-MM-DD), notes",
  invoices: "number, party (الجهة), kind (صادرة أو واردة), amount (رقم فقط), due_date (YYYY-MM-DD)",
  documents: "name, doc_type, expiry_date (YYYY-MM-DD), notes",
  legal_cases: "title, case_number, court, opponent, lawyer, next_hearing (YYYY-MM-DD), last_update (ملخص المستجدات)",
  projects: "name, client, po_number, contract_value (رقم), start_date, end_date, notes",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const auth = req.headers.get("Authorization") ?? "";
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: auth } },
    });
    const { data: { user } } = await sb.auth.getUser();
    if (!user) return json({ error: "غير مسجل" }, 401);
    const body = await req.json();
    const mode = body.mode;

    if (mode === "extract") {
      const sys = "أنت مساعد إدخال بيانات ذكي لشركة سعودية. اقرأ المستند المرفق بدقة (عربي/إنجليزي، والتواريخ الهجرية حوّلها لميلادية) وأعد JSON فقط بدون أي نص آخر، بالحقول التالية، واترك الحقل فارغاً إن لم يظهر: " + (EXTRACT_FIELDS[body.target] ?? EXTRACT_FIELDS.documents);
      const text = await claude(sys, [{ role: "user", content: [
        { type: "image", source: { type: "base64", media_type: body.media_type ?? "image/jpeg", data: body.image } },
        { type: "text", text: "استخرج البيانات." },
      ] }], 800);
      return json({ fields: parseJson(text) });
    }

    const { data: me } = await sb.from("profiles").select("full_name,role,company_id").eq("id", user.id).single();
    const cid = me?.role === "super_admin" ? body.company_id : me?.company_id;
    if (!cid) return json({ error: "اختر شركة أولاً" }, 400);
    const snap = await companySnapshot(sb, cid);
    const ctx = "بيانات الشركة الحالية (JSON):\n" + JSON.stringify(snap);

    if (mode === "brief") {
      const sys = `أنت مستشار تنفيذي ذكي لمدير شركة سعودية متوسطة الحجم تعمل في المقاولات وخدمات النفط مع أرامكو. حلل بيانات الشركة بعمق واكتشف المخاطر قبل وقوعها: وثائق وتأمينات واستمارات ورخص تنتهي خلال 30 يوماً أو انتهت، مشاريع متأخرة أو تقدمها لا يتناسب مع وقتها، فواتير متأخرة وأثرها على السيولة، جلسات قضايا قريبة، معدات متوقفة، طلبات عاجلة معلقة، ملاحظات مدير بلا رد. أعد JSON فقط بالشكل:
{"score": رقم من 0 إلى 100 لصحة الشركة, "headline": "جملة واحدة تلخص الوضع", "risks": [{"level":"عالي|متوسط|منخفض","title":"","detail":"","department":"اسم القسم كما هو في البيانات"}], "actions": [{"title":"إجراء محدد يتخذه المدير اليوم","department":"اسم القسم كما هو في البيانات","why":""}], "insights": ["ملاحظة ذكية غير واضحة من النظرة الأولى"], "kpis": [{"label":"","value":""}]}
اكتب بالعربية الواضحة، مختصراً ودقيقاً، واعتمد فقط على البيانات. إن كانت البيانات قليلة قل ذلك واقترح ما يجب إدخاله.`;
      const text = await claude(sys, [{ role: "user", content: ctx }], 2500);
      return json({ brief: parseJson(text) });
    }

    if (mode === "note_reply") {
      const sys = "أنت مساعد لموظف في شركة سعودية. اكتب مسودة رد مهني ومختصر بالعربية على ملاحظة المدير، معتمداً على بيانات الشركة إن كانت ذات صلة. أعد نص الرد فقط.";
      const text = await claude(sys, [{ role: "user", content: ctx + "\n\nملاحظة المدير: " + body.note }], 600);
      return json({ text });
    }

    const history = (body.history ?? []).slice(-10).map((m: any) => ({ role: m.role === "assistant" ? "assistant" : "user", content: String(m.content) }));
    const roleName = me?.role === "employee" ? "موظف" : "المدير";
    const sys = `أنت "مساعد يقين"، مساعد ذكاء اصطناعي داخل منصة إدارة شركة "${snap.الشركة}". تتحدث مع ${me?.full_name || "مستخدم"} (${roleName}). أجب بالعربية السعودية الواضحة، مختصراً ومباشراً، معتمداً فقط على البيانات التالية، واحسب الأرقام بدقة. إن لم تكن المعلومة موجودة قل ذلك بوضوح. عند الحاجة اقترح قراراً أو إجراءً عملياً. يمكنك استخدام قوائم قصيرة.\n\n${ctx}`;
    const text = await claude(sys, [...history, { role: "user", content: String(body.question ?? "") }], 1500);
    return json({ answer: text });
  } catch (e) {
    const msg = (e as Error).message;
    if (msg === "NO_KEY") return json({ error: "NO_KEY" }, 503);
    return json({ error: msg }, 500);
  }
});
