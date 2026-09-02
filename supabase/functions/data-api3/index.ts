// bisect3: first 60 of 259 top lines, cut at 'async function db(name: string) {'
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
Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/functions\/v1\/[^/]+/, '') || '/';
  if (path === '/' || path === '/health') {
    return json({ ok: true, version: 'bisect3-60', cut: 60, of: 259 });
  }
  return err(503, 'bisect3');
});
