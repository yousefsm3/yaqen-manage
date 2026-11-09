// Yaqen DEMO backend: runs entirely in the browser. Replaces @supabase/supabase-js in the demo build only
// (scripts/build_demo.mjs). No network, no real accounts, no real AI. All data is fictional and regenerated on
// every load; nothing is saved. Server rules (RLS, approvals, soft delete) are imitated in a simplified way so the
// screens behave like the real platform; the real rules live in the database and are tested in tests/db.
const DEMO = (() => {
  // ---------- deterministic fake data ----------
  let seed = 7;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const n = (a, b) => a + Math.floor(rnd() * (b - a + 1));
  let idc = 1;
  const uid = () => "d0000000-0000-4000-8000-" + String(idc++).padStart(12, "0");
  const day = (off) => { const d = new Date(); d.setDate(d.getDate() + off); return d.toISOString().slice(0, 10); };
  const ts = (offDays) => new Date(Date.now() + offDays * 864e5).toISOString();

  const CID = uid(), CID2 = uid(), CID3 = uid();
  const companies = [
    { id:CID, name:"شركة الساحل للمقاولات (بيانات وهمية)", active:true, join_code:"DEMOJOIN2026", admin_code:"DEMOADMIN0000001", ai_monthly_budget_usd:30, ai_daily_user_limit:60, require_admin_mfa:false, created_at:ts(-120), notes:"شركة تجريبية للعرض" },
    { id:CID2, name:"مؤسسة الواحة للخدمات (وهمية)", active:true, join_code:"DEMOJOIN0002", admin_code:"DEMOADMIN0000002", ai_monthly_budget_usd:30, ai_daily_user_limit:60, created_at:ts(-60) },
    { id:CID3, name:"شركة النخبة الصناعية (وهمية)", active:false, join_code:"DEMOJOIN0003", admin_code:"DEMOADMIN0000003", ai_monthly_budget_usd:30, ai_daily_user_limit:60, created_at:ts(-30) },
  ];
  const depDefs = [["المالية","💰"],["الأسطول والمعدات","🚚"],["المشاريع","🏗️"],["القانونية","⚖️"],["السلامة والامتثال","🦺"],["الموارد البشرية","👥"],["المشتريات","📦"]];
  const departments = depDefs.map(([name, icon], i) => ({ id:uid(), company_id:CID, name, icon, created_at:ts(-120 + i) }));
  const dep = (name) => departments.find((d) => d.name === name).id;
  const first = ["محمد","عبدالله","فهد","خالد","سعد","ناصر","تركي","سلطان","عمر","يوسف","فيصل","ماجد","راشد","بندر","نواف","سارة","نورة","ريم","هند","لمى"];
  const last = ["العتيبي","القحطاني","الدوسري","الشهري","الغامدي","الزهراني","المطيري","الحربي","العنزي","الشمري"];
  const drivers = ["Muhammad Asif","Imran Khan","Bilal Ahmed","Rashid Ali","Sajid Hussain","Tariq Mehmood","Arif Rahman","Joseph Cruz","Ramesh Kumar","Abdul Karim"];
  const ADMIN = uid(), EMP = uid(), OWNER = uid();
  const profiles = [
    { id:OWNER, company_id:null, full_name:"مسؤول منصة يقين (عرض)", email:"owner@demo.yaqen", role:"super_admin", status:"active", created_at:ts(-200) },
    { id:ADMIN, company_id:CID, full_name:"أحمد السالم (مدير الشركة)", email:"admin@demo.yaqen", role:"admin", status:"active", job_title:"المدير العام", phone:"0500000001", department_id:null, created_at:ts(-120) },
    { id:EMP, company_id:CID, full_name:"خالد المطيري (موظف الأسطول)", email:"fleet@demo.yaqen", role:"employee", status:"active", job_title:"مشرف أسطول", phone:"0500000002", department_id:dep("الأسطول والمعدات"), created_at:ts(-110) },
  ];
  for (let i = 0; i < 42; i++) {
    const d = departments[i % departments.length];
    profiles.push({ id:uid(), company_id:CID, full_name:pick(first) + " " + pick(last), email:`emp${i + 1}@demo.yaqen`, role:"employee", status:"active",
      job_title:pick(["فني","مهندس","محاسب","أخصائي","مشرف","منسق"]) + " " + d.name, phone:"05" + n(10000000, 99999999), department_id:d.id, created_at:ts(-100 + i) });
  }
  profiles.push({ id:uid(), company_id:CID, full_name:"سامي الحربي", email:"new1@demo.yaqen", role:"employee", status:"pending", job_title:"سائق معدات ثقيلة", department_id:null, created_at:ts(-1) });
  profiles.push({ id:uid(), company_id:CID, full_name:"Bilal Ahmed", email:"new2@demo.yaqen", role:"employee", status:"pending", job_title:"Driver", department_id:null, created_at:ts(0) });
  for (let i = 0; i < 6; i++) profiles.push({ id:uid(), company_id:i < 4 ? CID2 : CID3, full_name:pick(first) + " " + pick(last), role:i % 4 === 0 ? "admin" : "employee", status:"active", created_at:ts(-50) });

  const sites = ["موقع العميل - أبقيق","موقع العميل - رأس تنورة","الجبيل الصناعية","ورشة الدمام","موقع العميل - الحوية","المستودع الرئيسي - الخبر"];
  const vehicles = Array.from({ length:64 }, (_, i) => {
    const st = i % 11 === 0 ? "متوقفة" : i % 7 === 0 ? "صيانة" : "شغالة";
    return { id:uid(), company_id:CID, department_id:dep("الأسطول والمعدات"), plate:`${pick(["أ ب ج","د ر س","ط ع ق","ك ل م","ن هـ و"])} ${n(1000, 9999)}`,
      kind:pick(["ونيت","رافعة","شيول","باص عمال","تريلا","وايت ماء","بوكلين"]), model:pick(["تويوتا هايلكس","كاتربلر 950","هينو 500","مرسيدس أكتروس","إيسوزو NPR"]) + " " + n(2016, 2025),
      driver_name:pick(drivers), driver_phone:"05" + n(10000000, 99999999), location:pick(sites), status:st,
      registration_expiry:day(n(-10, 330)), insurance_expiry:day(i % 9 === 0 ? n(-5, 25) : n(40, 360)), license_expiry:day(n(20, 500)),
      notes:st === "متوقفة" ? "بانتظار قطع غيار" : null, updated_at:ts(-n(0, 60)), created_by:EMP };
  });
  const clients = ["عميل رئيسي أ (وهمي)","عميل صناعي ب (وهمي)","شركة التعدين ج (وهمية)","شركة الطاقة د (وهمية)","مقاول رئيسي هـ (وهمي)"];
  const invoices = Array.from({ length:148 }, (_, i) => {
    const out = i % 3 !== 0, dd = i < 90 ? n(-330, -20) : n(-75, 60), paid = dd < -60 ? rnd() < 0.98 : dd < -20 ? rnd() < 0.88 : dd < 0 ? rnd() < 0.6 : rnd() < 0.2;
    return { id:uid(), company_id:CID, department_id:dep("المالية"), number:(out ? "INV-2026-" : "SUP-") + String(1000 + i), kind:out ? "صادرة" : "واردة",
      party:out ? pick(clients) : pick(["مؤسسة قطع الغيار الحديثة","شركة الوقود المتحدة","مصنع الحديد الوطني","شركة التأمين التعاوني"]),
      amount:n(8, 480) * 1000, due_date:day(dd), status:paid ? "مدفوعة" : dd < 0 ? "متأخرة" : "غير مدفوعة", updated_at:ts(-n(0, 90)), created_by:ADMIN };
  });
  const projects = ["صيانة خطوط الأنابيب - أبقيق","توريد وتشغيل معدات - الجافورة","أعمال مدنية - رأس تنورة","نقل عمالة - الجبيل","تأهيل مستودعات - الدمام","فحص وصيانة صهاريج","تمديد شبكة مياه - الحوية","أعمال سفلتة طرق داخلية","تركيب هياكل حديدية","عقد تشغيل وصيانة سنوي","تأجير معدات ثقيلة","مشروع إسكان عمال"]
    .map((name, i) => { const late = i % 4 === 1; return { id:uid(), company_id:CID, department_id:dep("المشاريع"), name, client:pick(clients), po_number:"PO-" + n(450000, 459999),
      contract_value:n(4, 90) * 100000, progress:i === 9 ? 100 : n(10, 92), status:i === 9 ? "مكتمل" : late ? "متأخر" : i % 6 === 0 ? "معلق" : "جاري",
      start_date:day(-n(60, 300)), end_date:day(late ? -n(3, 40) : n(15, 240)), updated_at:ts(-n(0, 30)), created_by:ADMIN }; });
  const legal_cases = [["مطالبة مالية مع مقاول باطن","المحكمة التجارية بالدمام"],["نزاع عمالي - مستحقات نهاية خدمة","المحكمة العمالية بالخبر"],["مخالفة مرورية لمعدة ثقيلة","الإدارة العامة للمرور"],["تحصيل مستحقات فاتورة متأخرة","المحكمة التجارية بالرياض"],["نزاع عقد إيجار مستودع","المحكمة العامة بالدمام"],["اعتراض على غرامة بلدية","أمانة المنطقة الشرقية"],["مطالبة تأمين حادث معدة","هيئة التأمين"],["قضية منتهية - تسوية ودية","المحكمة التجارية بالدمام"]]
    .map(([title, court], i) => ({ id:uid(), company_id:CID, department_id:dep("القانونية"), title, court, case_number:String(4470000 + n(1000, 9999)), opponent:"طرف وهمي " + (i + 1),
      lawyer:pick(["مكتب المحاماة أ (وهمي)","مكتب المحاماة ب (وهمي)"]), status:i === 7 ? "مغلقة" : pick(["مفتوحة","قيد النظر","مؤجلة"]), next_hearing:i === 7 ? null : day(n(2, 45)),
      last_update:"تم تقديم المذكرة وبانتظار تحديد الجلسة.", updated_at:ts(-n(0, 20)), created_by:ADMIN }));
  const documents = [["السجل التجاري","سجل"],["شهادة تأهيل لدى العميل الرئيسي","تأهيل"],["شهادة الزكاة والدخل","زكاة"],["شهادة التأمينات الاجتماعية","تأمينات"],["رخصة البلدية","رخصة"],["شهادة الأيزو 9001","جودة"],["شهادة السلامة OSHA","سلامة"],["رخصة الدفاع المدني","سلامة"],["شهادة السعودة (نطاقات)","موارد بشرية"],["شهادة الغرفة التجارية","عضوية"],["عقد إيجار المستودع","عقد"],["شهادة الامتثال السيبراني","أمن سيبراني"]]
    .map(([name, doc_type], i) => ({ id:uid(), company_id:CID, department_id:dep("السلامة والامتثال"), name, doc_type, expiry_date:day(i % 4 === 0 ? n(-8, 25) : n(40, 400)), updated_at:ts(-n(0, 60)), created_by:ADMIN }));
  const requests = ["طلب صيانة رافعة 25 طن","طلب سلفة لموظف","اعتماد شراء إطارات","طلب إجازة","طلب تجديد إقامة","طلب تصريح دخول موقع العميل","طلب شراء معدات سلامة","طلب نقل سائق لموقع آخر","طلب تعميد مورد جديد","طلب ساعات عمل إضافية"]
    .map((title, i) => ({ id:uid(), company_id:CID, department_id:departments[(i + 1) % 7].id, title, details:"تفاصيل الطلب (بيانات وهمية للعرض).", priority:i % 3 === 0 ? "عاجل" : "عادي",
      status:pick(["جديد","قيد التنفيذ","معتمد","منجز"]), updated_at:ts(-n(0, 14)), created_by:EMP }));
  const manager_notes = [
    { subject:"تجديد تأمين المعدات", body:"راجعوا التأمينات اللي تنتهي هذا الشهر وجددوها قبل نهاية الأسبوع.", department_id:dep("الأسطول والمعدات"), status:"مفتوحة", due_date:day(4) },
    { subject:"تحصيل المتأخرات", body:"أبي كشف بالفواتير المتأخرة أكثر من 30 يوم مع خطة تحصيل.", department_id:dep("المالية"), status:"مفتوحة", due_date:day(2) },
    { subject:"تقرير تقدم مشروع أبقيق", body:"ارفعوا نسبة الإنجاز الفعلية وأسباب التأخير.", department_id:dep("المشاريع"), status:"تم الرد", reply:"تم التحديث، التأخير بسبب تصاريح الدخول.", due_date:day(-1) },
  ].map((x) => ({ id:uid(), company_id:CID, created_at:ts(-n(1, 6)), created_by:ADMIN, ...x }));
  const R1 = uid(), R2 = uid();
  const rooms = [
    { id:R1, company_id:CID, title:"غرفة متابعة موقع أبقيق", description:"تنسيق يومي بين الأسطول والمشاريع", status:"مفتوحة", created_by:ADMIN, created_at:ts(-5), last_message_at:ts(-0.1) },
    { id:R2, company_id:CID, title:"تعطل الرافعة 25 طن", description:"متابعة الصيانة", status:"مفتوحة", created_by:EMP, created_at:ts(-2), last_message_at:ts(-0.5) },
  ];
  const room_members = [R1, R2].flatMap((r) => [ADMIN, EMP, profiles[5].id].map((u) => ({ room_id:r, user_id:u, added_at:ts(-5) })));
  const room_messages = [
    { room_id:R1, user_id:ADMIN, kind:"text", body:"صباح الخير، وش وضع المعدات في الموقع اليوم؟", created_at:ts(-0.4) },
    { room_id:R1, user_id:EMP, kind:"text", body:"جميع المعدات شغالة ما عدا الشيول رقم 3 بالصيانة.", created_at:ts(-0.35) },
    { room_id:R1, user_id:profiles[5].id, kind:"text", body:"gaari ka tire kharab hai, kal tak theek ho jayega", created_at:ts(-0.3),
      translation:{ lang:"ur", lang_name_ar:"الأوردو", ar:"إطار السيارة خربان، وبيتصلّح بكرة.", en:"The vehicle's tire is damaged; it will be fixed by tomorrow.", ur:"گاڑی کا ٹائر خراب ہے، کل تک ٹھیک ہو جائے گا" } },
    { room_id:R2, user_id:EMP, kind:"text", body:"تم طلب قطعة الغيار من المورد، التوريد خلال 3 أيام.", created_at:ts(-0.5) },
  ].map((m) => ({ id:uid(), ...m }));
  const notifications = [];
  const audit_log = [];
  const wa_inbound = [
    { id:uid(), company_id:CID, profile_id:profiles[5].id, from_phone:"9665" + n(10000000, 99999999), msg_type:"text", body:"Crane no. 2 hydraulic leak, site Abqaiq", status:"needs_review", received_at:ts(-0.2) },
    { id:uid(), company_id:CID, profile_id:null, from_phone:"9665" + n(10000000, 99999999), msg_type:"audio", body:null, transcript:null, status:"unmatched", received_at:ts(-0.1) },
  ];
  const system_events = [{ id:1, at:ts(-0.2), level:"info", source:"demo", message:"نسخة عرض: لا توجد أحداث حقيقية" }];
  const DB = { companies, departments, profiles, vehicles, invoices, projects, legal_cases, documents, requests, manager_notes, rooms, room_members, room_messages, notifications, audit_log, wa_inbound, system_events, ai_usage:[] };
  // one soft-deleted record so the trash screen has something to show
  vehicles[63].deleted_at = ts(-1); vehicles[63].deleted_by = ADMIN;

  return { DB, CID, ACCOUNTS:{ admin:ADMIN, employee:EMP, owner:OWNER }, day, uid, ts };
})();

