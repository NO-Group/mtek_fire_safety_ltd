// ============================================================================
// M-TEK DATA API — Supabase Edge Function (Deno). THE production backend.
//
//   Supabase  = AUTH ONLY (GoTrue + JWT verification)
//   MongoDB   = ALL storage — 7 section databases on the owner's cluster
//
// STOCK IS NEVER SEEDED: the products collection starts EMPTY and is filled
// through the app's own fields (Add product / Import TXT → /api/products/upsert).
// Serial books still self-provision from 000000001 on first call.
//
// Deploy (owner preference — ONE file, no local imports):
//   Supabase dashboard → Edge Functions → Create a new function → name it
//   `data-api` → replace index.ts with THIS file → Deploy. That's all.
//
// Function secrets (dashboard → Edge Functions → Secrets):
//   MONGODB_URI   (your Atlas connection string)
//   MTEK_CEO_SIG  (the CEO signature passcode)
//   SUPABASE_SECRET_KEY(S) — Supabase default, leave as-is
//
// The apps call:  https://kshuadjcflwlidupnqly.supabase.co/functions/v1/data-api/...
//                 Authorization: Bearer <Supabase JWT>
// ============================================================================

// deno-lint-ignore no-import-assertions
import { MongoClient, ObjectId } from 'https://deno.land/x/mongo@v0.32.0/mod.ts';
// DRIVER SWAP (edge-runtime activation fix): the official npm:mongodb driver
// bundles to many MB and the function uploaded but NEVER activated — the
// platform silently kept serving the last healthy deployment (proven with a
// minimal canary that activated instantly, and with a lazy-import variant
// that still failed). x/mongo is a small pure-Deno driver with the same
// CRUD surface this API uses (find/sort/limit/toArray, insertOne, updateOne,
// updateMany, $-operators are all server-side and driver-agnostic).

// ---- environment (Function secrets — see header comment above) --------------
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected by the Supabase
// Edge Runtime for every function; SUPABASE_SECRET_KEY is kept as a fallback
// name since older projects expose the service key under that key instead.
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE =
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ??
  Deno.env.get('SUPABASE_SECRET_KEY') ??
  Deno.env.get('SUPABASE_ANON_KEY') ??
  '';
// The CEO identity is locked to this email (owner directive) and, optionally,
// a specific Supabase Auth UID if MTEK_CEO_UID is set as a secret.
const CEO_EMAIL = 'mtekfiresafetyltd@gmail.com';
const CEO_UID = Deno.env.get('MTEK_CEO_UID') ?? '';
// The CEO signature passcode (owner directive 2026-09-02 — 093618).
// HARDCODED ON PURPOSE: an old MTEK_CEO_SIG function secret previously
// overrode the directive, so the CEO's passcode silently never matched.
// To change the CEO passcode later: edit this constant AND bump
// SIG_RESET_ID below, then redeploy (or rotate in-app via Settings →
// Account → Signature passcode, which sticks — see the self-heal note).
const CEO_SIG = '093618';
// One-time passcode reset marker: whenever this value differs from the
// profile's stored sig_reset, the CEO's stored signature hash is re-bound
// to CEO_SIG exactly once (then the marker is written). Bump it to force a
// new server-side reset; between bumps, in-app passcode changes STICK
// (the previous unconditional self-heal silently reverted every change).
const SIG_RESET_ID = '2026-09-02a';
// Bundle marker returned by GET /health so a deploy can be VERIFIED from
// the outside (bump whenever index.ts changes).
const BUNDLE_VERSION = '2026-09-02f-xmongo';
// True when this GoTrue user is the locked CEO identity (by UID or email).
const isCeoUser = (id: unknown, email: unknown) =>
  String(id ?? '') === CEO_UID || String(email ?? '').toLowerCase() === CEO_EMAIL;

// CORS: the Android/Windows apps call this function directly (no browser
// origin to restrict to), so allow any origin but only the methods/headers
// this API actually uses.
const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
};

// ---- section databases (never entangled) ------------------------------------
const DB = {
  core: 'mtek_core', inventory: 'mtek_inventory', people: 'mtek_people',
  billing: 'mtek_billing', mils: 'mtek_mils', documents: 'mtek_documents',
  audit: 'mtek_audit',
};
const SECTION_DBS = Object.values(DB);

