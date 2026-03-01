import { useState } from "react";

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
        "Runtime execution is disabled on GitHub Pages unless VITE_RUN_API_BASE is configured. Run locally with `npm run dev`, or set VITE_RUN_API_BASE to a hosted runner API.",
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

  return (
    <div className="run-block">
      <div className="run-block-header">
        <strong>{title ?? "Runnable Example"}</strong>
        <div className="run-actions">
          <button
            onClick={() => setCode(initialCode.trimEnd())}
            className="ghost"
          >
            Reset
          </button>
          <button onClick={run} disabled={isRunning}>
            {isRunning ? "Running..." : "Run"}
          </button>
        </div>
      </div>
      <textarea
        value={code}
        onChange={(e) => setCode(e.target.value)}
        spellCheck={false}
      />
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