function createClient() {
  const { DB, CID, ACCOUNTS, day, uid } = DEMO;
  const SOFT = ["vehicles","projects","legal_cases","invoices","documents","requests","manager_notes"];
  const DEPT_SCOPED = [...SOFT, "profiles"];
  let session = null, listeners = [], aid = 1;
  const me = () => DB.profiles.find((p) => p.id === session?.user.id);
  const isSuper = () => me()?.role === "super_admin";
  const isAdmin = () => me()?.role === "admin" && me()?.status === "active";
  const myCo = () => me()?.status === "active" ? me()?.company_id : null;
  const today = new Date().toISOString().slice(0, 10);
  const dd = (d) => d ? Math.round((new Date(d) - new Date(today)) / 864e5) : null;
  const emit = (ev) => listeners.forEach((cb) => setTimeout(() => cb(ev, session), 0));
  const audit = (action, entity, row, before) => DB.audit_log.unshift({ id:aid++, at:new Date().toISOString(), company_id:row?.company_id ?? myCo(), actor:session?.user.id, source:"web", action, entity, entity_id:row?.id, before:before ?? null, after:action === "soft_delete" ? null : row });

  // simplified stand-in for the database's row-level security
  function visible(t, r) {
    const p = me(); if (!p) return t === "companies" ? false : false;
    if (isSuper()) return true;
    const co = myCo(); if (!co) return t === "profiles" && r.id === p.id;
    if (t === "companies") return r.id === co;
    if ("company_id" in r && r.company_id !== co && t !== "room_members" && t !== "notifications") return false;
    if (SOFT.includes(t) && r.deleted_at) return false;
    if (t === "notifications") return r.user_id === p.id;
    if (["audit_log","wa_inbound","system_events","ai_usage"].includes(t)) return isAdmin() && t !== "system_events";
    if (t === "rooms") return isAdmin() || DB.room_members.some((m) => m.room_id === r.id && m.user_id === p.id);
    if (t === "room_members" || t === "room_messages") return isAdmin() || DB.room_members.some((m) => m.room_id === r.room_id && m.user_id === p.id);
    if (DEPT_SCOPED.includes(t) && !isAdmin()) return t === "profiles" ? (r.id === p.id || (r.department_id === p.department_id && r.status === "active")) : r.department_id === p.department_id;
    return true;
  }
  const rows = (t) => (DB[t] = DB[t] || []).filter((r) => visible(t, r));

  class Query {
    constructor(t) { this.t = t; this.op = "select"; this.f = []; this.rng = null; this.lim = null; this.one = false; this.cnt = false; this.desc = null; }
    select(c, o) { if (o?.count) this.cnt = true; return this; }
    insert(p) { this.op = "insert"; this.p = p; return this; }
    update(p) { this.op = "update"; this.p = p; return this; }
    upsert(p) { this.op = "insert"; this.p = p; return this; }
    delete() { this.op = "delete"; return this; }
    eq(k, v) { this.f.push((r) => r[k] === v); return this; }
    neq(k, v) { this.f.push((r) => r[k] !== v); return this; }
    in(k, v) { this.f.push((r) => v.includes(r[k])); return this; }
    gte(k, v) { this.f.push((r) => r[k] != null && r[k] >= v); return this; }
    lte(k, v) { this.f.push((r) => r[k] != null && r[k] <= v); return this; }
    is(k, v) { this.f.push((r) => (r[k] ?? null) === v); return this; }
    or(expr) { const parts = expr.split(","); this.f.push((r) => parts.some((pt) => { const [c, , pat] = pt.split("."); return String(r[c] ?? "").toLowerCase().includes(pat.replace(/^\*|\*$/g, "").toLowerCase()); })); return this; }
    order(k, o) { if (!this.desc) this.desc = [k, o?.ascending === false]; return this; }
    range(a, b) { this.rng = [a, b]; return this; }
    limit(x) { this.lim = x; return this; }
    single() { this.one = true; return this; }
    maybeSingle() { this.one = true; return this; }
    run() {
      const t = this.t, all = (DB[t] = DB[t] || []);
      if (this.op === "insert") {
        const list = (Array.isArray(this.p) ? this.p : [this.p]).map((r) => ({ id:uid(), created_at:new Date().toISOString(), updated_at:new Date().toISOString(),
          ...(t !== "room_members" && t !== "notifications" && t !== "companies" ? { company_id:myCo() ?? r.company_id } : {}), created_by:session?.user.id, user_id:t === "room_messages" ? session?.user.id : r.user_id, ...r }));
        if (t === "companies" && !isSuper()) return { data:null, error:{ message:"غير مصرح (عرض)" } };
        all.push(...list); list.forEach((r) => audit("insert", t, r));
        if (t === "room_messages") { const room = DB.rooms.find((x) => x.id === list[0].room_id); if (room) room.last_message_at = list[0].created_at; }
        return { data:this.one ? list[0] : list, error:null };
      }
      let hit = rows(t).filter((r) => this.f.every((fn) => fn(r)));
      if (this.op === "update") {
        if (t === "profiles" && !isAdmin() && !isSuper()) hit = hit.filter((r) => r.id === session?.user.id);
        hit.forEach((r) => { const before = { ...r }; Object.assign(r, this.p, SOFT.includes(t) ? { updated_at:new Date().toISOString() } : {}); audit("update", t, r, before); });
        return { data:this.one ? hit[0] ?? null : hit, error:null };
      }
      if (this.op === "delete") {
        if (SOFT.includes(t)) return { data:null, error:{ message:"permission denied (الحذف النهائي ممنوع)" } };
        DB[t] = all.filter((r) => !hit.includes(r)); hit.forEach((r) => audit("delete", t, null, r));
        return { data:null, error:null };
      }
      if (this.desc) { const [k, d] = this.desc; hit = [...hit].sort((a, b) => (String(a[k] ?? "") < String(b[k] ?? "") ? -1 : 1) * (d ? -1 : 1)); }
      const total = hit.length;
      if (this.rng) hit = hit.slice(this.rng[0], this.rng[1] + 1);
      if (this.lim != null) hit = hit.slice(0, this.lim);
      if (this.one) return hit[0] ? { data:hit[0], error:null } : { data:null, error:{ message:"no rows" } };
      return { data:hit, error:null, count:this.cnt ? total : null };
    }
    then(a, b) { return Promise.resolve().then(() => this.run()).then(a, b); }
  }

  function alerts(cid) {
    const out = [], vis = (t) => rows(t).filter((r) => r.company_id === cid);
    for (const v of vis("vehicles")) {
      for (const [what, dt] of [["انتهاء الاستمارة", v.registration_expiry], ["انتهاء التأمين", v.insurance_expiry], ["انتهاء رخصة السائق", v.license_expiry]])
        if (dt && dd(dt) <= 30) out.push({ level:dd(dt) <= 7 ? "h" : "m", kind:"expiry", entity:"vehicles", entity_id:v.id, department_id:v.department_id, label:v.plate + " — " + what, due:dt, days:dd(dt) });
      if (v.status !== "شغالة") out.push({ level:"m", kind:"stopped", entity:"vehicles", entity_id:v.id, department_id:v.department_id, label:v.plate + " — " + v.status + (v.location ? " — " + v.location : "") });
    }
    for (const d of vis("documents")) if (d.expiry_date && dd(d.expiry_date) <= 30) out.push({ level:dd(d.expiry_date) <= 7 ? "h" : "m", kind:"expiry", entity:"documents", entity_id:d.id, department_id:d.department_id, label:d.name, due:d.expiry_date, days:dd(d.expiry_date) });
    for (const l of vis("legal_cases")) if (l.status !== "مغلقة" && l.next_hearing && dd(l.next_hearing) >= 0 && dd(l.next_hearing) <= 14) out.push({ level:dd(l.next_hearing) <= 3 ? "h" : "m", kind:"hearing", entity:"legal_cases", entity_id:l.id, department_id:l.department_id, label:l.title, due:l.next_hearing, days:dd(l.next_hearing) });
    for (const i of vis("invoices")) if (i.status !== "مدفوعة" && dd(i.due_date) < 0) out.push({ level:"h", kind:"overdue", entity:"invoices", entity_id:i.id, department_id:i.department_id, label:i.number + " — " + i.party, due:i.due_date, days:dd(i.due_date), amount:i.amount });
    for (const p of vis("projects")) if (p.status !== "مكتمل" && (p.status === "متأخر" || dd(p.end_date) < 0)) out.push({ level:"h", kind:"late", entity:"projects", entity_id:p.id, department_id:p.department_id, label:p.name, due:p.end_date, days:dd(p.end_date), amount:p.contract_value });
    for (const r of vis("requests")) if (r.priority === "عاجل" && !["منجز","مرفوض"].includes(r.status)) out.push({ level:"m", kind:"urgent", entity:"requests", entity_id:r.id, department_id:r.department_id, label:r.title });
    for (const n of vis("manager_notes")) if (n.status === "مفتوحة") out.push({ level:"l", kind:"note", entity:"manager_notes", entity_id:n.id, department_id:n.department_id, label:n.subject || n.body.slice(0, 60), due:n.due_date, days:dd(n.due_date) });
    const o = { h:0, m:1, l:2 };
    return out.sort((a, b) => o[a.level] - o[b.level] || (a.days ?? 1e9) - (b.days ?? 1e9));
  }
  function stats(cid) {
    const v = (t) => rows(t).filter((r) => r.company_id === cid);
    const pr = v("projects").filter((p) => p.status !== "مكتمل");
    return { employees:v("profiles").filter((p) => p.status === "active").length, pending_members:v("profiles").filter((p) => p.status === "pending").length,
      departments:v("departments").length, vehicles_total:v("vehicles").length, vehicles_active:v("vehicles").filter((x) => x.status === "شغالة").length,
      projects_running:pr.length, projects_avg_progress:pr.length ? Math.round(pr.reduce((s, p) => s + p.progress, 0) / pr.length) : 0,
      cases_open:v("legal_cases").filter((x) => x.status !== "مغلقة").length,
      receivables:v("invoices").filter((x) => x.kind === "صادرة" && x.status !== "مدفوعة").reduce((s, x) => s + x.amount, 0),
      invoices_overdue:v("invoices").filter((x) => x.status !== "مدفوعة" && dd(x.due_date) < 0).length,
      notes_open:v("manager_notes").filter((x) => x.status === "مفتوحة").length, rooms_open:v("rooms").filter((x) => x.status === "مفتوحة").length };
  }
  const err = (m) => ({ data:null, error:{ message:m } });
  const RPC = {
    my_account: () => { const p = me(); const c = DB.companies.find((x) => x.id === p?.company_id); return p && { id:p.id, status:p.status, role:p.role, company_id:p.company_id, company_name:c?.name, company_active:c?.active, mfa_required:false, aal:"aal1" }; },
    lookup_company: ({ code }) => { const c = DB.companies.find((x) => [x.join_code, x.admin_code].includes(String(code).toUpperCase()) && x.active && !x.deleted_at); return c ? { name:c.name, logo_url:c.logo_url, is_admin_code:c.admin_code === String(code).toUpperCase() } : null; },
    dashboard_stats: ({ cid }) => stats(cid),
    // same shape and rules as public.dashboard_charts (due-date basis, last 12 months, visible rows only)
    dashboard_charts: ({ cid }) => {
      const v = (t) => rows(t).filter((r) => r.company_id === cid), now = new Date(), ym = (d) => d.slice(0, 7);
      const months = Array.from({ length:12 }, (_, i) => { const d = new Date(Date.UTC(now.getFullYear(), now.getMonth() - 11 + i, 1)); return d.toISOString().slice(0, 7); });
      const inv = v("invoices"), sum = (xs) => xs.reduce((s, x) => s + Number(x.amount), 0);
      const unpaid = inv.filter((x) => x.kind === "صادرة" && x.status !== "مدفوعة").map((x) => ({ a:Number(x.amount), d:-dd(x.due_date) }));
      const by = (t) => v(t).reduce((o, r) => ((o[r.status || "بدون حالة"] = (o[r.status || "بدون حالة"] || 0) + 1), o), {});
      const depAmt = {}; inv.filter((x) => x.kind === "صادرة" && x.status !== "مدفوعة").forEach((x) => { depAmt[x.department_id] = (depAmt[x.department_id] || 0) + Number(x.amount); });
      const exp = [...v("documents").map((d) => d.expiry_date), ...v("vehicles").flatMap((x) => [x.registration_expiry, x.insurance_expiry, x.license_expiry])].filter(Boolean).map(dd);
      return { as_of:new Date().toISOString(),
        monthly:months.map((m) => { const r = inv.filter((x) => x.due_date && ym(x.due_date) === m);
          return { month:m, issued:sum(r.filter((x) => x.kind === "صادرة")), incoming:sum(r.filter((x) => x.kind === "واردة")), collected:sum(r.filter((x) => x.kind === "صادرة" && x.status === "مدفوعة")) }; }),
        aging:{ not_due:sum(unpaid.filter((x) => x.d <= 0).map((x) => ({ amount:x.a }))), d1_30:sum(unpaid.filter((x) => x.d >= 1 && x.d <= 30).map((x) => ({ amount:x.a }))),
          d31_60:sum(unpaid.filter((x) => x.d >= 31 && x.d <= 60).map((x) => ({ amount:x.a }))), d61_90:sum(unpaid.filter((x) => x.d >= 61 && x.d <= 90).map((x) => ({ amount:x.a }))),
          d90_plus:sum(unpaid.filter((x) => x.d > 90).map((x) => ({ amount:x.a }))) },
        fleet:by("vehicles"), projects:by("projects"),
        receivables_by_dept:Object.entries(depAmt).sort((a, b) => b[1] - a[1]).slice(0, 6).map(([id, amount]) => ({ department:DB.departments.find((d) => d.id === id)?.name || "بدون قسم", amount })),
        expiry:{ expired:exp.filter((d) => d < 0).length, d30:exp.filter((d) => d >= 0 && d <= 30).length, d90:exp.filter((d) => d > 30 && d <= 90).length } };
    },
    company_alerts: ({ cid, lim }) => alerts(cid).slice(0, lim || 100),
    department_summary: ({ cid }) => rows("departments").filter((d) => d.company_id === cid).map((d) => ({ department_id:d.id,
      people:DB.profiles.filter((p) => p.department_id === d.id && p.status === "active").length,
      records:SOFT.filter((t) => t !== "manager_notes").reduce((s, t) => s + DB[t].filter((r) => r.department_id === d.id && !r.deleted_at).length, 0) })),
    approve_member: ({ target, dept, new_role }) => { if (!isAdmin() && !isSuper()) return { __e:"غير مصرح" }; const p = DB.profiles.find((x) => x.id === target); const before = { ...p }; Object.assign(p, { status:"active", department_id:dept, role:new_role, approved_by:session.user.id, approved_at:new Date().toISOString() }); audit("update", "profiles", p, before); },
    set_member_status: ({ target, new_status }) => { if (!isAdmin() && !isSuper()) return { __e:"غير مصرح" }; const p = DB.profiles.find((x) => x.id === target); const before = { ...p }; p.status = new_status; audit("update", "profiles", p, before); },
    regenerate_company_codes: ({ target, which }) => { const c = DB.companies.find((x) => x.id === target); const g = (l) => Array.from(crypto.getRandomValues(new Uint8Array(l)), (b) => "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"[b % 32]).join("");
      if (which !== "admin") c.join_code = g(12); if (which !== "join") c.admin_code = g(16); return { join_code:c.join_code }; },
    soft_delete: ({ tbl, rid }) => { if (!isAdmin()) return { __e:"غير مصرح" }; const r = DB[tbl].find((x) => x.id === rid); r.deleted_at = new Date().toISOString(); r.deleted_by = session.user.id; audit("soft_delete", tbl, r); },
    restore_deleted: ({ tbl, rid }) => { const r = DB[tbl].find((x) => x.id === rid); delete r.deleted_at; delete r.deleted_by; audit("restore", tbl, r); },
    list_trash: ({ cid }) => SOFT.flatMap((t) => DB[t].filter((r) => r.company_id === cid && r.deleted_at).map((r) => ({ entity:t, id:r.id, label:r.plate || r.number || r.name || r.title || r.subject, deleted_at:r.deleted_at, deleted_by:r.deleted_by }))),
    delete_company: ({ target }) => { const c = DB.companies.find((x) => x.id === target); c.deleted_at = new Date().toISOString(); c.active = false; },
    restore_company: ({ target }) => { const c = DB.companies.find((x) => x.id === target); delete c.deleted_at; c.active = true; },
    review_wa_message: ({ mid, decision }) => { const m = DB.wa_inbound.find((x) => x.id === mid); m.status = decision; },
    ai_usage_summary: () => ({ month_spent_usd:0, month_requests:0, budget_usd:30, daily_user_limit:60 }),
    invite_platform_admin: () => null,
    admin_delete_user: ({ target }) => { DB.profiles = DB.profiles.filter((p) => p.id !== target); },
    log_client_error: () => null,
    // same rules as public.report_profit_comparison (due-date basis, net profit not available), on the fake data
    report_profit_comparison: ({ a_from, a_to, b_from, b_to }) => {
      const cid = myCo(); const inv = rows("invoices").filter((i) => i.company_id === cid);
      const per = (f, t) => { const r = inv.filter((i) => i.due_date && i.due_date >= f && i.due_date <= t);
        const sum = (xs) => xs.reduce((s, i) => s + Number(i.amount), 0);
        const rev = r.filter((i) => i.kind === "صادرة"), sup = r.filter((i) => i.kind === "واردة");
        const parties = Object.entries(rev.reduce((m, i) => ((m[i.party] = m[i.party] || { amount:0, count:0 }), (m[i.party].amount += Number(i.amount)), m[i.party].count++, m), {}))
          .map(([party, v]) => ({ party, ...v })).sort((x, y) => y.amount - x.amount).slice(0, 5);
        const deps = Object.values(r.reduce((m, i) => { const d = DB.departments.find((x) => x.id === i.department_id)?.name ?? null;
          (m[d] = m[d] || { department:d, revenue:0, supplier:0 })[i.kind === "صادرة" ? "revenue" : "supplier"] += Number(i.amount); return m; }, {}));
        return { from:f, to:t, revenue_invoiced:sum(rev), supplier_invoiced:sum(sup), net_invoiced:sum(rev) - sum(sup), revenue_count:rev.length, supplier_count:sup.length,
          collected:sum(rev.filter((i) => i.status === "مدفوعة")), outstanding:sum(rev.filter((i) => i.status !== "مدفوعة")), supplier_paid:sum(sup.filter((i) => i.status === "مدفوعة")),
          top_clients:parties, by_department:deps };
      };
      const A = per(a_from, a_to), B = per(b_from, b_to);
      const change = Object.fromEntries(["revenue_invoiced","supplier_invoiced","net_invoiced","collected","outstanding"].map((k) =>
        [k, { abs:A[k] - B[k], pct:B[k] === 0 ? null : Math.round(((A[k] - B[k]) / Math.abs(B[k])) * 1000) / 10 }]));
      return { report:"profit_comparison", as_of:new Date().toISOString(), data_last_updated:inv.map((i) => i.updated_at).sort().pop() ?? null,
        basis:"invoice_due_date", basis_ar:"حسب تاريخ استحقاق الفواتير المسجلة في يقين", currency:"SAR", periods:{ a:A, b:B }, change,
        excluded_no_due_date:inv.filter((i) => !i.due_date).length,
        net_profit:{ available:false, reasons_ar:["لا يوجد في يقين دفتر مصروفات ولا رواتب ولا تكاليف مشاريع.", "الفواتير بدون تاريخ إصدار، فتُنسب للفترة حسب تاريخ الاستحقاق فقط.", "الفواتير غير مربوطة بالمشاريع، فلا يمكن حساب ربحية مشروع."],
          shown_instead_ar:"الفرق بين الفواتير الصادرة والواردة المستحقة في الفترة (صافي الفوترة)، وهو ليس ربحاً محاسبياً." } };
    },
  };

  // AI: NOT active in the demo. Answers are computed from the fake data and clearly labelled as examples.
  function demoAI(body) {
    const cid = myCo() ?? body.company_id, a = alerts(cid), s = stats(cid);
    if (body.mode === "brief") {
      const high = a.filter((x) => x.level === "h");
      return { brief:{ score:Math.max(35, 92 - high.length * 3),
        headline:"تقرير توضيحي محسوب من بيانات العرض الوهمية — في النسخة الكاملة يكتبه الذكاء الاصطناعي",
        kpis:[{ label:"مستحقات غير محصلة", value:Math.round(s.receivables / 1000) + " ألف ر.س" }, { label:"فواتير متأخرة", value:String(s.invoices_overdue) }, { label:"معدات شغالة", value:`${s.vehicles_active}/${s.vehicles_total}` }, { label:"متوسط إنجاز المشاريع", value:s.projects_avg_progress + "%" }],
        risks:high.slice(0, 5).map((x) => ({ level:"عالي", title:x.label, detail:x.kind === "overdue" ? `متأخرة ${-x.days} يوم` : x.days != null ? (x.days < 0 ? `منتهية منذ ${-x.days} يوم` : `بعد ${x.days} يوم`) : "", department:DB.departments.find((d) => d.id === x.department_id)?.name })),
        actions:[{ title:"اعتماد تجديد التأمينات المنتهية خلال أسبوع", department:"الأسطول والمعدات", why:"معدات بدون تأمين ساري تمنع دخول مواقع العملاء." },
                 { title:"خطة تحصيل للفواتير المتأخرة", department:"المالية", why:`${s.invoices_overdue} فاتورة متأخرة تضغط على السيولة.` }],
        insights:["هذا مثال لشكل التقرير فقط. الذكاء الاصطناعي غير مفعّل في نسخة العرض."] } };
    }
    if (body.mode === "chat") return { answer:`**نسخة عرض: الذكاء الاصطناعي غير مفعّل.**\nفي النسخة الكاملة يجيب مساعد يقين على سؤالك من بيانات الشركة. مثال لنوع المعلومات المتاحة من بيانات العرض:\n- المعدات: ${s.vehicles_active} شغالة من ${s.vehicles_total}\n- الفواتير المتأخرة: ${s.invoices_overdue}\n- القضايا المفتوحة: ${s.cases_open}\n- المشاريع الجارية: ${s.projects_running} بمتوسط إنجاز ${s.projects_avg_progress}%` };
    if (body.mode === "note_reply") return { text:"(مسودة توضيحية — الذكاء الاصطناعي غير مفعّل في نسخة العرض) تم الاطلاع على الملاحظة، وجاري العمل عليها، وبنرفع لكم التحديث قبل الموعد." };
    return null;
  }
  const blobs = {};
  return {
    from: (t) => new Query(t),
    async rpc(fn, args) { const h = RPC[fn]; if (!h) return err("غير متاح في نسخة العرض"); const r = h(args || {}); return r && r.__e ? err(r.__e) : { data:r ?? null, error:null }; },
    functions: { async invoke(name, { body }) { const out = demoAI(body);
      return out ? { data:out, error:null } : { data:null, error:{ message:"هذه الميزة تحتاج الذكاء الاصطناعي، وهو غير مفعّل في نسخة العرض.", context:{ json:async () => ({ error:"هذه الميزة تحتاج الذكاء الاصطناعي، وهو غير مفعّل في نسخة العرض." }) } } }; } },
    auth: {
      async getSession() { return { data:{ session } }; },
      onAuthStateChange(cb) { listeners.push(cb); setTimeout(() => cb("INITIAL_SESSION", session), 0); return { data:{ subscription:{ unsubscribe() {} } } }; },
      async signInWithPassword({ email }) { const p = DB.profiles.find((x) => x.email === String(email).toLowerCase()); if (!p) return err("في نسخة العرض استخدم أزرار الحسابات في الشريط العلوي"); session = { user:{ id:p.id, email:p.email } }; emit("SIGNED_IN"); return { data:{ session }, error:null }; },
      async signUp({ email, options }) { const d = options?.data || {}; const c = DB.companies.find((x) => x.join_code === d.company_code || x.admin_code === d.company_code);
        if (!c) return err("Database error saving new user"); const isAdm = c.admin_code === d.company_code;
        DB.profiles.push({ id:uid(), company_id:c.id, full_name:d.full_name, email:String(email).toLowerCase(), job_title:d.job_title, phone:d.phone, role:isAdm ? "admin" : "employee", status:isAdm ? "active" : "pending", department_id:null, created_at:new Date().toISOString() });
        return { data:{ session:null }, error:null }; },
      async signOut() { session = null; emit("SIGNED_OUT"); return { error:null }; },
      async updateUser() { return { error:null }; },
      async resetPasswordForEmail() { return { error:{ message:"غير متاح في نسخة العرض" } }; },
      mfa: { async getAuthenticatorAssuranceLevel() { return { data:{ currentLevel:"aal1", nextLevel:"aal1" }, error:null }; }, async listFactors() { return { data:{ totp:[], all:[] }, error:null }; },
        async enroll() { return err("التحقق الثنائي غير متاح في نسخة العرض"); }, async challengeAndVerify() { return err("غير متاح"); }, async unenroll() { return { error:null }; } },
    },
    storage: { from: () => ({
      async upload(path, blob) { blobs[path] = URL.createObjectURL(blob); return { error:null }; },
      getPublicUrl: (path) => ({ data:{ publicUrl:blobs[path] || "" } }),
      async createSignedUrls(paths) { return { data:paths.map((p) => ({ path:p, signedUrl:blobs[p] || null })), error:null }; },
      async remove() { return { error:null }; }, async list() { return { data:[], error:null }; } }) },
    channel() { const c = { on:() => c, subscribe:() => c, send:async () => ({}) }; return c; },
    removeChannel() {},
    __demo: { async login(k) { if (session) { session = null; emit("SIGNED_OUT"); await new Promise((r) => setTimeout(r, 30)); } const p = DB.profiles.find((x) => x.id === ACCOUNTS[k]); session = { user:{ id:p.id, email:p.email } }; emit("SIGNED_IN"); } },
  };
}
