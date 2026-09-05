/* Caches the app shell so the portal opens instantly and still opens
   with a bad connection. Supabase calls are never cached: a balance
   must always be the live one. */

const CACHE = 'bms-shell-v8';
const SHELL = [
  './', './index.html', './manifest.json', './config.js',
  './assets/app.css', './assets/icon.svg', './vendor/supabase.js',
  './core/app.js', './core/ui.js', './core/db.js', './core/store.js',
  './core/router.js', './core/i18n.js', './core/xlsx.js', './core/layout.js',
  './modules/dashboard.js', './modules/flats.js', './modules/charges.js',
  './modules/finance.js', './modules/bank.js', './modules/reports.js',
  './modules/users.js', './modules/audit.js', './modules/settings.js',
  './modules/assets.js', './modules/generator.js', './modules/lift.js',
  './modules/fire.js', './modules/maintenance.js', './modules/staff.js',
  './modules/salary.js', './modules/work.js', './modules/mosque.js',
  './modules/reserve.js', './modules/budget.js', './modules/reconcile.js'
];

self.addEventListener('install', (e) => {
  self.skipWaiting();
  e.waitUntil((async () => {
    const c = await caches.open(CACHE);
    await Promise.all(SHELL.map(u => c.add(u).catch(() => {})));
  })());
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  const sameOrigin = url.origin === self.location.origin;

  // NEVER cache data. Anything that is not a static file belonging to this
  // app goes straight to the network — a balance, a permission or a ledger
  // row served from a cache would be worse than an error message.
  //
  // The check is "is this a static asset of ours", not "is this Supabase":
  // a host-name test breaks the moment the API moves to another domain,
  // and it would fail silently, with stale money on the screen.
  const STATIC = /\.(?:html|css|js|mjs|json|png|svg|webp|woff2?)$/i;
  const isApi  = /^\/(rest|auth|storage|realtime|functions)\b/.test(url.pathname);
  const isStaticAsset = sameOrigin && !isApi &&
        (STATIC.test(url.pathname) || url.pathname === '/' || url.pathname.endsWith('/'));

  if (!isStaticAsset && !(req.mode === 'navigate' || req.destination === 'document')){
    e.respondWith(fetch(req).catch(() => new Response(
      JSON.stringify({ message: 'You appear to be offline.' }),
      { status: 503, headers: { 'Content-Type':'application/json' } })));
    return;
  }

  // App shell: network first so a deploy is picked up, cache as fallback.
  if (req.mode === 'navigate' || req.destination === 'document'){
    e.respondWith((async () => {
      try {
        const fresh = await fetch(req);
        (await caches.open(CACHE)).put('./index.html', fresh.clone());
        return fresh;
      } catch {
        const c = await caches.open(CACHE);
        return (await c.match('./index.html')) || (await c.match('./')) ||
               new Response('Offline', { status: 503 });
      }
    })());
    return;
  }

  // Static assets only: cache first, refreshed in the background.
  e.respondWith((async () => {
    const c = await caches.open(CACHE);
    const hit = await c.match(req);
    const net = fetch(req).then(r => { if (r.ok) c.put(req, r.clone()); return r; }).catch(() => null);
    return hit || (await net) || new Response('', { status: 503 });
  })());
});
