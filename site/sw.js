// humibeam Service Worker — Offline-Schale für die statischen Seiten.
// API-Aufrufe (/humibeam-*) werden NIE gecacht (immer Netzwerk).
const CACHE = 'humibeam-v1';
const SHELL = [
  '/', '/account/', '/support/', '/status/',
  '/account/app.js', '/account/crypto.js',
  '/icon.svg', '/manifest.webmanifest',
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()).catch(() => {}));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  const url = new URL(req.url);
  // Nur eigene Origin, nur GET. APIs immer live.
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  if (url.pathname.startsWith('/humibeam-')) return;

  // Navigationen: Netzwerk zuerst, Cache als Fallback (offline).
  if (req.mode === 'navigate') {
    e.respondWith(
      fetch(req).then((res) => { cachePut(req, res.clone()); return res; })
        .catch(() => caches.match(req).then((m) => m || caches.match('/')))
    );
    return;
  }
  // Statische Assets: Cache zuerst, dann Netzwerk (und nachladen).
  e.respondWith(
    caches.match(req).then((m) => m || fetch(req).then((res) => { cachePut(req, res.clone()); return res; }).catch(() => m))
  );
});

function cachePut(req, res) {
  if (res && res.ok && res.type === 'basic') caches.open(CACHE).then((c) => c.put(req, res)).catch(() => {});
}
