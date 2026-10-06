import { useEffect, useMemo, useRef, useState } from "react";

import {
  highlightToFragment,
  parseStyleAttr,
  useSiteHighlighter,
} from "../utils/shikiHighlighter";
import { copyTextToClipboard } from "../utils/clipboard";
import { FunCompileError, runEditedCode } from "../utils/compileInBrowser";

type Props = {
  initialCode: string;
  title?: string;
};

type RunResponse = {
  ok: boolean;
  stdout?: string;
  stderr?: string;
  error?: string;
};

type RunOutcome = { stdout: string; stderr: string };

// Matches `prebake-wasm.mjs`'s own `hashCode`: trimmed and CRLF-normalized,
// so this component's react-markdown-derived text and that script's
// regex-derived text don't have to be byte-identical, just the same
// *content*, before hashing.
async function hashCode(code: string): Promise<string> {
  const normalized = code.replace(/\r\n/g, "\n").trim();
  const bytes = new TextEncoder().encode(normalized);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// Runs a pre-baked wasm module (built by `prebake-wasm.mjs`, see #189) for
// `hash` entirely client-side - no backend at all. The module is emscripten's
// own default (non-modularized) output: it auto-runs on load, reading
// `print`/`printErr`/`onExit`/`onAbort` off a pre-existing global `Module`
// object when one is set before the script loads (`var Module = typeof
// Module != "undefined" ? Module : {}` at the top of every such file) -
// the classic, well-supported emscripten integration pattern, chosen over
// `-sMODULARIZE` specifically so the artifact `prebake-wasm.mjs` already
// produces (and already verified working end to end, #189) needs no
// compile-flag changes here.
//
// Each run gets its own fresh, throwaway iframe rather than injecting the
// script into the main document - confirmed necessary directly, not just
// a defensive choice: the module's own top-level `class`/`let`/`const`
// declarations (an internal emscripten helper, `EmscriptenEH`, among
// others) persist in whatever global lexical scope they first execute
// in, even after the `<script>` tag that declared them is removed from
// the DOM - a real, unrelated-to-this-project browser platform
// limitation, not something `-sMODULARIZE` or any compile flag changes.
// Loading a second module (or re-running the same one) into the shared
// main-document scope throws "Identifier already declared" instead of
// running. A fresh iframe is a fresh JS realm every time, so this can
// never collide, regardless of which example ran there before.
//
// Rejects (falling back to the backend, or the "nothing available"
// message) when no module exists for this hash - a 404 is the normal,
// expected case for any edited or non-pre-baked code.
async function runWasm(hash: string): Promise<RunOutcome> {
  const base = import.meta.env.BASE_URL || "/";
  const src = `${base}wasm/${hash}.js`;
  const stdoutLines: string[] = [];
  const stderrLines: string[] = [];

  return new Promise<RunOutcome>((resolve, reject) => {
    let settled = false;

    const iframe = document.createElement("iframe");
    iframe.style.display = "none";
    document.body.appendChild(iframe);

    const cleanup = () => {
      window.clearTimeout(timeoutId);
      // Deferred, not immediate: `onExit` fires from inside emscripten's
      // own exit-handling code, which can still touch `Module` itself a
      // moment later in the same tick (its own pthread-worker teardown,
      // observed directly) - tearing the iframe down synchronously here
      // raced that, producing a real (if harmless) console error. A
      // zero-delay timeout runs after the current callstack unwinds,
      // giving that a chance to finish first.
      window.setTimeout(() => iframe.remove(), 0);
    };
    const finish = () => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve({ stdout: stdoutLines.join("\n"), stderr: stderrLines.join("\n") });
    };
    const fail = (reason: Error) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(reason);
    };

    const timeoutId = window.setTimeout(
      () => fail(new Error("Timed out waiting for the wasm module to finish.")),
      15000,
    );

    const iframeWindow = iframe.contentWindow as any;
    const iframeDocument = iframe.contentDocument;
    if (!iframeWindow || !iframeDocument) {
      fail(new Error("Could not create an isolated frame to run the module in."));
      return;
    }

    iframeWindow.Module = {
      print: (line: string) => stdoutLines.push(line),
      printErr: (line: string) => stderrLines.push(line),
      onExit: () => finish(),
      onAbort: (what: unknown) => fail(new Error(String(what))),
    };

    const script = iframeDocument.createElement("script");
    script.src = src;
    script.onerror = () => fail(new Error("No pre-baked wasm module for this example."));
    iframeDocument.body.appendChild(script);
  });
}

