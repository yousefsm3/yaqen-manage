// In-browser stand-in for @supabase/supabase-js used by the UI tests.
// The real CDN module is replaced with this file by Playwright (page.route). It never touches the network.
// Scenario data comes from window.__SCN (set by the test); every call is recorded in window.__CALLS
// so the test can assert what the UI asked the server to do.
const SCN = globalThis.__SCN || {};
const CALLS = (globalThis.__CALLS = []);
const DB = SCN.tables || {};
const log = (c) => { CALLS.push(JSON.parse(JSON.stringify(c))); };

class Query {
  constructor(t) { this.t = t; this.op = "select"; this.filters = []; this.rng = null; this.lim = null; this.one = false; this.count = false; this.payload = null; }
  select(cols, opts) { if (this.op === "select") this.cols = cols; if (opts?.count) this.count = true; this.ret = true; return this; }
  insert(rows) { this.op = "insert"; this.payload = rows; return this; }
  update(row) { this.op = "update"; this.payload = row; return this; }
  upsert(rows) { this.op = "upsert"; this.payload = rows; return this; }
  delete() { this.op = "delete"; return this; }
  eq(k, v) { this.filters.push(["eq", k, v]); return this; }
  neq(k, v) { this.filters.push(["neq", k, v]); return this; }
  in(k, v) { this.filters.push(["in", k, v]); return this; }
  gte(k, v) { this.filters.push(["gte", k, v]); return this; }
  lte(k, v) { this.filters.push(["lte", k, v]); return this; }
  is(k, v) { this.filters.push(["eq", k, v]); return this; }
  or(expr) { this.filters.push(["or", expr]); return this; }
  order() { return this; }
  range(a, b) { this.rng = [a, b]; return this; }
  limit(n) { this.lim = n; return this; }
  single() { this.one = true; return this; }
  maybeSingle() { this.one = true; return this; }
  match(r) {
    return this.filters.every(([op, k, v]) => {
      if (op === "eq") return r[k] === v;
      if (op === "neq") return r[k] !== v;
      if (op === "gte") return r[k] != null && r[k] >= v;
      if (op === "lte") return r[k] != null && r[k] <= v;
      if (op === "in") return v.includes(r[k]);
      if (op === "or") return k.split(",").some((part) => {
        const [col, , pat] = part.split(".");
        const term = pat.replace(/^\*|\*$/g, "").toLowerCase();
        return String(r[col] ?? "").toLowerCase().includes(term);
      });
      return true;
    });
  }
  run() {
    const rows = (DB[this.t] = DB[this.t] || []);
    log({ t:this.t, op:this.op, filters:this.filters, range:this.rng, limit:this.lim, payload:this.payload });
    const deny = (SCN.deny || {})[this.t + ":" + this.op];
    if (deny) return { data:null, error:{ message:deny }, count:null };
    if (this.op === "insert" || this.op === "upsert") {
      const list = (Array.isArray(this.payload) ? this.payload : [this.payload]).map((r) => ({ id:crypto.randomUUID(), created_at:new Date().toISOString(), ...r }));
      rows.push(...list);
      return { data:this.one ? list[0] : list, error:null };
    }
    let hit = rows.filter((r) => this.match(r));
    if (this.op === "update") { hit.forEach((r) => Object.assign(r, this.payload)); return { data:this.one ? hit[0] ?? null : hit, error:null }; }
    if (this.op === "delete") { DB[this.t] = rows.filter((r) => !hit.includes(r)); return { data:null, error:null }; }
    const total = hit.length;
    if (this.rng) hit = hit.slice(this.rng[0], this.rng[1] + 1);
    if (this.lim != null) hit = hit.slice(0, this.lim);
    if (this.one) return hit[0] ? { data:hit[0], error:null } : { data:null, error:{ message:"no rows" } };
    return { data:hit, error:null, count:this.count ? total : null };
  }
  then(res, rej) { return Promise.resolve().then(() => this.run()).then(res, rej); }
}

export function createClient() {
  const user = SCN.user ? { id:SCN.user, email:SCN.email || "qa@example.com" } : null;
  const session = user ? { user, access_token:"stub" } : null;
  const aal = SCN.aal || { currentLevel:"aal1", nextLevel:"aal1" };
  return {
    from: (t) => new Query(t),
    async rpc(fn, args) {
      log({ rpc:fn, args });
      const h = (SCN.rpc || {})[fn];
      if (h && typeof h === "object" && h.__error) return { data:null, error:{ message:h.__error } };
      return { data:h === undefined ? null : h, error:null };
    },
    functions: {
      async invoke(name, { body }) {
        log({ fn:name, body });
        const out = (SCN.ai || {})[body.mode];
        return out ? { data:out, error:null } : { data:null, error:{ message:"NO_KEY", context:{ json:async () => ({ error:"NO_KEY" }) } } };
      },
    },
    auth: {
      async getSession() { return { data:{ session } }; },
      onAuthStateChange(cb) { setTimeout(() => cb("INITIAL_SESSION", session), 0); return { data:{ subscription:{ unsubscribe() {} } } }; },
      async signInWithPassword(a) { log({ auth:"signIn", email:a.email }); return { data:{}, error:{ message:"Invalid login credentials" } }; },
      async signUp(a) { log({ auth:"signUp", email:a.email, data:a.options?.data, pwLen:String(a.password).length }); return { data:{ session:null }, error:null }; },
      async signOut() { log({ auth:"signOut" }); return { error:null }; },
      async updateUser(a) { log({ auth:"updateUser", pwLen:a.password ? String(a.password).length : 0 }); return { error:null }; },
      async resetPasswordForEmail() { return { error:null }; },
      mfa: {
        async getAuthenticatorAssuranceLevel() { return { data:aal, error:null }; },
        async listFactors() { const f = SCN.factors || []; return { data:{ totp:f, all:f }, error:null }; },
        async enroll() { log({ mfa:"enroll" }); return { data:{ id:"f-new", totp:{ qr_code:"data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg'/>", secret:"JBSWY3DPEHPK3PXP" } }, error:null }; },
        async challengeAndVerify(a) { log({ mfa:"verify", code:a.code }); return a.code === "123456" ? { data:{}, error:null } : { data:null, error:{ message:"Invalid TOTP code" } }; },
        async unenroll(a) { log({ mfa:"unenroll", id:a.factorId }); return { error:null }; },
      },
    },
    storage: { from: () => ({
      async upload() { return { error:null }; }, getPublicUrl: () => ({ data:{ publicUrl:"" } }),
      async createSignedUrl() { return { data:{ signedUrl:"" }, error:null }; }, async createSignedUrls() { return { data:[], error:null }; },
      async remove() { return { error:null }; }, async list() { return { data:[], error:null }; } }) },
    channel() { const c = { on:() => c, subscribe:() => c, send:async () => ({}) }; return c; },
    removeChannel() {},
  };
}