let client: MongoClient | null = null;
async function db(name: string) {
  if (!client) {
    client = new MongoClient();
    await client.connect(Deno.env.get('MONGODB_URI') ?? '');
  }
  return client.database(name);
}
const coll = {
  serials: () => db(DB.core).then(d => d.collection('serials')),
  settings: () => db(DB.core).then(d => d.collection('settings')),
  products: () => db(DB.inventory).then(d => d.collection('products')),
  adjustments: () => db(DB.inventory).then(d => d.collection('stock_adjustments')),
  profiles: () => db(DB.people).then(d => d.collection('profiles')),
  customers: () => db(DB.people).then(d => d.collection('customers')),
  sales: () => db(DB.billing).then(d => d.collection('sales')),
  txns: () => db(DB.billing).then(d => d.collection('transactions')),
  invoices: () => db(DB.billing).then(d => d.collection('invoices')),
  receipts: () => db(DB.billing).then(d => d.collection('receipts')),
  payments: () => db(DB.billing).then(d => d.collection('invoice_payments')),
  mils: () => db(DB.mils).then(d => d.collection('logs')),
  archive: () => db(DB.documents).then(d => d.collection('archive')),
  audit: () => db(DB.audit).then(d => d.collection('events')),
  notifications: () => db(DB.core).then(d => d.collection('notifications')),
};

// ---- helpers ----------------------------------------------------------------
const pad9 = (n: number) => String(n).padStart(9, '0');
const fmtN = (n: number) => '₦' + Math.round(n).toLocaleString('en-NG');
const BOOK_TYPES = ['receiptIssue', 'receipt', 'invoice', 'mils', 'waybill', 'deliverynote'];
const now = () => new Date().toISOString();

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
const err = (status: number, message: string) => json({ error: message }, status);

async function audit(section: string, action: string, ref: string, user: Profile) {
  try {
    (await coll.audit()).insertOne({ section, action, ref: String(ref), by: user.uid, by_name: user.name, at: now() });
  } catch { /* never break a request on audit failure */ }
}

// ---- notifications: every significant write fires one of these, visible
// to EVERY signed-in user (CEO, Admin, Sales) — owner directive 2026-09-01
// ("the CEO admin and any user should receive a notification ... when any
// transaction happens"). Announcements (CEO/Admin → all staff) reuse the
// same collection with kind='announcement' and track exactly who has read
// them so the sender can see a read count + reader list.
async function notify(kind: string, title: string, message: string, ref: string, user: Profile) {
  try {
    await (await coll.notifications()).insertOne({
      kind, title, message, ref: String(ref),
      created_by: user.uid, created_by_name: user.name, created_at: now(),
      read_by: [] as Array<{ uid: string; name: string; at: string }>,
    });
  } catch { /* never break a request because a notification failed to save */ }
}

// ---- auth: Supabase JWT → MongoDB profile ------------------------------------
interface Profile {
  uid: string; email: string; name: string; role: string;
  sig_hash: string; sig_salt: string;
}
const hashPass = (secret: string, salt: string) => {
  // scrypt via WebCrypto is unavailable here, so we use HMAC-SHA512
  // (salt+secret, key='mtek-store-salt') — deterministic and salted.
  // Kept byte-identical with backend/scripts/seed-mongo.js so a passcode
  // seeded there verifies correctly here.
  return hmacHex(`${salt}${secret}`, 'mtek-store-salt');
};
// Recovery strings use a SEPARATE HMAC key from signature passcodes so a
// leaked signature hash can never be replayed as a password-recovery hash.
const hashRecovery = (secret: string, salt: string) => hmacHex(`${salt}${secret}`, 'mtek-recovery-salt');
async function hmacHex(message: string, key: string): Promise<string> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-512' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, enc.encode(message));
  return [...new Uint8Array(sig)].map(b => b.toString(16).padStart(2, '0')).join('');
}

