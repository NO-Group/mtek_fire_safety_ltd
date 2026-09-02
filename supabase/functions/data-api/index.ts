// CANARY (bisect): minimal function to test whether deployments activate at
// all. No imports, no MongoDB. If /health returns version canary-1 the
// runtime activates bundles; if it still answers like the old bundle, the
// project's deployment routing is stuck at the platform level.
const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
};
Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/functions\/v1\/data-api/, '') || '/';
  if (req.method === 'GET' && (path === '/' || path === '/health' || path === '/health/')) {
    return new Response(
      JSON.stringify({ ok: true, version: 'canary-1', note: 'minimal bisect build' }),
      { headers: { ...CORS, 'Content-Type': 'application/json' } });
  }
  return new Response(
    JSON.stringify({ error: 'canary build — real backend temporarily disabled for diagnosis' }),
    { status: 503, headers: { ...CORS, 'Content-Type': 'application/json' } });
});
