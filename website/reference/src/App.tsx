import { useEffect, useMemo, useState } from "react";
import data from "./generated/content.json";
import MarkdownWithPlayground from "./components/MarkdownWithPlayground";
import RunCodeBlock from "./components/RunCodeBlock";

type DocsSections = {
  params: string[];
  returns: string[];
  fields: string[];
  usage: string[];
  examples: string[];
  notes: string[];
};

type DocsMeta = {
  summary: string;
  description: string;
  raw: string;
  sections: DocsSections;
  example: string;
};

type StdSymbol = {
  kind: string;
  name: string;
  signature: string;
  line: number;
  docs: DocsMeta;
  docsMarkdown: string;
};

type StdModule = {
  module: string;
  summary: string;
  docs: DocsMeta;
  docsMarkdown: string;
  symbols: StdSymbol[];
};

type ReferenceContent = {
  generatedAt: string;
  funVersion: string;
  docs: {
    language: string;
    reference: string;
    stdlibReadme: string;
  };
  stdlib: StdModule[];
  samples: Array<{ title: string; code: string }>;
};

const content = data as ReferenceContent;

type TabKey = "language" | "reference" | "stdlib" | "playground";

const TABS: Array<{ key: TabKey; label: string }> = [
  { key: "language", label: "Language Guide" },
  { key: "reference", label: "Reference" },
  { key: "stdlib", label: "Std Library" },
  { key: "playground", label: "Playground" },
];

function parseStdlibHash(hash: string) {
  const value = hash.startsWith("#") ? hash.slice(1) : hash;
  const [route, query = ""] = value.split("?");
  if (route !== "stdlib") {
    return null;
  }
  const params = new URLSearchParams(query);
  return {
    modulePath: params.get("module") ?? "",
    symbolKey: params.get("symbol") ?? "",
  };
}

function buildStdlibHash(modulePath: string, symbolKey: string) {
  const params = new URLSearchParams();
  if (modulePath) params.set("module", modulePath);
  if (symbolKey) params.set("symbol", symbolKey);
  const query = params.toString();
  return query ? `#stdlib?${query}` : "#stdlib";
}

function parseTabHash(hash: string): TabKey | null {
  const value = hash.startsWith("#") ? hash.slice(1) : hash;
  const [route] = value.split("?");
  if (route === "language") return "language";
  if (route === "reference") return "reference";
  if (route === "playground") return "playground";
  if (route === "stdlib") return "stdlib";
  return null;
}

function getInitialHashState() {
  if (typeof window === "undefined") {
    return {
      tab: "language" as TabKey,
      modulePath: "",
      symbolKey: "",
    };
  }

  const tabFromHash = parseTabHash(window.location.hash);
  if (tabFromHash && tabFromHash !== "stdlib") {
    return {
      tab: tabFromHash,
      modulePath: "",
      symbolKey: "",
    };
  }

  const parsed = parseStdlibHash(window.location.hash);
  if (parsed) {
    return {
      tab: "stdlib" as TabKey,
      modulePath: parsed.modulePath,
      symbolKey: parsed.symbolKey,
    };
  }

  return {
    tab: "language" as TabKey,
    modulePath: "",
    symbolKey: "",
  };
}

