const CACHE_NAME = 'cycle-reminder-pwa-v4';
const APP_ASSETS = [
  './',
  './index.html',
  './reset.html',
  './styles.css',
  './app.js',
  './manifest.webmanifest',
  './icon.svg',
];
const APP_ASSET_URLS = new Set(APP_ASSETS.map((asset) => new URL(asset, self.location).href));

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_ASSETS)));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then(async (keys) => {
        const staleKeys = keys.filter((key) => key !== CACHE_NAME);
        await Promise.all(staleKeys.map((key) => caches.delete(key)));
        await self.clients.claim();

        if (staleKeys.length === 0) {
          return;
        }

        const windowClients = await self.clients.matchAll({ type: 'window' });
        await Promise.all(
          windowClients.map((client) => {
            if ('navigate' in client) {
              return client.navigate(client.url).catch(() => undefined);
            }

            return undefined;
          }),
        );
      }),
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') {
    return;
  }

  const requestUrl = new URL(event.request.url);
  if (requestUrl.origin !== self.location.origin) {
    return;
  }

  if (event.request.mode === 'navigate' || APP_ASSET_URLS.has(requestUrl.href)) {
    event.respondWith(networkFirst(event.request));
    return;
  }

  event.respondWith(caches.match(event.request).then((cached) => cached || fetch(event.request)));
});

async function networkFirst(request) {
  const cache = await caches.open(CACHE_NAME);

  try {
    const response = await fetch(request);
    if (response.ok) {
      await cache.put(request, response.clone());
    }

    return response;
  } catch {
    return (await caches.match(request)) || caches.match('./index.html');
  }
}

self.addEventListener('message', (event) => {
  if (event.data?.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
