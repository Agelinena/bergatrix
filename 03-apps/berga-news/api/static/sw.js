// Minimal service worker — enables PWA installability
// Network-first: always fetches fresh content, no offline cache
self.addEventListener('fetch', e => {
  e.respondWith(fetch(e.request).catch(() => caches.match(e.request)));
});
