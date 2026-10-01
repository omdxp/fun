import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { copyFileSync, mkdirSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

// `@wasmer/sdk` has two separate groups of files Vite's bundler never
// resolves, both confirmed directly against a real production build
// served under the real GitHub Pages subpath (a local dev-server run
// never catches either: dev mode serves anything under `node_modules`
// on demand, masking exactly this gap):
//
// 1. `browser-worker.js` (its web worker entry point, loaded at
//    runtime via `new Worker(...)`, not through Vite's ordinary static
//    module graph) statically imports four sibling files of its own
//    (`node-compat.js`, `host-filesystem.js`, `node-network-rpc.js`,
//    `capi-worker-bridge.js`) - real, unconditionally-needed
//    dependencies (symbol-portability shims, the host filesystem
//    bridge, and so on), not anything to tree-shake away. Each
//    reference is the unhashed literal name (`"./node-compat.js"`).
// 2. `dist/index.js` imports its wasm-bindgen glue from
//    `../pkg/wasmer_sdk_js.js` (outside `dist/`, so Vite does bundle
//    this one into the main graph) - but that glue file itself
//    imports `./snippets/wasmer-napi-<hash>/inline0.js` (a dynamic
//    `eval`/import-rewriting helper, plus its own `acorn.mjs`
//    dependency), which Vite leaves as an unbundled relative import.
//
// Both leave the built site requesting a file that was never copied
// into `dist/`, a real 404 (or, server-side meaning wrong-content
// "`<!doctype`" HTML fallback) at runtime. Copying the SDK's own files
// to the same relative paths these chunks already reference is a
// stable fix, not tied to any particular build's own hash.
const WASMER_WORKER_DEPS = [
  "node-compat.js",
  "host-filesystem.js",
  "node-network-rpc.js",
  "capi-worker-bridge.js",
];

const WASMER_SNIPPETS_DIR = "snippets/wasmer-napi-4dc421676e010b84";

function copyWasmerWorkerDeps(): Plugin {
  return {
    name: "copy-wasmer-worker-deps",
    closeBundle() {
      for (const name of WASMER_WORKER_DEPS) {
        const src = fileURLToPath(
          new URL(`node_modules/@wasmer/sdk/dist/${name}`, import.meta.url),
        );
        copyFileSync(src, `dist/assets/${name}`);
      }

      const snippetsSrcDir = fileURLToPath(
        new URL(`node_modules/@wasmer/sdk/pkg/${WASMER_SNIPPETS_DIR}`, import.meta.url),
      );
      const snippetsOutDir = `dist/assets/${WASMER_SNIPPETS_DIR}`;
      mkdirSync(snippetsOutDir, { recursive: true });
      for (const name of readdirSync(snippetsSrcDir)) {
        copyFileSync(`${snippetsSrcDir}/${name}`, `${snippetsOutDir}/${name}`);
      }
    },
  };
}

export default defineConfig({
  base: process.env.VITE_BASE_PATH ?? "/",
  plugins: [react(), copyWasmerWorkerDeps()],
  server: {
    port: 5173,
    proxy: {
      "/api": "http://localhost:8787",
    },
  },
});