export default function App() {
  const initial = getInitialHashState();
  const [tab, setTab] = useState<TabKey>(initial.tab);
  const [search, setSearch] = useState("");
  const [selectedModulePath, setSelectedModulePath] = useState(
    initial.modulePath,
  );
  const [selectedSymbolKey, setSelectedSymbolKey] = useState(initial.symbolKey);
  const [copyStatus, setCopyStatus] = useState<"idle" | "ok" | "err">("idle");

  const filteredModules = useMemo(() => {
    const q = search.toLowerCase().trim();
    if (!q) return content.stdlib;
    return content.stdlib.filter((m) => {
      if (m.module.toLowerCase().includes(q)) return true;
      if (m.summary.toLowerCase().includes(q)) return true;
      if ((m.docsMarkdown ?? "").toLowerCase().includes(q)) return true;
      return m.symbols.some(
        (s) =>
          s.name.toLowerCase().includes(q) ||
          s.signature.toLowerCase().includes(q) ||
          (s.docsMarkdown ?? "").toLowerCase().includes(q),
      );
    });
  }, [search]);

  const activeModule = useMemo(() => {
    if (filteredModules.length === 0) return null;
    if (selectedModulePath) {
      const found = filteredModules.find(
        (m) => m.module === selectedModulePath,
      );
      if (found) return found;
    }
    return filteredModules[0];
  }, [filteredModules, selectedModulePath]);

  const activeSymbol = useMemo(() => {
    if (!activeModule || activeModule.symbols.length === 0) return null;
    if (selectedSymbolKey) {
      const found = activeModule.symbols.find(
        (s) => `${s.name}:${s.line}` === selectedSymbolKey,
      );
      if (found) return found;
    }
    return activeModule.symbols[0];
  }, [activeModule, selectedSymbolKey]);

  useEffect(() => {
    if (typeof window === "undefined") return;

    const applyHash = () => {
      const tabFromHash = parseTabHash(window.location.hash);
      if (tabFromHash && tabFromHash !== "stdlib") {
        setTab(tabFromHash);
        return;
      }

      const parsed = parseStdlibHash(window.location.hash);
      if (!parsed) return;
      setTab("stdlib");
      setSearch("");
      setSelectedModulePath(parsed.modulePath);
      setSelectedSymbolKey(parsed.symbolKey);
    };

    applyHash();
    window.addEventListener("hashchange", applyHash);
    return () => window.removeEventListener("hashchange", applyHash);
  }, []);

  useEffect(() => {
    if (typeof window === "undefined") return;

    if (tab !== "stdlib") {
      const nextHash = `#${tab}`;
      if (window.location.hash !== nextHash) {
        const nextUrl = `${window.location.pathname}${window.location.search}${nextHash}`;
        window.history.replaceState(null, "", nextUrl);
      }
      return;
    }

    const modulePath = activeModule?.module ?? "";
    const symbolKey = activeSymbol
      ? `${activeSymbol.name}:${activeSymbol.line}`
      : "";
    const nextHash = buildStdlibHash(modulePath, symbolKey);

    if (window.location.hash !== nextHash) {
      const nextUrl = `${window.location.pathname}${window.location.search}${nextHash}`;
      window.history.replaceState(null, "", nextUrl);
    }
  }, [tab, activeModule, activeSymbol]);

  const copyStdlibLink = async () => {
    if (typeof window === "undefined") return;
    if (!activeModule) return;

    const symbolKey = activeSymbol
      ? `${activeSymbol.name}:${activeSymbol.line}`
      : "";
    const hash = buildStdlibHash(activeModule.module, symbolKey);
    const url = `${window.location.origin}${window.location.pathname}${window.location.search}${hash}`;

    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(url);
      } else {
        const textArea = document.createElement("textarea");
        textArea.value = url;
        textArea.setAttribute("readonly", "true");
        textArea.style.position = "absolute";
        textArea.style.left = "-9999px";
        document.body.appendChild(textArea);
        textArea.select();
        document.execCommand("copy");
        document.body.removeChild(textArea);
      }
      setCopyStatus("ok");
    } catch {
      setCopyStatus("err");
    }

    window.setTimeout(() => {
      setCopyStatus("idle");
    }, 1500);
  };

  return (
    <div className="app-shell">
      <aside>
        <div className="brand">Fun Language Reference</div>
        <p className="muted">Interactive docs + local runner</p>
        <nav>
          {TABS.map((t) => (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              className={tab === t.key ? "active" : ""}
            >
              {t.label}
            </button>
          ))}
        </nav>
        <div className="meta muted">Fun v{content.funVersion}</div>
        <div className="meta muted">
          Generated {new Date(content.generatedAt).toLocaleString()}
        </div>
      </aside>

      <main>
        {tab === "language" && (
          <section className="panel">
            <h1>Language Features</h1>
            <p className="lead">
              This page is sourced from docs/language.md and includes runnable
              Fun code blocks.
            </p>
            <MarkdownWithPlayground
              markdown={content.docs.language}
              sourcePath="docs/language.md"
            />
          </section>
        )}

        {tab === "reference" && (
          <section className="panel">
            <h1>Comprehensive Reference</h1>
            <p className="lead">
              Syntax, semantics, runtime behavior, and interop details.
            </p>
            <MarkdownWithPlayground
              markdown={content.docs.reference}
              sourcePath="docs/reference.md"
            />
          </section>
        )}

        {tab === "stdlib" && (
          <section className="panel">
            <h1>Standard Library Explorer</h1>
            <p className="lead">
              Click a module, then click a symbol to inspect docs and examples
              parsed from source comments.
            </p>
            <input
              className="search"
              placeholder="Search module, symbol, signature, docs..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />

            {activeModule && (
              <section className="detail-card detail-card-sticky">
                <div className="detail-head">
                  <h2>std/{activeModule.module.replace(/\.fn$/, "")}</h2>
                  <button className="copy-link-btn" onClick={copyStdlibLink}>
                    {copyStatus === "ok"
                      ? "Copied"
                      : copyStatus === "err"
                        ? "Copy failed"
                        : "Copy link"}
                  </button>
                </div>
                <p className="muted">
                  Click a symbol below to view signature docs and examples.
                </p>
                {activeModule.docsMarkdown ? (
                  <MarkdownWithPlayground
                    markdown={activeModule.docsMarkdown}
                    sourcePath={`stdlib/std/${activeModule.module}`}
                  />
                ) : (
                  <p className="muted">No module-level docs found.</p>
                )}

                <div className="symbol-pills">
                  {activeModule.symbols.map((s) => {
                    const key = `${s.name}:${s.line}`;
                    return (
                      <a
                        key={key}
                        className={`symbol-pill ${
                          activeSymbol &&
                          activeSymbol.name === s.name &&
                          activeSymbol.line === s.line
                            ? "active"
                            : ""
                        }`}
                        href={buildStdlibHash(activeModule.module, key)}
                        onClick={() => setSelectedSymbolKey(key)}
                      >
                        <span className="badge">{s.kind}</span>
                        <span>{s.name}</span>
                      </a>
                    );
                  })}
                </div>

                {activeSymbol && (
                  <article className="symbol-detail">
                    <h3>
                      {activeSymbol.name}{" "}
                      <span className="muted">(line {activeSymbol.line})</span>
                    </h3>
                    <pre>
                      <code>{activeSymbol.signature}</code>
                    </pre>
                    {activeSymbol.docsMarkdown ? (
                      <MarkdownWithPlayground
                        markdown={activeSymbol.docsMarkdown}
                        sourcePath={`stdlib/std/${activeModule.module}`}
                      />
                    ) : (
                      <p className="muted">
                        No comment docs found above this declaration.
                      </p>
                    )}
                  </article>
                )}
              </section>
            )}

            <div className="stdlib-grid">
              {filteredModules.map((m) => (
                <article
                  key={m.module}
                  className={`module-card ${
                    activeModule?.module === m.module ? "active" : ""
                  }`}
                >
                  <a
                    className="module-select"
                    href={buildStdlibHash(m.module, "")}
                    onClick={() => {
                      setSelectedModulePath(m.module);
                      setSelectedSymbolKey("");
                    }}
                  >
                    <div className="module-title">
                      std/{m.module.replace(/\.fn$/, "")}
                    </div>
                  </a>
                  <div className="module-summary">
                    {m.summary || "No summary found."}
                  </div>
                  <ul>
                    {m.symbols.length === 0 ? (
                      <li className="muted">No public declarations</li>
                    ) : (
                      m.symbols.slice(0, 6).map((s) => (
                        <li key={`${m.module}:${s.name}:${s.line}`}>
                          <a
                            className={`symbol-row ${
                              activeModule?.module === m.module &&
                              activeSymbol &&
                              activeSymbol.name === s.name &&
                              activeSymbol.line === s.line
                                ? "active"
                                : ""
                            }`}
                            href={buildStdlibHash(
                              m.module,
                              `${s.name}:${s.line}`,
                            )}
                            onClick={() => {
                              setSelectedModulePath(m.module);
                              setSelectedSymbolKey(`${s.name}:${s.line}`);
                            }}
                          >
                            <span className="badge">{s.kind}</span>
                            <code>{s.signature}</code>
                          </a>
                        </li>
                      ))
                    )}
                  </ul>
                  {m.symbols.length > 6 && (
                    <div className="muted small">
                      +{m.symbols.length - 6} more symbols
                    </div>
                  )}
                </article>
              ))}
            </div>
          </section>
        )}

        {tab === "playground" && (
          <section className="panel">
            <h1>Interactive Playground</h1>
            <p className="lead">
              Edit and run snippets locally with your real Fun compiler.
            </p>
            <div className="hint">
              Requires zig-out/bin/fun. If missing, run zig build in repo root
              first.
            </div>
            {content.samples.map((s) => (
              <RunCodeBlock
                key={s.title}
                title={s.title}
                initialCode={s.code}
              />
            ))}
            <details>
              <summary>Raw stdlib docs source</summary>
              <MarkdownWithPlayground
                markdown={content.docs.stdlibReadme}
                sourcePath="stdlib/README.md"
              />
            </details>
          </section>
        )}
      </main>
    </div>
  );
}
