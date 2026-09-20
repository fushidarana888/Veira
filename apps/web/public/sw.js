const CACHE_NAME = 'veira-static-v2'

self.addEventListener('install', () => {
  self.skipWaiting()
})

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys
          .filter((key) => key.startsWith('veira-static-') && key !== CACHE_NAME)
          .map((key) => caches.delete(key)),
      ))
      .then(() => self.clients.claim()),
  )
})

self.addEventListener('fetch', (event) => {
  const request = event.request
  if (request.method !== 'GET') return

  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return

  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then(async (response) => {
          if (response.ok) {
            const cache = await caches.open(CACHE_NAME)
            await cache.put(request, response.clone())
          }
          return response
        })
        .catch(async () => {
          const cached = await caches.match(request)
          return cached || Response.error()
        }),
    )
    return
  }

  const immutableAsset = url.pathname.includes('/assets/')
  const imageAsset = /\.(?:webp|png|jpe?g|svg|gif|woff2?)$/i.test(url.pathname)
  if (!immutableAsset && !imageAsset) return

  event.respondWith(
    caches.open(CACHE_NAME).then(async (cache) => {
      const cached = await cache.match(request)

      if (immutableAsset) {
        if (cached) return cached
        const response = await fetch(request)
        if (response.ok) await cache.put(request, response.clone())
        return response
      }

      const networkUpdate = fetch(request)
        .then(async (response) => {
          if (response.ok) await cache.put(request, response.clone())
          return response
        })
        .catch(() => null)

      if (cached) {
        event.waitUntil(networkUpdate)
        return cached
      }

      return (await networkUpdate) || Response.error()
    }),
  )
})
