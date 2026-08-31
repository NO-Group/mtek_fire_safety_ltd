// ============================================================================
// M-TEK DATA API — the real backend service.
//
// ARCHITECTURE (owner directive 2026-08-30):
//   · Supabase  = AUTH ONLY (GoTrue accounts, JWTs). No business tables.
//   · MongoDB   = ALL storage. ONE cluster (mfsl.w5ifd7x), one DATABASE per
//     section so data never entangles:
//       mtek_core      → serials, settings            (seedable: CEO only)
//       mtek_inventory → products, stock_adjustments  (edits: CEO/Admin)
//       mtek_people    → customers, profiles (role map)
//       mtek_billing   → sales, transactions, invoices, receipts, payments
//       mtek_mils      → MILS service logs
//       mtek_documents → issued-document archive
//       mtek_audit     → audit-trail events
//
// AUTH: every request carries `Authorization: Bearer <supabase-jwt>`. The JWT
// is validated against Supabase Auth; the caller's role comes from
// mtek_people.profiles (CEO is hardcoded to UID in backend/.env).
//
// SERIALS: every document book starts at 000000001 (9 digits, owner directive
// 2026-08-30). Counters are atomic (findOneAndUpdate $inc) and CEO-reseedable.
//
// RUN:  cd backend/api && npm install && npm start        (needs backend/.env)
// ============================================================================
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { MongoClient } = require('mongodb');

// ---- config -----------------------------------------------------------------
const ENV_PATH = path.join(__dirname, '..', '.env');
const env = Object.fromEntries(
  fs.existsSync(ENV_PATH)
    ? fs.readFileSync(ENV_PATH, 'utf8').split('\n')
        .filter(l => l.trim() && !l.trim().startsWith('#'))
        .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; })
    : [],
);
const PORT = process.env.PORT || 8090;
const SUPABASE_URL = env.SUPABASE_URL || '';
const SUPABASE_SECRET = env.SUPABASE_SECRET_KEY || '';
const CEO_UID = env.MTEK_CEO_UID || 'd9c7fd50-0a60-4a16-b4ab-041cb568a49b';
const CEO_EMAIL = 'mtekfiresafetyltd@gmail.com';
const CEO_SIG = env.MTEK_CEO_SIG || ''; // seeded into the profile as a hash

// ---- section databases (never entangled) ------------------------------------
const DB = {
  core: 'mtek_core',
  inventory: 'mtek_inventory',
  people: 'mtek_people',
  billing: 'mtek_billing',
  mils: 'mtek_mils',
  documents: 'mtek_documents',
  audit: 'mtek_audit',
};
const SECTION_DBS = Object.values(DB);

let client = null;
async function db(name) {
  if (!client) client = new MongoClient(env.MONGODB_URI, { appName: 'mtek-api' });
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

// ---- helpers ------------------------------------------------------------------
const httpErr = (status, message) => Object.assign(new Error(message), { status });
const json = (res, status, data) => {
  const buf = Buffer.from(JSON.stringify(data));
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': buf.length });
  res.end(buf);
};
function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', c => { raw += c; if (raw.length > 5e6) reject(httpErr(413, 'Payload too large')); });
    req.on('end', () => { try { resolve(raw ? JSON.parse(raw) : {}); } catch { reject(httpErr(400, 'Invalid JSON')); } });
    req.on('error', reject);
  });
}
const hashPass = (secret, salt) =>
  crypto.createHmac('sha512', 'mtek-store-salt').update(String(salt) + String(secret)).digest('hex');
const newSalt = () => crypto.randomBytes(8).toString('hex');
const pad9 = n => String(n).padStart(9, '0'); // 000000001 series (owner directive)

async function audit(section, action, ref, user) {
  try {
    (await coll.audit()).insertOne({
      section, action, ref: String(ref), by: user.uid, by_name: user.name,
      at: new Date().toISOString(),
    });
  } catch { /* auditing must never break the request */ }
}

// ---- auth: Supabase JWT → profile ---------------------------------------------
const profileCache = new Map(); // uid → {profile, expires}
async function auth(req) {
  const jwt = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!jwt) throw httpErr(401, 'Missing bearer token');
  let user;
  try {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SUPABASE_SECRET, Authorization: `Bearer ${jwt}` },
    });
    if (!r.ok) throw httpErr(401, 'Invalid or expired token');
    user = await r.json();
  } catch (e) {
    if (e.status) throw e;
    throw httpErr(503, 'Auth service unreachable — try again shortly');
  }
  return ensureProfile(user);
}