const profileCache = new Map<string, { value: Profile; expires: number }>();
async function auth(req: Request): Promise<Profile> {
  const jwt = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!jwt) throw new HttpErr(401, 'Missing bearer token');
  // NOTE: Supabase's GET /auth/v1/user returns the user id under `id`, NOT
  // `sub` (`sub` only exists inside a raw JWT payload). Keying everything on
  // `user.sub` made every profile lookup/cache key resolve to `undefined`,
  // so accounts could collide and pick up the WRONG cached role — the
  // reported "CEO signs in and shows as Sales" bug. Everything here now keys
  // on the real `user.id`.
  let user: { id: string; email?: string; user_metadata?: Record<string, unknown> };
  try {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SERVICE_ROLE, Authorization: `Bearer ${jwt}` },
    });
    if (!r.ok) throw new HttpErr(401, 'Invalid or expired token');
    user = await r.json();
  } catch (e) {
    if (e instanceof HttpErr) throw e;
    throw new HttpErr(503, 'Auth service unreachable — try again shortly');
  }
  if (!user.id) throw new HttpErr(401, 'Invalid or expired token');
  const cached = profileCache.get(user.id);
  if (cached && Date.now() < cached.expires) return cached.value;

  const profiles = await coll.profiles();
  let p = await profiles.findOne({ _id: user.id }) as Record<string, unknown> | null;
  const isCeo = user.id === CEO_UID || String(user.email ?? '').toLowerCase() === CEO_EMAIL;
  if (!p) {
    const salt = crypto.randomUUID().replaceAll('-', '').slice(0, 16);
    p = {
      _id: user.id,
      email: String(user.email ?? '').toLowerCase(),
      full_name: (user.user_metadata?.full_name as string) || (isCeo ? 'CEO' : String(user.email ?? 'staff').split('@')[0]),
      role: isCeo ? 'ceo' : 'sales', // the CEO identity is locked by hardcode
      sig_salt: salt,
      sig_hash: isCeo && CEO_SIG ? await hashPass(CEO_SIG, salt) : null,
      sig_reset: SIG_RESET_ID,
      created_at: now(),
    };
    await profiles.insertOne(p as Record<string, unknown>);
  } else if (isCeo && p.role !== 'ceo') {
    await profiles.updateOne({ _id: user.id }, { $set: { role: 'ceo' } });
    p.role = 'ceo';
  }
  // Self-heal the CEO's SIGNATURE PASSCODE — but only ONCE per SIG_RESET_ID
  // (owner directive 2026-09-02 → 093618). Gating on the marker means: a
  // deploy with a bumped SIG_RESET_ID force-applies the new passcode even
  // though an old hash is stored (the "new passcode not recognised" bug),
  // while the CEO's own in-app passcode rotations (Settings → Account)
  // stick — the old unconditional self-heal silently reverted those on the
  // very next call. Also guarantees role='ceo'.
  if (isCeo && CEO_SIG && (p as Record<string, unknown>).sig_reset !== SIG_RESET_ID) {
    const salt = String(p.sig_salt ?? '').slice(0, 16) || crypto.randomUUID().replaceAll('-', '').slice(0, 16);
    const wantHash = await hashPass(CEO_SIG, salt);
    await profiles.updateOne(
      { _id: user.id },
      { $set: { role: 'ceo', sig_salt: salt, sig_hash: wantHash, sig_reset: SIG_RESET_ID, email: String(user.email ?? '').toLowerCase() } });
    p.role = 'ceo'; p.sig_salt = salt; p.sig_hash = wantHash;
    p.email = String(user.email ?? '').toLowerCase();
    (p as Record<string, unknown>).sig_reset = SIG_RESET_ID;
  }
  const value: Profile = {
    uid: user.id, email: String(p.email), name: String(p.full_name),
    role: String(p.role), sig_hash: String(p.sig_hash ?? ''), sig_salt: String(p.sig_salt ?? ''),
  };
  profileCache.set(user.id, { value, expires: Date.now() + 60_000 });
  return value;
}

class HttpErr extends Error { constructor(public status: number, message: string) { super(message); } }

function requireRole(user: Profile, roles: string[], what: string) {
  if (!roles.includes(user.role)) {
    throw new HttpErr(403, roles.length === 1 && roles[0] === 'ceo'
      ? `Only the CEO can ${what}` : `Only CEO or Admin can ${what}`);
  }
}

async function verifyPasscode(user: Profile, passcode: string) {
  if (!passcode) throw new HttpErr(403, 'Not signed — passcode required');
  const hash = user.sig_hash && user.sig_salt ? await hashPass(passcode, user.sig_salt) : '';
  if (hash && hash === user.sig_hash) return;
  // first bind: CEO's configured signature seeds the hash on first use
  if (!user.sig_hash && CEO_SIG && passcode === CEO_SIG && user.role === 'ceo') {
    const salt = crypto.randomUUID().replaceAll('-', '').slice(0, 16);
    await (await coll.profiles()).updateOne(
      { _id: user.uid }, { $set: { sig_salt: salt, sig_hash: await hashPass(CEO_SIG, salt) } });
    profileCache.delete(user.uid);
    return;
  }
  throw new HttpErr(403, 'Signature passcode does not match — action NOT authorised');
}

// ---- core provisioning (serials from 000000001, REAL owner catalogue) -------
async function ensureCore() {
  const s = await coll.serials();
  for (const t of BOOK_TYPES) {
    await s.updateOne({ _id: t }, { $setOnInsert: { last_used: 0 } }, { upsert: true });
  }
  await coll.settings().then(c =>
    c.updateOne({ _id: 'settings' }, { $setOnInsert: { vat_enabled: false, vat_rate: 0.075, watermark: true } }, { upsert: true }));
}
async function nextSerial(type: string): Promise<number> {
  const out = await (await coll.serials()).findOneAndUpdate(
    { _id: type }, { $inc: { last_used: 1 } }, { returnDocument: 'after', upsert: true });
  return out!.last_used as number;
}
async function peekSerials(): Promise<Record<string, number>> {
  const rows = await (await coll.serials()).find({}).toArray();
  const out: Record<string, number> = {};
  for (const r of rows) if (r._id !== 'seeded') out[String(r._id)] = Number(r.last_used ?? 0);
  return out;
}

// ---- router -----------------------------------------------------------------
Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/functions\/v1\/data-api/, '') || '/';
  if (req.method === 'GET' && (path === '/' || path === '/health')) {
    return json({ ok: true, version: 'bisect-tops-only', note: 'full top section, canary handler' });
  }
  return err(503, 'bisect build');
});
