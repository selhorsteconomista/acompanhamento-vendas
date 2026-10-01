// Service worker: guarda a "casca" do app para abrir rápido e instalar como aplicativo.
// Os dados de vendas sempre vêm do Supabase e nunca ficam neste cache.
const CACHE = 'vendas-v1';
const SHELL = ['./', 'index.html', 'config.js', 'manifest.webmanifest', 'favicon.svg', 'icon-192.png', 'icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co') || url.hostname.endsWith('supabase.in') || url.hostname.includes('ibge.gov.br')) return;
  const sameOrigin = url.origin === self.location.origin;
  const cdn = /cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com|fonts\.(googleapis|gstatic)\.com/.test(url.hostname);
  if (sameOrigin) {
    // Rede primeiro: publica atualizações na hora; usa o cache só sem internet.
    e.respondWith(fetch(req).then(r => { const c = r.clone(); caches.open(CACHE).then(x => x.put(req, c)); return r; })
      .catch(() => caches.match(req).then(r => r || caches.match('index.html'))));
  } else if (cdn) {
    e.respondWith(caches.match(req).then(hit => {
      const net = fetch(req).then(r => { const c = r.clone(); caches.open(CACHE).then(x => x.put(req, c)); return r; }).catch(() => hit);
      return hit || net;
    }));
  }
});
