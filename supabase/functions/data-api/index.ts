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

import { MongoClient } from 'npm:mongodb@6.8.0';

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
const CEO_SIG = Deno.env.get('MTEK_CEO_SIG') ?? '';

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
    client = new MongoClient(Deno.env.get('MONGODB_URI') ?? '', { appName: 'mtek-edge' });
  }
  if (!client.topology || !client.topology.isConnected()) await client.connect();
  return client.db(name);
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
};

// ---- helpers ----------------------------------------------------------------
const pad9 = (n: number) => String(n).padStart(9, '0');
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

// ---- auth: Supabase JWT → MongoDB profile ------------------------------------
interface Profile { uid: string; email: string; name: string; role: string; sig_hash: string; sig_salt: string; }
const hashPass = (secret: string, salt: string) => {
  // scrypt via WebCrypto is unavailable here, so we use HMAC-SHA512
  // (salt+secret, key='mtek-store-salt') — deterministic and salted.
  // Kept byte-identical with backend/scripts/seed-mongo.js so a passcode
  // seeded there verifies correctly here.
  return hmacHex(`${salt}${secret}`, 'mtek-store-salt');
};
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
  let user: { sub: string; email?: string; user_metadata?: Record<string, unknown> };
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
  const cached = profileCache.get(user.sub);
  if (cached && Date.now() < cached.expires) return cached.value;

  const profiles = await coll.profiles();
  let p = await profiles.findOne({ _id: user.sub }) as Record<string, unknown> | null;
  const isCeo = user.sub === CEO_UID || String(user.email ?? '').toLowerCase() === CEO_EMAIL;
  if (!p) {
    const salt = crypto.randomUUID().replaceAll('-', '').slice(0, 16);
    p = {
      _id: user.sub,
      email: String(user.email ?? '').toLowerCase(),
      full_name: (user.user_metadata?.full_name as string) || (isCeo ? 'CEO' : String(user.email ?? 'staff').split('@')[0]),
      role: isCeo ? 'ceo' : 'sales', // the CEO identity is locked by hardcode
      sig_salt: salt,
      sig_hash: isCeo && CEO_SIG ? await hashPass(CEO_SIG, salt) : null,
      created_at: now(),
    };
    await profiles.insertOne(p as Record<string, unknown>);
  } else if (isCeo && p.role !== 'ceo') {
    await profiles.updateOne({ _id: user.sub }, { $set: { role: 'ceo' } });
    p.role = 'ceo';
  }
  const value: Profile = {
    uid: user.sub, email: String(p.email), name: String(p.full_name),
    role: String(p.role), sig_hash: String(p.sig_hash ?? ''), sig_salt: String(p.sig_salt ?? ''),
  };
  profileCache.set(user.sub, { value, expires: Date.now() + 60_000 });
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
  const route = `${req.method} ${path}`;

  try {
    if (route === 'GET /' || route === 'GET /health') {
      await ensureCore();
      return json({ ok: true, databases: SECTION_DBS, serials: await peekSerials() });
    }

    // ---- public auth: email + password sign-in (Supabase GoTrue proxy) ----
    if (route === 'POST /api/auth/login') {
      const b = await req.json().catch(() => ({} as Record<string, unknown>));
      let gr: Response;
      try {
        gr = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
          method: 'POST',
          headers: { apikey: SERVICE_ROLE || (Deno.env.get('SUPABASE_ANON_KEY') ?? ''), 'Content-Type': 'application/json' },
          body: JSON.stringify({ email: String(b.email ?? ''), password: String(b.password ?? '') }),
        });
      } catch {
        return err(503, 'Auth service unreachable — try again shortly');
      }
      const j = await gr.json().catch(() => ({} as Record<string, unknown>));
      if (!gr.ok) {
        return err(401, String(j.error_description ?? j.msg ?? 'Wrong email or password'));
      }
      const u = (j.user ?? {}) as Record<string, unknown>;
      const token = String(j.access_token ?? '');
      let profile: Profile | null = null;
      try {
        profile = await auth(new Request('https://internal/', { headers: { authorization: `Bearer ${token}` } }));
      } catch { /* profile warming is best-effort */ }
      return json({
        access_token: token,
        user: {
          uid: String(u.id ?? ''), email: String(u.email ?? ''),
          name: profile?.name ?? String((u.user_metadata as Record<string, unknown> | undefined)?.full_name ?? String(u.email ?? '').split('@')[0]),
          role: profile?.role ?? 'sales',
        },
      });
    }
    if (route === 'POST /api/auth/signup') {
      // open self-registration is disabled on the live system (authority rules):
      // the CEO adds staff in Supabase → Authentication → Users → "Add user".
      return err(403, 'Staff accounts are created by the CEO (Supabase dashboard → Authentication → Add user), then sign in here');
    }

    const user = await auth(req);

    switch (route) {
      case 'GET /api/me':
        return json({ user: { uid: user.uid, email: user.email, name: user.name, role: user.role } });

      case 'GET /api/bootstrap': {
        await ensureCore();
        const [products, customers, settings, serials, txns, receipts, invoices, docs, sales, mils, adjustments] = await Promise.all([
          (await coll.products()).find({}).sort({ name: 1 }).limit(1000).toArray(),
          (await coll.customers()).find({}).sort({ name: 1 }).limit(1000).toArray(),
          (await coll.settings()).findOne({ _id: 'settings' }),
          peekSerials(),
          (await coll.txns()).find({}).sort({ txn_date: -1 }).limit(300).toArray(),
          (await coll.receipts()).find({}).sort({ created_at: -1 }).limit(300).toArray(),
          (await coll.invoices()).find({}).sort({ created_at: -1 }).limit(300).toArray(),
          (await coll.archive()).find({}).sort({ issued_at: -1 }).limit(100).toArray(),
          (await coll.sales()).find({}).sort({ created_at: -1 }).limit(300).toArray(),
          (await coll.mils()).find({}).sort({ created_at: -1 }).limit(300).toArray(),
          (await coll.adjustments()).find({}).sort({ created_at: -1 }).limit(300).toArray(),
        ]);
        return json({
          user: { uid: user.uid, email: user.email, name: user.name, role: user.role },
          products, customers, transactions: txns, receipts, invoices, docs, sales, mils, adjustments,
          settings: { vat_enabled: settings?.vat_enabled ?? false, vat_rate: settings?.vat_rate ?? 0.075, watermark: settings?.watermark ?? true },
          serials,
        });
      }

      case 'POST /api/auth/signature': {
        const b = await req.json();
        await verifyPasscode(user, String(b.passcode ?? ''));
        return json({ ok: true, user: { uid: user.uid, name: user.name, role: user.role } });
      }

      case 'POST /api/customers': {
        const b = await req.json();
        if (!b.name || String(b.name).trim().length < 2) throw new HttpErr(400, 'Customer name required');
        const doc = {
          name: String(b.name).trim().slice(0, 120),
          kind: b.corp || b.kind === 'corporate' ? 'corporate' : 'individual',
          phone: String(b.phone ?? ''), email: String(b.email ?? ''), address: String(b.address ?? ''),
          credit_balance: 0, created_by: user.uid, created_at: now(),
        };
        const out = await (await coll.customers()).insertOne(doc);
        await audit('customers', 'create', String(out.insertedId), user);
        return json({ customer: { ...doc, _id: out.insertedId } }, 201);
      }

      case 'POST /api/products/upsert': {
        requireRole(user, ['ceo', 'admin'], 'edit stock / import products');
        const b = await req.json();
        const rows = Array.isArray(b.products) ? b.products : [b];
        let upserted = 0;
        for (const r of rows) {
          if (!r.id || !r.name) continue;
          await (await coll.products()).updateOne({ _id: String(r.id) }, { $set: {
            name: String(r.name), category: r.category ?? 'Fire',
            cost_price: Number(r.cost_price) || 0, selling_price: Number(r.selling_price) || 0,
            qty_on_hand: Math.max(0, Math.trunc(Number(r.qty_on_hand) || 0)),
            reorder_level: Math.max(0, Math.trunc(Number(r.reorder_level) || 0)),
            unit: r.unit ?? 'unit', is_service: !!r.is_service, updated_at: now(),
          } }, { upsert: true });
          upserted++;
        }
        await audit('inventory', 'upsert', `${upserted} products`, user);
        return json({ ok: true, upserted });
      }

      case 'POST /api/stock/adjust': {
        requireRole(user, ['ceo', 'admin'], 'edit stock');
        const b = await req.json();
        const delta = Math.trunc(Number(b.delta) || 0);
        if (!delta) throw new HttpErr(400, 'Quantity change required');
        const guarded = await (await coll.products()).updateOne(
          { _id: String(b.id), $expr: { $gte: [{ $add: ['$qty_on_hand', delta] }, 0] } },
          { $inc: { qty_on_hand: delta }, $set: { updated_at: now() } });
        if (!guarded.matchedCount) throw new HttpErr(400, 'Unknown product or adjustment would drive stock negative');
        const adj = { product_id: String(b.id), delta, reason: String(b.reason ?? 'CORRECTION'), note: String(b.note ?? ''), by: user.uid, by_name: user.name, created_at: now() };
        await (await coll.adjustments()).insertOne(adj);
        await audit('inventory', 'adjust', `${b.id} ${delta > 0 ? '+' : ''}${delta}`, user);
        return json({ ok: true, adjustment: adj });
      }

      case 'POST /api/sales': {
        const b = await req.json();
        await verifyPasscode(user, String(b.passcode ?? ''));
        const items = Array.isArray(b.items) ? b.items : [];
        if (!items.length) throw new HttpErr(400, 'Cart is empty');
        const method = ['cash', 'transfer', 'pos', 'credit'].includes(b.method) ? b.method : 'cash';
        const products = await coll.products();
        const lines: Array<Record<string, unknown>> = [];
        let subtotal = 0;
        for (const it of items) {
          const p = await products.findOne({ _id: String(it.product_id) }) as Record<string, unknown> | null;
          if (!p) throw new HttpErr(400, `Unknown product ${it.product_id}`);
          const qty = Math.trunc(Number(it.qty) || 0);
          if (qty <= 0) throw new HttpErr(400, 'Invalid quantity');
          if (!p.is_service) {
            const g = await products.updateOne(
              { _id: p._id, qty_on_hand: { $gte: qty } },
              { $inc: { qty_on_hand: -qty }, $set: { updated_at: now() } });
            if (!g.modifiedCount) throw new HttpErr(400, `Only ${p.qty_on_hand} ${p.unit} of ${p.name} in stock`);
          }
          subtotal += Number(p.selling_price) * qty;
          lines.push({ product_id: p._id, name: p.name, qty, unit_price: p.selling_price });
        }
        const discount = Math.max(0, Math.trunc(Number(b.discount) || 0));
        const total = Math.max(subtotal - discount, 0);

        let customerId: string | null = b.customerId ?? null;
        let customerName = 'Walk-in customer';
        const customers = await coll.customers();
        if (customerId) {
          const c = await customers.findOne({ _id: customerId }) as Record<string, unknown> | null;
          if (!c) throw new HttpErr(400, 'Unknown customer');
          customerName = String(c.name);
        } else if (b.customer && String(b.customer.name ?? '').trim().length > 1) {
          const doc = { name: String(b.customer.name).trim(), kind: 'individual', phone: String(b.customer.phone ?? ''), email: String(b.customer.email ?? ''), address: '', credit_balance: 0, created_by: user.uid, created_at: now() };
          const r = await customers.insertOne(doc);
          customerId = String(r.insertedId);
          customerName = doc.name;
        }

        const t = now();
        const sale = { customer_id: customerId, customer_name: customerName, customer_contact: String(b.customer_contact ?? ''), method, discount, total, items: lines, signed_by: user.uid, signed_name: user.name, customer_signature: String(b.customer_signature ?? ''), created_at: t };
        const saleOut = await (await coll.sales()).insertOne(sale);
        const txnOut = await (await coll.txns()).insertOne({ txn_type: 'salePayment', method, amount: total, reference: String(saleOut.insertedId), txn_date: t, created_by: user.uid });
        const recNo = 'MTK-REC-' + pad9(await nextSerial('receiptIssue'));
        await (await coll.receipts()).insertOne({ no: recNo, amount: total, method, source: 'sale', customer_id: customerId, customer_name: customerName, customer_contact: String(b.customer_contact ?? ''), issued_by: user.uid, issued_name: user.name, customer_signature: String(b.customer_signature ?? ''), txn_id: String(txnOut.insertedId), sale_id: String(saleOut.insertedId), created_at: t });
        let invoiceNo: string | null = null;
        if (method === 'credit' && customerId) {
          await customers.updateOne({ _id: customerId }, { $inc: { credit_balance: total } });
          invoiceNo = 'MTK-INV-' + pad9(await nextSerial('invoice'));
          await (await coll.invoices()).insertOne({ no: invoiceNo, customer_id: customerId, customer_name: customerName, status: 'sent', subtotal, vat: 0, total, amount_paid: 0, items: lines, issued_by: user.uid, created_at: t, updated_at: t });
        }
        await audit('billing', 'sale', recNo, user);
        return json({ ok: true, sale_id: String(saleOut.insertedId), total, receipt_no: recNo, invoice_no: invoiceNo }, 201);
      }

      case 'POST /api/invoices/pay': {
        const b = await req.json();
        await verifyPasscode(user, String(b.passcode ?? ''));
        const invoices = await coll.invoices();
        const inv = await invoices.findOne({ no: String(b.no ?? '') }) as Record<string, unknown> | null;
        if (!inv) throw new HttpErr(404, 'Invoice not found');
        const amount = Math.trunc(Number(b.amount) || 0);
        const balance = Number(inv.total) - Number(inv.amount_paid ?? 0);
        if (balance <= 0) throw new HttpErr(400, `${inv.no} is fully paid`);
        const pay = Math.min(amount > 0 ? amount : balance, balance);
        const method = ['cash', 'transfer', 'pos'].includes(b.method) ? b.method : 'transfer';
        const t = now();
        const upd = await invoices.updateOne(
          { no: String(inv.no), $expr: { $lte: ['$amount_paid', '$total'] } },
          { $inc: { amount_paid: pay }, $set: { status: Number(inv.amount_paid ?? 0) + pay >= Number(inv.total) ? 'paid' : 'partial', updated_at: t } });
        if (!upd.modifiedCount) throw new HttpErr(409, 'Payment raced another update — retry');
        const txnOut = await (await coll.txns()).insertOne({ txn_type: 'invoicePayment', method, amount: pay, reference: String(inv.no), txn_date: t, created_by: user.uid });
        const recNo = 'MTK-REC-' + pad9(await nextSerial('receiptIssue'));
        await (await coll.receipts()).insertOne({ no: recNo, amount: pay, method, source: 'invoice', invoice_no: inv.no, customer_id: inv.customer_id ?? null, customer_name: inv.customer_name ?? '—', customer_contact: String(b.customer_contact ?? ''), issued_by: user.uid, issued_name: user.name, txn_id: String(txnOut.insertedId), created_at: t });
        await (await coll.payments()).insertOne({ invoice_no: inv.no, amount: pay, method, receipt_no: recNo, created_by: user.uid, created_at: t });
        await audit('billing', 'invoice-payment', `${inv.no} ${pay}`, user);
        return json({ ok: true, receipt_no: recNo, status: Number(inv.amount_paid ?? 0) + pay >= Number(inv.total) ? 'paid' : 'partial' });
      }

      case 'POST /api/settings': {
        requireRole(user, ['ceo'], 'change settings or seed data');
        const b = await req.json();
        const set: Record<string, unknown> = {};
        if (typeof b.vatEnabled === 'boolean') set.vat_enabled = b.vatEnabled;
        if (typeof b.vatRate === 'number' && b.vatRate >= 0 && b.vatRate <= 0.5) set.vat_rate = b.vatRate;
        if (typeof b.watermark === 'boolean') set.watermark = b.watermark;
        const st = await coll.settings();
        if (Object.keys(set).length) await st.updateOne({ _id: 'settings' }, { $set: set });
        if (b.reseed && BOOK_TYPES.includes(b.reseed.type)) {
          const v = Math.trunc(Number(b.reseed.value));
          if (v < 0) throw new HttpErr(400, 'Invalid serial value');
          await (await coll.serials()).updateOne({ _id: b.reseed.type }, { $set: { last_used: v } }, { upsert: true });
        }
        await audit('core', 'settings', JSON.stringify({ ...set, reseed: b.reseed ?? null }), user);
        return json({ ok: true, settings: await st.findOne({ _id: 'settings' }), serials: await peekSerials() });
      }

      case 'POST /api/docs/issue': {
        requireRole(user, ['ceo', 'admin'], 'issue freehand documents');
        const b = await req.json();
        const type = ['receipt', 'invoice', 'mils', 'waybill', 'deliverynote'].includes(b.type) ? b.type : null;
        if (!type) throw new HttpErr(400, 'Unknown document type');
        await verifyPasscode(user, String(b.passcode ?? ''));
        const contact = String(b.contact ?? '');
        if (!contact && b.requireContact !== false) {
          // owner rule: every issued document carries a customer phone or email
          throw new HttpErr(400, 'Customer phone or email is required on every document');
        }
        const serial = await nextSerial(type);
        const record = {
          doc_type: type, serial, customer: String(b.customer ?? '—').slice(0, 120) || '—',
          customer_contact: contact, total: Number(b.total) || 0,
          signed_by: user.uid, signed_name: user.name,
          verify_hash: String(b.hash ?? '').slice(0, 64),
          filename: `mtek_${type}_${serial}_${Date.now()}.pdf`, issued_at: now(),
        };
        await (await coll.archive()).insertOne(record);
        await audit('documents', 'issue', `${type} ${pad9(serial)}`, user);
        return json({ serial, doc: record, serials: await peekSerials() });
      }
      case 'GET /api/docs/history': {
        const docs = await (await coll.archive()).find({}).sort({ issued_at: -1 }).limit(500).toArray();
        return json({ docs });
      }

      case 'GET /api/mils': {
        const q: Record<string, unknown> = {};
        for (const k of ['customer_id', 'customer_name', 'equipment']) {
          if (url.searchParams.get(k)) q[k] = url.searchParams.get(k);
        }
        const logs = await (await coll.mils()).find(q).sort({ created_at: -1 }).limit(500).toArray();
        return json({ logs });
      }
      case 'POST /api/mils': {
        requireRole(user, ['ceo', 'admin'], 'record MILS jobs');
        const b = await req.json();
        const doc = { ...b, mils_no: b.mils_no || 'MILS-' + pad9(await nextSerial('mils')), recorded_by: user.uid, recorded_name: user.name, created_at: now() };
        const out = await (await coll.mils()).insertOne(doc);
        await audit('mils', 'create', String(out.insertedId), user);
        return json({ ok: true, id: String(out.insertedId), mils_no: doc.mils_no, mils: doc }, 201);
      }

      case 'GET /api/audit': {
        if (user.role === 'sales') throw new HttpErr(403, 'Audit trail is management-only');
        const events = await (await coll.audit()).find({}).sort({ at: -1 }).limit(1000).toArray();
        return json({ events });
      }

      default:
        return err(404, 'Unknown API route');
    }
  } catch (e) {
    if (e instanceof HttpErr) return err(e.status, e.message);
    return err(500, String(e instanceof Error ? e.message : e));
  }
});