async function ensureProfile(user) {
  const profiles = await coll.profiles();
  const cached = profileCache.get(user.id);
  if (cached && Date.now() < cached.expires) return cached.value;

  let p = await profiles.findOne({ _id: user.id });
  if (!p) {
    const isCeo = user.id === CEO_UID || String(user.email || '').toLowerCase() === CEO_EMAIL;
    p = {
      _id: user.id,
      email: String(user.email || '').toLowerCase(),
      full_name: user.user_metadata?.full_name || (isCeo ? 'CEO' : String(user.email || 'staff').split('@')[0]),
      role: isCeo ? 'ceo' : 'sales', // hardcoded CEO (never self-promoted)
      sig_salt: newSalt(),
      sig_hash: isCeo && CEO_SIG ? hashPass(CEO_SIG, newSalt()) : null,
      // NOTE: CEO sig_hash is re-seeded deterministically in seed-core (below)
      created_at: new Date().toISOString(),
    };
    if (isCeo && CEO_SIG) p.sig_hash = hashPass(CEO_SIG, p.sig_salt);
    await profiles.insertOne(p);
  } else if ((user.id === CEO_UID || String(user.email || '').toLowerCase() === CEO_EMAIL) && p.role !== 'ceo') {
    await profiles.updateOne({ _id: user.id }, { $set: { role: 'ceo' } });
    p.role = 'ceo'; // the CEO identity is locked by hardcode
  }
  const value = { uid: user.id, email: p.email, name: p.full_name, role: p.role, sig_hash: p.sig_hash, sig_salt: p.sig_salt };
  profileCache.set(user.id, { value, expires: Date.now() + 60_000 });
  return value;
}

function requireRole(user, roles, what) {
  if (!roles.includes(user.role)) {
    throw httpErr(403, roles.length === 1 && roles[0] === 'ceo'
      ? `Only the CEO can ${what}`
      : `Only CEO or Admin can ${what}`);
  }
}

async function verifyPasscode(user, passcode) {
  if (!passcode) throw httpErr(403, 'Not signed — passcode required');
  if (user.sig_hash && user.sig_salt &&
      hashPass(passcode, user.sig_salt) === user.sig_hash) return;
  // profile has no hash yet (account created before seeding) → allow the
  // configured CEO signature to bind the account once, then persist it
  if (!user.sig_hash && CEO_SIG && passcode === CEO_SIG && user.role === 'ceo') {
    const salt = user.sig_salt || newSalt();
    await (await coll.profiles()).updateOne(
      { _id: user.uid }, { $set: { sig_salt: salt, sig_hash: hashPass(CEO_SIG, salt) } });
    profileCache.delete(user.uid);
    return;
  }
  throw httpErr(403, 'Signature passcode does not match — action NOT authorised');
}

// ---- serial counters (atomic; every book starts at 000000001) ----------------
const BOOK_TYPES = ['receiptIssue', 'receipt', 'invoice', 'mils', 'waybill', 'deliverynote'];
async function ensureCore() {
  const s = await coll.serials();
  await s.updateOne({ _id: 'seeded' }, { $setOnInsert: { seeded: true, at: new Date().toISOString() } }, { upsert: true });
  for (const t of BOOK_TYPES) {
    await s.updateOne({ _id: t }, { $setOnInsert: { last_used: 0 } }, { upsert: true });
  }
  const st = await coll.settings();
  await st.updateOne({ _id: 'settings' }, { $setOnInsert: { vat_enabled: false, vat_rate: 0.075, watermark: true } }, { upsert: true });
}
async function nextSerial(type) {
  const s = await coll.serials();
  const out = await s.findOneAndUpdate(
    { _id: type }, { $inc: { last_used: 1 } }, { returnDocument: 'after', upsert: true });
  return out.last_used;
}
async function peekSerials() {
  const s = await coll.serials();
  const rows = await s.find({}).toArray();
  const out = {};
  for (const r of rows) if (r._id !== 'seeded') out[r._id] = r.last_used || 0;
  return out;
}

