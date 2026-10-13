// GitHub Pages serves static files only - it cannot set the
// `Cross-Origin-Opener-Policy`/`Cross-Origin-Embedder-Policy` response
// headers the in-browser C-to-wasm compiler (`@wasmer/sdk`) requires to
// use `SharedArrayBuffer`. Confirmed directly, not assumed: without
// those headers, `window.crossOriginIsolated` is false and the SDK
// refuses outright ("You can only run packages from 'Cross-Origin
// Isolated' websites"), it does not just lose an optimization.
//
// This file is loaded twice, for two different roles, distinguished by
// `typeof window`: once as a classic `<script>` in the page itself
// (registers the service worker below), and once by the browser as the
// service worker's own script (intercepts every fetch this origin
// makes and adds the two headers to the response). A freshly installed
// service worker does not control the page that registered it until
// the next navigation, so the page reloads itself once right after the
// worker activates - the one unavoidable extra round trip this
// technique costs.
if (typeof window === "undefined") {
  self.addEventListener("install", () => self.skipWaiting());
  self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

  // The Playground's own wasm modules (the compiler frontend, fls, and
  // every pre-baked example) - large, and immutable once fetched: each
  // one's URL already carries its build's own content hash as a `?v=`
  // query param (see `compileInBrowser.ts`'s own `manifestHash`), so the
  // exact same URL can only ever resolve to the exact same bytes. Cached
  // here, across page loads *and* across deployments (a new deployment
  // changes the hash, so its own URLs are a natural cache miss - nothing
  // to invalidate by hand), rather than left to the regular HTTP cache,
  // which is the first thing evicted under storage pressure for
  // anything this large. `manifest.json` itself is excluded - it has no
  // hash of its own (it's what *provides* the hash everything else
  // uses) and the app already fetches it with `cache: "no-store"` for
  // exactly that reason.
  const ASSET_CACHE = "fun-wasm-assets-v1";
  const isVersionedAsset = (pathname) =>
    /\/(wasm|wasm-frontend|wasm-fls)\//.test(pathname) &&
    !pathname.endsWith("manifest.json");

  const withCoiHeaders = (response) => {
    if (response.status === 0) return response;
    const headers = new Headers(response.headers);
    headers.set("Cross-Origin-Embedder-Policy", "require-corp");
    headers.set("Cross-Origin-Opener-Policy", "same-origin");
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  };

  const fetchWithCoiHeaders = (request) =>
    fetch(request)
      .then(withCoiHeaders)
      .catch((error) => {
        console.error("coi-serviceworker fetch failed:", error);
        throw error;
      });

  const cacheFirst = async (request) => {
    const cache = await caches.open(ASSET_CACHE);
    const cached = await cache.match(request);
    if (cached) return cached;
    const response = await fetchWithCoiHeaders(request);
    if (response.ok) {
      cache.put(request, response.clone());
    }
    return response;
  };

  self.addEventListener("fetch", (event) => {
    const request = event.request;
    if (request.cache === "only-if-cached" && request.mode !== "same-origin") return;

    const pathname = new URL(request.url).pathname;
    event.respondWith(
      request.method === "GET" && isVersionedAsset(pathname)
        ? cacheFirst(request)
        : fetchWithCoiHeaders(request),
    );
  });
} else {
  (() => {
    if (window.crossOriginIsolated) return;
    if (!navigator.serviceWorker) {
      console.error("Cross-origin isolation unavailable: this browser has no Service Worker support.");
      return;
    }

    navigator.serviceWorker.register(window.document.currentScript.src).then(
      (registration) => {
        registration.addEventListener("updatefound", () => window.location.reload());
        if (registration.active && !navigator.serviceWorker.controller) {
          window.location.reload();
        }
      },
      (error) => console.error("coi-serviceworker registration failed:", error),
    );
  })();
}