export default function RunCodeBlock({ initialCode, title }: Props) {
  const [code, setCode] = useState(initialCode.trimEnd());
  const [stdout, setStdout] = useState("");
  const [stderr, setStderr] = useState("");
  const [isRunning, setIsRunning] = useState(false);
  const [hasRun, setHasRun] = useState(false);
  const [copyStatus, setCopyStatus] = useState<"idle" | "ok" | "err">("idle");
  const editorRef = useRef<HTMLTextAreaElement | null>(null);
  const previewRef = useRef<HTMLPreElement | null>(null);
  const configuredApiBase = (import.meta.env.VITE_RUN_API_BASE ?? "")
    .trim()
    .replace(/\/+$/, "");
  const runEndpoint = configuredApiBase
    ? `${configuredApiBase}/api/run`
    : "/api/run";
  const isGithubPages =
    typeof window !== "undefined" &&
    window.location.hostname.endsWith("github.io");
  // A pre-baked wasm module only ever exists for the example's own
  // original text (see `prebake-wasm.mjs`) - an edit means there's
  // nothing to look up, only the backend (if any) can run it.
  const isUnedited = code === initialCode.trimEnd();
  const backendUnavailable = isGithubPages && configuredApiBase === "";

  const runViaBackend = async (): Promise<RunOutcome> => {
    const res = await fetch(runEndpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
    });
    const data = (await res.json()) as RunResponse;
    return { stdout: data.stdout ?? "", stderr: data.error ?? data.stderr ?? "" };
  };

  const run = async () => {
    setIsRunning(true);
    setHasRun(true);
    setStdout("");
    setStderr("");
    try {
      if (isUnedited) {
        try {
          const hash = await hashCode(initialCode);
          const outcome = await runWasm(hash);
          setStdout(outcome.stdout);
          setStderr(outcome.stderr);
          return;
        } catch {
          // No pre-baked module for this example (or it failed to load/
          // run) - fall through to the backend below.
        }
      } else {
        try {
          const outcome = await runEditedCode(code);
          setStdout(outcome.stdout);
          setStderr(outcome.stderr);
          return;
        } catch (e) {
          if (e instanceof FunCompileError) {
            // The authoritative answer - a live backend would reject
            // the same program the same way, so there's nothing to
            // gain by falling through to one.
            setStderr(e.message);
            return;
          }
          // An infrastructure failure (a module failed to load, a
          // timeout, the in-browser C compiler itself choked) - fall
          // through to the backend below, same as an unedited example
          // without a pre-baked module does.
        }
      }
      if (backendUnavailable) {
        setStderr(
          isUnedited
            ? "This example has no pre-baked offline version and there is no backend API available to run it. Run the site locally, or set up a remote runner API (see project README)."
            : "Could not run this in your browser and there is no backend API available to fall back to. Run the site locally, or set up a remote runner API (see project README).",
        );
        return;
      }
      const outcome = await runViaBackend();
      setStdout(outcome.stdout);
      setStderr(outcome.stderr);
    } catch (e: any) {
      setStderr(e?.message ?? "Request failed");
    } finally {
      setIsRunning(false);
    }
  };

  const copyCode = async () => {
    try {
      await copyTextToClipboard(code);
      setCopyStatus("ok");
    } catch {
      setCopyStatus("err");
    }
    window.setTimeout(() => setCopyStatus("idle"), 1600);
  };

  const highlighter = useSiteHighlighter();
  const highlighted = useMemo(() => {
    if (!highlighter) return null;
    return highlightToFragment(highlighter, code, "fun");
  }, [highlighter, code]);
  const lineCount = useMemo(() => code.split("\n").length, [code]);
  const lineNumbers = useMemo(
    () => Array.from({ length: lineCount }, (_, i) => i + 1).join("\n"),
    [lineCount],
  );

  // The overlay `pre` and the real (invisible) `textarea` sit in the
  // same CSS grid cell (`.run-surface`'s `grid-area: 1 / 1` on both),
  // so the grid row's height always equals its tallest child. Growing
  // the textarea to fit its own content - no fixed height, no internal
  // scroll, no manual resize handle - is what keeps the two perfectly
  // aligned: a mismatch here (resizing one without the other) is
  // exactly what used to make the caret look like it landed somewhere
  // other than where you clicked or typed.
  useEffect(() => {
    const ta = editorRef.current;
    if (!ta) return;
    ta.style.height = "auto";
    ta.style.height = `${ta.scrollHeight}px`;
  }, [code]);

  return (
    <div className="run-block">
      <div className="run-editor">
        <div className="run-gutter" aria-hidden>
          {lineNumbers}
        </div>
        <div className="run-surface">
          <pre
            ref={previewRef}
            aria-hidden
            className={highlighted ? "shiki" : undefined}
            style={highlighted ? parseStyleAttr(highlighted.style) : undefined}
          >
            {highlighted ? (
              <code dangerouslySetInnerHTML={{ __html: highlighted.innerHtml }} />
            ) : (
              <code>{code}</code>
            )}
          </pre>
          <textarea
            ref={editorRef}
            value={code}
            onChange={(e) => setCode(e.target.value)}
            spellCheck={false}
            wrap="soft"
            aria-label={title ?? "Runnable Fun code"}
          />
        </div>
        <div className="run-actions">
          <button
            onClick={copyCode}
            className="ghost"
            type="button"
            title="Copy code"
          >
            {copyStatus === "ok"
              ? "Copied"
              : copyStatus === "err"
                ? "Copy failed"
                : "Copy"}
          </button>
          <button
            onClick={() => setCode(initialCode.trimEnd())}
            className="ghost"
            type="button"
          >
            Reset
          </button>
          <button onClick={run} disabled={isRunning} type="button">
            {isRunning ? "Running..." : "Run"}
          </button>
        </div>
      </div>
      {hasRun && (
        <div className="output-grid">
          <div>
            <div className="output-title">stdout</div>
            <pre>{stdout || "(empty)"}</pre>
          </div>
          <div>
            <div className="output-title">stderr</div>
            <pre className={stderr ? "err" : ""}>{stderr || "(empty)"}</pre>
          </div>
        </div>
      )}
    </div>
  );
}
