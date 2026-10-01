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

  self.addEventListener("fetch", (event) => {
    const request = event.request;
    if (request.cache === "only-if-cached" && request.mode !== "same-origin") return;

    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response.status === 0) return response;
          const headers = new Headers(response.headers);
          headers.set("Cross-Origin-Embedder-Policy", "require-corp");
          headers.set("Cross-Origin-Opener-Policy", "same-origin");
          return new Response(response.body, {
            status: response.status,
            statusText: response.statusText,
            headers,
          });
        })
        .catch((error) => console.error("coi-serviceworker fetch failed:", error)),
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
