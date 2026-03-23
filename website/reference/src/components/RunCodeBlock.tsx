import { useMemo, useRef, useState } from "react";

import { highlightFun } from "../utils/funHighlight";

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

export default function RunCodeBlock({ initialCode, title }: Props) {
  const [code, setCode] = useState(initialCode.trimEnd());
  const [stdout, setStdout] = useState("");
  const [stderr, setStderr] = useState("");
  const [isRunning, setIsRunning] = useState(false);
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
  const runtimeDisabled = isGithubPages && configuredApiBase === "";

  const run = async () => {
    if (runtimeDisabled) {
      setStdout("");
      setStderr(
        "Runtime execution is disabled on GitHub Pages because there is no backend API available to run code. To use the Run button, run the site locally or set up a remote runner API (see project README).",
      );
      return;
    }

    setIsRunning(true);
    setStdout("");
    setStderr("");
    try {
      const res = await fetch(runEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code }),
      });
      const data = (await res.json()) as RunResponse;
      setStdout(data.stdout ?? "");
      setStderr(data.error ?? data.stderr ?? "");
    } catch (e: any) {
      setStderr(e?.message ?? "Request failed");
    } finally {
      setIsRunning(false);
    }
  };

  const highlighted = useMemo(() => highlightFun(code), [code]);
  const syncScroll = () => {
    if (!editorRef.current || !previewRef.current) return;
    previewRef.current.scrollTop = editorRef.current.scrollTop;
    previewRef.current.scrollLeft = editorRef.current.scrollLeft;
  };

  return (
    <div className="run-block">
      <div className="run-block-header">
        <strong>{title ?? "Runnable Example"}</strong>
        <div className="run-actions">
          <button
            onClick={() => setCode(initialCode.trimEnd())}
            className="ghost"
            disabled={runtimeDisabled}
            title={
              runtimeDisabled
                ? "Reset is disabled on GitHub Pages because code execution is not available."
                : undefined
            }
            style={
              runtimeDisabled ? { opacity: 0.6, cursor: "not-allowed" } : {}
            }
          >
            Reset
          </button>
          <button
            onClick={run}
            disabled={isRunning || runtimeDisabled}
            title={
              runtimeDisabled
                ? "Run is disabled on GitHub Pages because there is no backend API available to run code. To use the Run button, run the site locally or set up a remote runner API (see project README)."
                : undefined
            }
            style={
              runtimeDisabled ? { opacity: 0.6, cursor: "not-allowed" } : {}
            }
          >
            {isRunning ? "Running..." : "Run"}
          </button>
        </div>
      </div>
      <div className="run-editor">
        <pre ref={previewRef} aria-hidden>
          <code>{highlighted}</code>
        </pre>
        <textarea
          ref={editorRef}
          value={code}
          onChange={(e) => setCode(e.target.value)}
          onScroll={syncScroll}
          spellCheck={false}
        />
      </div>
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
    </div>
  );
}
