# Fun Language Reference Website

Interactive local website for the Fun language with:

- Full language + reference docs rendered from repository markdown
- Standard library explorer generated from `stdlib/std/**/*.fn`
- Editable runnable code blocks (for `fun` fenced code)
- Local API runner that executes snippets using your real `fun` compiler

## Prerequisites

- Node.js 20+
- The Fun compiler binary at `fun-out/bin/fun`
  - from repo root, run: `fun build`

## Development

From `website/reference`:

```bash
npm install
npm run dev
```

This starts:

- Web UI: http://localhost:5173
- Run API: http://localhost:8787

## Build + Production Run

```bash
npm run build
npm run start
```

The server serves API and static frontend from `dist`.

## Deep links

The UI supports URL hash links for direct navigation:

- `#language`
- `#reference`
- `#playground`
- `#stdlib?module=<path>&symbol=<name:line>`

Example stdlib deep link:

- `#stdlib?module=string.fn&symbol=len:109`

When browsing the Std Library tab, the hash updates automatically so module/symbol views are shareable.

## How snippet execution works

The browser posts code to `/api/run`, the server writes a temp `.fn` file, and invokes:

- `fun-out/bin/fun -in <temp-file>`

The process runs with `FUN_STDLIB_DIR` pointed at repo `stdlib/` so std imports resolve consistently.

## Multi-file snippets

Runnable `fun` code blocks can define multiple files using markers:

```fun
// file: main.fn
imp mod1 as one;

fun main() {
  num v = one.pick();
  _ = v;
}

// file: mod1.fn
pub fun pick() num { ret 7; }
```

- Each marker starts a new file at the given path (relative, must end in `.fn`).
- The runner executes `main.fn` if present; otherwise it uses the first file.

## Remote runtime API (optional)

By default, the frontend calls `/api/run` (works with local `npm run dev` proxy/server).

For static hosting (like GitHub Pages), you can enable runnable blocks by setting:

- `VITE_RUN_API_BASE=https://<your-runner-host>`

Then the frontend sends execution requests to:

- `https://<your-runner-host>/api/run`

If `VITE_RUN_API_BASE` is not set on `github.io`, the Run button remains visible but execution is disabled with an explanatory message.
