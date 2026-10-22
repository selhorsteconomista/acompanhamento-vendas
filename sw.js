// Service worker da Tintomax: guarda a "casca" do app para abrir rápido e permitir instalar no celular.
// Os dados de vendas sempre vêm do Supabase e nunca ficam neste cache.
// Ao publicar uma mudança grande no app, troque o número da versão abaixo (v2 -> v3...).
const CACHE = 'tintomax-v3';
const SHELL = [
  './', 'index.html', 'config.js', 'manifest.webmanifest',
  'favicon.svg', 'logo.png', 'apple-touch-icon.png',
  'icon-192.png', 'icon-512.png', 'icon-maskable-512.png'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Supabase (login e dados) e IBGE: sempre direto na internet, nunca do cache.
  if (/supabase\.(co|in)$/.test(url.hostname) || url.hostname.includes('ibge.gov.br')) return;

  const sameOrigin = url.origin === self.location.origin;
  const cdn = /cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com|fonts\.(googleapis|gstatic)\.com/.test(url.hostname);
  const guardar = r => { if (r && r.ok) { const c = r.clone(); caches.open(CACHE).then(x => x.put(req, c)); } return r; };

  if (sameOrigin) {
    // Arquivos do app: internet primeiro (atualizações aparecem na hora); cache só quando estiver offline.
    e.respondWith(
      // no-cache: sempre confere com o servidor se há versão nova (o GitHub Pages guarda cópias por até 10 min).
      fetch(req, { cache: 'no-cache' }).then(guardar)
        .catch(() => caches.match(req).then(r => r || caches.match('index.html')))
    );
  } else if (cdn) {
    // Bibliotecas e fontes: usa o cache e atualiza em segundo plano.
    e.respondWith(caches.match(req).then(hit => {
      const net = fetch(req).then(guardar).catch(() => hit);
      return hit || net;
    }));
  }
});