// ---- routing --------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const route = `${req.method} ${url.pathname}`;
  try {
    // landing page (browser-checkable — no bash needed)
    if (route === 'GET /' ) {
      const buf = Buffer.from(`<!DOCTYPE html><html><head><title>M-TEK Data API</title>
<style>body{font-family:system-ui,sans-serif;background:#0b1224;color:#e7edf7;display:grid;place-items:center;min-height:100vh;margin:0}
main{text-align:center;max-width:560px;padding:40px}h1{letter-spacing:1px}img{width:120px;height:120px;border-radius:50%;background:#fff;padding:8px}
code{background:#16213c;padding:2px 8px;border-radius:6px}ul{text-align:left;line-height:1.9}</style></head><body><main>
<img src="/logo.png" alt="M-Tek seal"><h1>M-TEK Data API</h1>
<p>Supabase = auth only · MongoDB = all storage (7 section databases)</p>
<ul><li><code>GET /health</code> — live status + serial counters</li>
<li>Serial books start at <b>000000001</b></li>
<li>Authority: stock edits = CEO/Admin · seeding = CEO only</li></ul>
<p style="color:#7f8ea8">POST endpoints require a Supabase JWT (Authorization: Bearer …)</p>
</main></body></html>`, 'utf8');
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': buf.length });
      return res.end(buf);
    }
    if (route === 'GET /logo.png') {
      const png = fs.readFileSync(path.join(__dirname, '..', '..', 'assets', 'logo', 'mtek_logo.png'));
      res.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': png.length });
      return res.end(png);
    }

    // health (no auth — also proves Mongo reachability)
    if (route === 'GET /health') {
      try {
        await ensureCore();
        return json(res, 200, { ok: true, databases: SECTION_DBS, serials: await peekSerials() });
      } catch (e) {
        return json(res, 503, { ok: false, error: `MongoDB unreachable — ${e.message.slice(0, 120)}`, databases: SECTION_DBS });
      }
    }

    const user = await auth(req);

    switch (route) {
      // ------------------------------------------------ profile / bootstrap
      case 'GET /api/me': {
        return json(res, 200, { user: { uid: user.uid, email: user.email, name: user.name, role: user.role } });
      }
      case 'GET /api/bootstrap': {
        await ensureCore();
        const [products, customers, settings, serials, txns, receipts, invoices, docs] = await Promise.all([
          (await coll.products()).find({}).sort({ name: 1 }).limit(1000).toArray(),
          (await coll.customers()).find({}).sort({ name: 1 }).limit(1000).toArray(),
          (await coll.settings()).findOne({ _id: 'settings' }),
          peekSerials(),
          (await coll.txns()).find({}).sort({ txn_date: -1 }).limit(300).toArray(),
          (await coll.receipts()).find({}).sort({ created_at: -1 }).limit(300).toArray(),
          (await coll.invoices()).find({}).sort({ created_at: -1 }).limit(300).toArray(),
          (await coll.archive()).find({}).sort({ issued_at: -1 }).limit(100).toArray(),
        ]);
        return json(res, 200, {
          user: { uid: user.uid, email: user.email, name: user.name, role: user.role },
          products, customers, transactions: txns, receipts, invoices, docs,
          settings: { vat_enabled: settings.vat_enabled, vat_rate: settings.vat_rate, watermark: settings.watermark },
          serials,
        });
      }

      // ------------------------------------------------ signature passcode
      case 'POST /api/auth/signature': {
        const body = await readBody(req);
        await verifyPasscode(user, String(body.passcode || ''));
        return json(res, 200, { ok: true, user: { uid: user.uid, name: user.name, role: user.role } });
      }

      // ------------------------------------------------ customers (any staff)
      case 'POST /api/customers': {
        const b = await readBody(req);
        if (!b.name || String(b.name).trim().length < 2) throw httpErr(400, 'Customer name required');
        const doc = {
          name: String(b.name).trim().slice(0, 120),
          kind: b.corp || b.kind === 'corporate' ? 'corporate' : 'individual',
          phone: String(b.phone || ''), email: String(b.email || ''), address: String(b.address || ''),
          credit_balance: 0, created_by: user.uid, created_at: new Date().toISOString(),
        };
        const out = await (await coll.customers()).insertOne(doc);
        await audit('customers', 'create', out.insertedId, user);
        return json(res, 201, { customer: { ...doc, _id: out.insertedId } });
      }

      // ------------------------------------------------ products (CEO/Admin)
      case 'POST /api/products/upsert': {
        requireRole(user, ['ceo', 'admin'], 'edit stock / import products');
        const b = await readBody(req);
        const rows = Array.isArray(b.products) ? b.products : [b];
        const products = await coll.products();
        let upserted = 0;
        for (const r of rows) {
          if (!r.id || !r.name) continue;
          await products.updateOne({ _id: String(r.id) }, {
            $set: {
              name: String(r.name), category: r.category || 'Fire',
              cost_price: Number(r.cost_price) || 0, selling_price: Number(r.selling_price) || 0,
              qty_on_hand: Math.max(0, Math.trunc(Number(r.qty_on_hand) || 0)),
              reorder_level: Math.max(0, Math.trunc(Number(r.reorder_level) || 0)),
              unit: r.unit || 'unit', is_service: !!r.is_service, updated_at: new Date().toISOString(),
            },
          }, { upsert: true });
          upserted++;
        }
        await audit('inventory', 'upsert', `${upserted} products`, user);
        return json(res, 200, { ok: true, upserted });
      }

      // ------------------------------------------------ stock adjust (CEO/Admin)
      case 'POST /api/stock/adjust': {
        requireRole(user, ['ceo', 'admin'], 'edit stock');
        const b = await readBody(req);
        const delta = Math.trunc(Number(b.delta) || 0);
        if (!delta) throw httpErr(400, 'Quantity change required');
        const products = await coll.products();
        const guarded = await products.updateOne(
          { _id: String(b.id), $expr: { $gte: [{ $add: ['$qty_on_hand', delta] }, 0] } },
          { $inc: { qty_on_hand: delta }, $set: { updated_at: new Date().toISOString() } });
        if (!guarded.matchedCount) throw httpErr(400, 'Unknown product or adjustment would drive stock negative');
        const adj = {
          product_id: String(b.id), delta, reason: String(b.reason || 'CORRECTION'),
          note: String(b.note || ''), by: user.uid, by_name: user.name, created_at: new Date().toISOString(),
        };
        await (await coll.adjustments()).insertOne(adj);
        await audit('inventory', 'adjust', `${b.id} ${delta > 0 ? '+' : ''}${delta}`, user);
        return json(res, 200, { ok: true, adjustment: adj });
      }

      // ------------------------------------------------ complete sale (atomic)
      case 'POST /api/sales': {
        const b = await readBody(req);
        await verifyPasscode(user, String(b.passcode || ''));
        const items = Array.isArray(b.items) ? b.items : [];
        if (!items.length) throw httpErr(400, 'Cart is empty');
        const method = ['cash', 'transfer', 'pos', 'credit'].includes(b.method) ? b.method : 'cash';
        const products = await coll.products();

        // server-side pricing + atomic stock guards
        const lines = [];
        let subtotal = 0;
        for (const it of items) {
          const p = await products.findOne({ _id: String(it.product_id) });
          if (!p) throw httpErr(400, `Unknown product ${it.product_id}`);
          const qty = Math.trunc(Number(it.qty) || 0);
          if (qty <= 0) throw httpErr(400, 'Invalid quantity');
          if (!p.is_service) {
            const g = await products.updateOne(
              { _id: p._id, qty_on_hand: { $gte: qty } },
              { $inc: { qty_on_hand: -qty }, $set: { updated_at: new Date().toISOString() } });
            if (!g.modifiedCount) throw httpErr(400, `Only ${p.qty_on_hand} ${p.unit} of ${p.name} in stock`);
          }
          subtotal += p.selling_price * qty;
          lines.push({ product_id: p._id, name: p.name, qty, unit_price: p.selling_price });
        }
        const discount = Math.max(0, Math.trunc(Number(b.discount) || 0));
        const total = Math.max(subtotal - discount, 0);

        // resolve customer (existing id, inline new, or walk-in)
        let customerId = b.customerId || null, customerName = 'Walk-in customer';
        const customers = await coll.customers();
        if (customerId) {
          const c = await customers.findOne({ _id: customerId });
          if (!c) throw httpErr(400, 'Unknown customer');
          customerName = c.name;
        } else if (b.customer && String(b.customer.name || '').trim().length > 1) {
          const doc = {
            name: String(b.customer.name).trim(), kind: 'individual', phone: String(b.customer.phone || ''),
            email: '', address: '', credit_balance: 0, created_by: user.uid, created_at: new Date().toISOString(),
          };
          const r = await customers.insertOne(doc);
          customerId = String(r.insertedId); customerName = doc.name;
        }

        const now = new Date().toISOString();
        const sale = {
          customer_id: customerId, customer_name: customerName, method, discount, total,
          items: lines, signed_by: user.uid, signed_name: user.name,
          customer_signature: String(b.customer_signature || ''), created_at: now,
        };
        const saleOut = await (await coll.sales()).insertOne(sale);

        const txn = {
          txn_type: 'salePayment', method, amount: total, reference: String(saleOut.insertedId),
          txn_date: now, created_by: user.uid,
        };
        const txnOut = await (await coll.txns()).insertOne(txn);

        const recNo = 'MTK-REC-' + pad9(await nextSerial('receiptIssue'));
        const receipt = {
          no: recNo, amount: total, method, source: 'sale',
          customer_id: customerId, customer_name: customerName,
          issued_by: user.uid, issued_name: user.name,
          customer_signature: String(b.customer_signature || ''),
          txn_id: String(txnOut.insertedId), sale_id: String(saleOut.insertedId), created_at: now,
        };
        await (await coll.receipts()).insertOne(receipt);

        if (method === 'credit' && customerId) {
          await customers.updateOne({ _id: customerId }, { $inc: { credit_balance: total } });
          const invNo = 'MTK-INV-' + pad9(await nextSerial('invoice'));
          await (await coll.invoices()).insertOne({
            no: invNo, customer_id: customerId, customer_name: customerName, status: 'sent',
            subtotal, vat: 0, total, amount_paid: 0, items: lines,
            issued_by: user.uid, created_at: now, updated_at: now,
          });
        }
        await audit('billing', 'sale', recNo, user);
        return json(res, 201, { ok: true, sale_id: String(saleOut.insertedId), total, receipt_no: recNo });
      }

      // ------------------------------------------------ invoice payment
      case 'POST /api/invoices/pay': {
        const b = await readBody(req);
        await verifyPasscode(user, String(b.passcode || ''));
        const invoices = await coll.invoices();
        const inv = await invoices.findOne({ no: String(b.no || '') });
        if (!inv) throw httpErr(404, 'Invoice not found');
        const amount = Math.trunc(Number(b.amount) || 0);
        const balance = inv.total - (inv.amount_paid || 0);
        if (balance <= 0) throw httpErr(400, `${inv.no} is fully paid`);
        const pay = Math.min(amount > 0 ? amount : balance, balance);
        const method = ['cash', 'transfer', 'pos'].includes(b.method) ? b.method : 'transfer';
        const now = new Date().toISOString();

        const upd = await invoices.updateOne(
          { no: inv.no, $expr: { $lte: ['$amount_paid', '$total'] } },
          { $inc: { amount_paid: pay }, $set: {
            status: (inv.amount_paid || 0) + pay >= inv.total ? 'paid' : 'partial', updated_at: now } });
        if (!upd.modifiedCount) throw httpErr(409, 'Payment raced another update — retry');

        const txnOut = await (await coll.txns()).insertOne({
          txn_type: 'invoicePayment', method, amount: pay, reference: inv.no, txn_date: now, created_by: user.uid,
        });
        const recNo = 'MTK-REC-' + pad9(await nextSerial('receiptIssue'));
        await (await coll.receipts()).insertOne({
          no: recNo, amount: pay, method, source: 'invoice', invoice_no: inv.no,
          customer_id: inv.customer_id || null, customer_name: inv.customer_name || '—',
          issued_by: user.uid, issued_name: user.name, txn_id: String(txnOut.insertedId), created_at: now,
        });
        await (await coll.payments()).insertOne({
          invoice_no: inv.no, amount: pay, method, receipt_no: recNo, created_by: user.uid, created_at: now,
        });
        await audit('billing', 'invoice-payment', `${inv.no} ₦${pay}`, user);
        return json(res, 200, { ok: true, receipt_no: recNo,
          status: (inv.amount_paid || 0) + pay >= inv.total ? 'paid' : 'partial' });
      }

      // ------------------------------------------------ settings / reseed (CEO)
      case 'POST /api/settings': {
        requireRole(user, ['ceo'], 'change settings or seed data');
        const b = await readBody(req);
        const set = {};
        if (typeof b.vatEnabled === 'boolean') set.vat_enabled = b.vatEnabled;
        if (typeof b.vatRate === 'number' && b.vatRate >= 0 && b.vatRate <= 0.5) set.vat_rate = b.vatRate;
        if (typeof b.watermark === 'boolean') set.watermark = b.watermark;
        const st = await coll.settings();
        if (Object.keys(set).length) await st.updateOne({ _id: 'settings' }, { $set: set });
        if (b.reseed && BOOK_TYPES.includes(b.reseed.type)) {
          const v = Math.trunc(Number(b.reseed.value));
          if (v < 0) throw httpErr(400, 'Invalid serial value');
          await (await coll.serials()).updateOne(
            { _id: b.reseed.type }, { $set: { last_used: v } }, { upsert: true });
        }
        await audit('core', 'settings', JSON.stringify({ ...set, reseed: b.reseed || null }), user);
        return json(res, 200, { ok: true, settings: await st.findOne({ _id: 'settings' }), serials: await peekSerials() });
      }

      // ------------------------------------------------ documents (CEO/Admin)
      case 'POST /api/docs/issue': {
        requireRole(user, ['ceo', 'admin'], 'issue freehand documents');
        const b = await readBody(req);
        const type = ['receipt', 'invoice', 'mils', 'waybill', 'deliverynote'].includes(b.type) ? b.type : null;
        if (!type) throw httpErr(400, 'Unknown document type');
        await verifyPasscode(user, String(b.passcode || ''));
        const serial = await nextSerial(type);
        const record = {
          doc_type: type, serial,
          customer: String(b.customer || '—').slice(0, 120) || '—',
          total: Number(b.total) || 0,
          signed_by: user.uid, signed_name: user.name,
          verify_hash: String(b.hash || '').slice(0, 64),
          filename: `mtek_${type}_${serial}_${Date.now()}.pdf`,
          issued_at: new Date().toISOString(),
        };
        await (await coll.archive()).insertOne(record);
        await audit('documents', 'issue', `${type} ${pad9(serial)}`, user);
        return json(res, 200, { serial, doc: record, serials: await peekSerials() });
      }
      case 'GET /api/docs/history': {
        const docs = await (await coll.archive()).find({}).sort({ issued_at: -1 }).limit(500).toArray();
        return json(res, 200, { docs });
      }

      // ------------------------------------------------ MILS (CEO/Admin write)
      case 'GET /api/mils': {
        const q = {};
        for (const k of ['customer_id', 'customer_name', 'equipment']) {
          if (url.searchParams.get(k)) q[k] = url.searchParams.get(k);
        }
        const logs = await (await coll.mils()).find(q).sort({ entry_date: -1 }).limit(500).toArray();
        return json(res, 200, { logs });
      }
      case 'POST /api/mils': {
        requireRole(user, ['ceo', 'admin'], 'record MILS jobs');
        const b = await readBody(req);
        const doc = {
          ...b, mils_no: b.mils_no || 'MILS-' + pad9(await nextSerial('mils')),
          recorded_by: user.uid, recorded_name: user.name, created_at: new Date().toISOString(),
        };
        const out = await (await coll.mils()).insertOne(doc);
        await audit('mils', 'create', String(out.insertedId), user);
        return json(res, 201, { ok: true, id: String(out.insertedId), mils_no: doc.mils_no });
      }

      // ------------------------------------------------ audit (management read)
      case 'GET /api/audit': {
        if (user.role === 'sales') throw httpErr(403, 'Audit trail is management-only');
        const events = await (await coll.audit()).find({}).sort({ at: -1 }).limit(1000).toArray();
        return json(res, 200, { events });
      }

      default:
        return json(res, 404, { error: 'Unknown API route' });
    }
  } catch (e) {
    json(res, e.status || 500, { error: e.message });
  }
});

if (require.main === module) {
  server.listen(PORT, '0.0.0.0', () => {
    console.log(`M-TEK DATA API → :${PORT}`);
    console.log(`  Supabase (auth only): ${SUPABASE_URL || 'NOT CONFIGURED'}`);
    console.log(`  MongoDB sections:     ${SECTION_DBS.join(', ')}`);
    console.log(`  Serial books start at 000000001 (9-digit, owner directive)`);
  });
}
module.exports = { server, coll, ensureCore, nextSerial, peekSerials, pad9, DB, SECTION_DBS };
