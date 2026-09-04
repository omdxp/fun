import { useEffect, useMemo, useRef, useState } from "react";

import MarkdownWithPlayground from "./components/MarkdownWithPlayground";
import RunCodeBlock from "./components/RunCodeBlock";
import HighlightedCode from "./components/HighlightedCode";
import { copyTextToClipboard } from "./utils/clipboard";
import { getSiteHighlighter } from "./utils/shikiHighlighter";
import bundledContentUrl from "./generated/content.json?url";

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

type StdField = {
  name: string;
  type: string;
  signature: string;
  line: number;
  docs: DocsMeta;
  docsMarkdown: string;
  inlineDoc?: string;
};

type StdSymbol = {
  kind: string;
  name: string;
  signature: string;
  line: number;
  owner?: string;
  fields?: StdField[];
  members?: StdField[];
  variants?: StdField[];
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
  versions?: {
    latest: string;
    available: string[];
  };
  docs: {
    getStarted: string;
    language: string;
    concurrency: string;
    tooling: string;
    platforms: string;
    stdlibReadme: string;
  };
  stdlib: StdModule[];
  samples: Array<{ title: string; code: string }>;
};

type VersionsIndex = {
  latest: string;
  available: string[];
};

type GlobalSearchResult = {
  id: string;
  title: string;
  subtitle: string;
  group: "docs" | "stdlib" | "samples";
  tab: TabKey;
  modulePath?: string;
  symbolKey?: string;
  detailKey?: string;
  docAnchorKey?: string;
};

type DocSection = {
  id: string;
  title: string;
  level: number;
  content: string;
  tab: DocTabKey;
};

type TocHeading = {
  id: string;
  title: string;
  level: number;
};

const DEFAULT_FUN_VERSION = "0.0.0";

const EMPTY_CONTENT: ReferenceContent = {
  generatedAt: new Date().toISOString(),
  funVersion: DEFAULT_FUN_VERSION,
  versions: {
    latest: DEFAULT_FUN_VERSION,
    available: [DEFAULT_FUN_VERSION],
  },
  docs: {
    getStarted: "",
    language: "",
    concurrency: "",
    tooling: "",
    platforms: "",
    stdlibReadme: "",
  },
  stdlib: [],
  samples: [],
};

type DocTabKey =
  | "getStarted"
  | "language"
  | "concurrency"
  | "tooling"
  | "platforms";
type TabKey = DocTabKey | "stdlib" | "playground";

function withBasePath(relativePath: string) {
  const base = import.meta.env.BASE_URL || "/";
  const normalizedBase = base.endsWith("/") ? base : `${base}/`;
  const normalizedPath = relativePath.replace(/^\/+/, "");
  return `${normalizedBase}${normalizedPath}`;
}

const isGithubPages =
  typeof window !== "undefined" &&
  window.location.hostname.endsWith("github.io");
const DOC_TABS: Array<{
  key: DocTabKey;
  navLabel: string;
  title: string;
  lead: string;
  sourcePath: string;
}> = [
  {
    key: "getStarted",
    navLabel: "Get Started",
    title: "Get Started",
    lead: "Install Fun, scaffold a project with fun init, and run your first program.",
    sourcePath: "docs/get-started.md",
  },
  {
    key: "language",
    navLabel: "Language",
    title: "Language",
    lead: "Syntax, types, control flow, and everything else the language surface covers.",
    sourcePath: "docs/language.md",
  },
  {
    key: "concurrency",
    navLabel: "Concurrency",
    title: "Concurrency",
    lead: "Async/await, virtual threads with fork, and channels.",
    sourcePath: "docs/concurrency.md",
  },
  {
    key: "tooling",
    navLabel: "Tooling",
    title: "Tooling",
    lead: "Testing, fuzzing, formatting, the language server, editor support, and the full CLI.",
    sourcePath: "docs/tooling.md",
  },
  {
    key: "platforms",
    navLabel: "Platforms & Compilers",
    title: "Platforms & Compilers",
    lead: "C compiler selection, runtime backends, and what's supported where.",
    sourcePath: "docs/platforms.md",
  },
];

const DOC_TAB_KEYS = new Set<string>(DOC_TABS.map((d) => d.key));
function isDocTab(key: TabKey): key is DocTabKey {
  return DOC_TAB_KEYS.has(key);
}

const TABS: Array<{
  key: TabKey;
  label: string;
  disabled?: boolean;
  tooltip?: string;
}> = [
  ...DOC_TABS.map((dt) => ({ key: dt.key as TabKey, label: dt.navLabel })),
  { key: "stdlib", label: "Std Library" },
  {
    key: "playground",
    label: "Playground",
    disabled: isGithubPages,
    tooltip: isGithubPages
      ? "Playground is disabled on GitHub Pages because there is no backend API available to run code. To use the Playground, run the site locally or set up a remote runner API."
      : undefined,
  },
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
    detailKey: params.get("detail") ?? "",
  };
}

function buildStdlibHash(
  modulePath: string,
  symbolKey: string,
  detailKey = "",
) {
  const params = new URLSearchParams();
  if (modulePath) params.set("module", modulePath);
  if (symbolKey) params.set("symbol", symbolKey);
  if (detailKey) params.set("detail", detailKey);
  const query = params.toString();
  return query ? `#stdlib?${query}` : "#stdlib";
}

function parseTabHash(hash: string): TabKey | null {
  const value = hash.startsWith("#") ? hash.slice(1) : hash;
  const [route] = value.split("?");
  if (route === "playground") return "playground";
  if (route === "stdlib") return "stdlib";
  const docTab = DOC_TABS.find((d) => d.key === route);
  if (docTab) return docTab.key;
  return null;
}

function getInitialHashState() {
  if (typeof window === "undefined") {
    return {
      tab: "getStarted" as TabKey,
      modulePath: "",
      symbolKey: "",
      detailKey: "",
      docAnchorKey: "",
    };
  }

  const value = window.location.hash.startsWith("#")
    ? window.location.hash.slice(1)
    : window.location.hash;
  const [_route, query = ""] = value.split("?");
  const params = new URLSearchParams(query);

  const tabFromHash = parseTabHash(window.location.hash);
  if (tabFromHash && tabFromHash !== "stdlib") {
    return {
      tab: tabFromHash,
      modulePath: "",
      symbolKey: "",
      detailKey: "",
      docAnchorKey: params.get("anchor") ?? "",
    };
  }

  const parsed = parseStdlibHash(window.location.hash);
  if (parsed) {
    return {
      tab: "stdlib" as TabKey,
      modulePath: parsed.modulePath,
      symbolKey: parsed.symbolKey,
      detailKey: parsed.detailKey,
      docAnchorKey: "",
    };
  }

  return {
    tab: "getStarted" as TabKey,
    modulePath: "",
    symbolKey: "",
    detailKey: "",
    docAnchorKey: params.get("anchor") ?? "",
  };
}

const THEME_STORAGE_KEY = "fun-theme";

function getInitialTheme(): "light" | "dark" {
  if (typeof document !== "undefined") {
    const seeded = document.documentElement.dataset.theme;
    if (seeded === "light" || seeded === "dark") {
      return seeded;
    }
  }

  if (typeof window !== "undefined") {
    try {
      const stored = window.localStorage.getItem(THEME_STORAGE_KEY);
      if (stored === "light" || stored === "dark") {
        return stored;
      }
    } catch {
      // Ignore storage access failures (e.g. privacy mode) and fall through.
    }

    if (window.matchMedia?.("(prefers-color-scheme: light)").matches) {
      return "light";
    }
  }

  return "dark";
}

function getInitialVersion() {
  if (typeof window === "undefined") {
    return DEFAULT_FUN_VERSION;
  }

  const params = new URLSearchParams(window.location.search);
  return params.get("v") || DEFAULT_FUN_VERSION;
}

function stripMarkdownForSearch(text: string) {
  return text
    .replace(/```[\s\S]*?```/g, (block) =>
      block.replace(/```[a-zA-Z0-9_-]*\n?|```/g, " "),
    )
    .replace(/`([^`]+)`/g, "$1")
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/^>\s?/gm, "")
    .replace(/^[-*+]\s+/gm, "")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/__([^_]+)__/g, "$1")
    .replace(/(?<!\*)\*([^*]+)\*(?!\*)/g, "$1")
    .replace(/(?<!_)_([^_]+)_(?!_)/g, "$1")
    .replace(/~~([^~]+)~~/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
}

function formatSnippet(text: string, q: string) {
  const cleaned = stripMarkdownForSearch(text);
  const lower = cleaned.toLowerCase();
  const idx = lower.indexOf(q.toLowerCase());
  if (idx < 0) return cleaned.slice(0, 120);
  const start = Math.max(0, idx - 36);
  const end = Math.min(cleaned.length, idx + q.length + 56);
  return cleaned.slice(start, end).replace(/\s+/g, " ").trim();
}

function slugifyHeading(text: string) {
  const base = text
    .toLowerCase()
    .replace(/[`*_~[\]().,!?:;"'<>]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "");
  return base || "section";
}

function cleanHeadingText(raw: string) {
  return raw
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*_~]/g, "")
    .trim();
}

function normalizeModuleSummary(
  summary: string,
  fallback = "No summary found.",
) {
  const raw = String(summary ?? "");
  const firstLine = raw.split(/\r?\n/)[0] ?? "";
  const compact = firstLine
    .replace(/```/g, "")
    .replace(/^#{1,6}\s+/, "")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\s+/g, " ")
    .trim();

  if (!compact) return fallback;
  if (
    /^(usage|example|examples|params|returns|fields|notes)\s*:?\s*$/i.test(
      compact,
    )
  ) {
    return fallback;
  }

  return compact.length > 180 ? `${compact.slice(0, 177)}...` : compact;
}

function extractDocSections(markdown: string, tab: DocTabKey) {
  const lines = markdown.split(/\r?\n/);
  const counts = new Map<string, number>();
  const sections: DocSection[] = [];
  let current: DocSection | null = null;
  let inCodeFence = false;

  for (const line of lines) {
    if (/^```/.test(line.trim())) {
      inCodeFence = !inCodeFence;
      if (current) {
        current.content += `\n${line}`;
      }
      continue;
    }

    if (inCodeFence) {
      if (current) {
        current.content += `\n${line}`;
      }
      continue;
    }

    const headingMatch = line.match(/^(#{1,6})\s+(.+)$/);
    if (headingMatch) {
      const level = headingMatch[1].length;
      const title = cleanHeadingText(headingMatch[2]);
      const slug = `${tab}-${slugifyHeading(title)}`;
      const seen = counts.get(slug) ?? 0;
      counts.set(slug, seen + 1);
      const id = seen === 0 ? slug : `${slug}-${seen + 1}`;

      current = {
        id,
        title,
        level,
        content: title,
        tab,
      };
      sections.push(current);
      continue;
    }

    if (current) {
      current.content += `\n${line}`;
    }
  }

  return sections;
}

async function tryLoadVersionContent(version: string) {
  const res = await fetch(withBasePath(`versions/${version}/content.json`), {
    cache: "no-store",
  });
  if (!res.ok) {
    throw new Error(`Failed to load version ${version}`);
  }
  return (await res.json()) as ReferenceContent;
}

async function tryLoadBundledContent() {
  const res = await fetch(bundledContentUrl, {
    cache: "no-store",
  });
  if (!res.ok) {
    throw new Error("Failed to load bundled content");
  }
  return (await res.json()) as ReferenceContent;
}

export default function App() {
  const initial = getInitialHashState();
  const [content, setContent] = useState<ReferenceContent>(EMPTY_CONTENT);
  const [versionList, setVersionList] = useState<string[]>([
    DEFAULT_FUN_VERSION,
  ]);
  const [selectedVersion, setSelectedVersion] = useState(getInitialVersion());
  const [versionsReady, setVersionsReady] = useState(false);
  const [tab, setTab] = useState<TabKey>(initial.tab);
  const [search, setSearch] = useState("");
  const [globalSearch, setGlobalSearch] = useState("");
  const [activeGlobalResultIndex, setActiveGlobalResultIndex] = useState(-1);
  const [selectedModulePath, setSelectedModulePath] = useState(
    initial.modulePath,
  );
  const [selectedSymbolKey, setSelectedSymbolKey] = useState(initial.symbolKey);
  const [selectedDetailKey, setSelectedDetailKey] = useState(initial.detailKey);
  const [modalContentTab, setModalContentTab] = useState<"module" | "symbol">(
    initial.symbolKey ? "symbol" : "module",
  );
  const [selectedDocAnchorKey, setSelectedDocAnchorKey] = useState(
    initial.docAnchorKey,
  );
  const [activeDocAnchorKey, setActiveDocAnchorKey] = useState("");
  // Timestamp (ms) until which the scroll-spy observer below should not
  // override activeDocAnchorKey - set right after an explicit scroll-to-
  // anchor, whose target can otherwise get immediately outvoted by the
  // observer's own "reading position" heuristic (see tryScroll).
  const suppressScrollSpyUntilRef = useRef(0);
  const [docTocHeadings, setDocTocHeadings] = useState<
    Partial<Record<DocTabKey, TocHeading[]>>
  >({});
  const [isStdlibModalOpen, setIsStdlibModalOpen] = useState(
    Boolean(initial.modulePath || initial.symbolKey),
  );
  const [isVersionLoading, setIsVersionLoading] = useState(false);
  const [copyStatus, setCopyStatus] = useState<"idle" | "ok" | "err">("idle");
  const [detailCopyKey, setDetailCopyKey] = useState("");
  const [isMobileDrawerOpen, setIsMobileDrawerOpen] = useState(false);
  const [isSearchModalOpen, setIsSearchModalOpen] = useState(false);
  const [theme, setTheme] = useState<"light" | "dark">(getInitialTheme);
  const globalSearchInputRef = useRef<HTMLInputElement | null>(null);
  const releaseUrl = `https://github.com/omdxp/fun/releases/tag/v${content.funVersion}`;

  const toggleTheme = () => {
    setTheme((prev) => (prev === "dark" ? "light" : "dark"));
  };

  const openSearchModal = () => {
    setIsSearchModalOpen(true);
    setIsMobileDrawerOpen(false);
  };

  const closeSearchModal = () => {
    setIsSearchModalOpen(false);
    setActiveGlobalResultIndex(-1);
  };

  const goHome = () => {
    setTab("getStarted");
    setSearch("");
    setGlobalSearch("");
    setActiveGlobalResultIndex(-1);
    setSelectedModulePath("");
    setSelectedSymbolKey("");
    setSelectedDetailKey("");
    setSelectedDocAnchorKey("");
    setActiveDocAnchorKey("");
    setIsStdlibModalOpen(false);
    setIsMobileDrawerOpen(false);
    setIsSearchModalOpen(false);
    if (typeof window !== "undefined") {
      window.scrollTo({ top: 0, behavior: "smooth" });
    }
  };

  const scrollToDocAnchor = (
    anchor: string,
    behavior: ScrollBehavior = "smooth",
    headingTitle = "",
  ) => {
    if (!anchor) return;
    if (typeof window === "undefined") return;

    const normalize = (text: string) => text.trim().replace(/\s+/g, " ");

    const resolveAnchor = () => {
      if (document.getElementById(anchor)) return anchor;

      const headings = Array.from(
        document.querySelectorAll<HTMLElement>("[data-doc-heading='true']"),
      );

      if (headingTitle) {
        const target = normalize(headingTitle);
        const byTitle = headings.find((el) => {
          const label =
            el.querySelector<HTMLElement>(".md-heading-inner")?.textContent ??
            el.textContent ??
            "";
          return normalize(label) === target;
        });
        if (byTitle?.id) return byTitle.id;
      }

      const prefix = anchor.replace(/-\d+$/, "");
      const byPrefix = headings.find((el) => el.id.startsWith(prefix));
      if (byPrefix?.id) return byPrefix.id;

      return "";
    };

    const tryScroll = (attempt: number) => {
      const resolved = resolveAnchor();
      const el = resolved ? document.getElementById(resolved) : null;
      if (el) {
        el.scrollIntoView({ behavior, block: "start" });
        setActiveDocAnchorKey(el.id);
        // A short section can put its own heading at the very top of the
        // viewport (y=0) while the observer's active zone only starts
        // 15% down, so the NEXT heading over ends up the only one it
        // sees - suppress its updates briefly so the explicit target
        // sticks until the user actually scrolls on their own.
        suppressScrollSpyUntilRef.current = Date.now() + 900;
        if (selectedDocAnchorKey !== el.id) {
          setSelectedDocAnchorKey(el.id);
        }
        return;
      }

      if (attempt < 8) {
        window.setTimeout(() => tryScroll(attempt + 1), 40);
      }
    };

    tryScroll(0);
  };

  const docSectionsByTab = useMemo(() => {
    const out = {} as Record<DocTabKey, DocSection[]>;
    for (const dt of DOC_TABS) {
      // A picked historical version's content.json may predate this tab
      // (its docs object won't have the field at all), not just be empty.
      out[dt.key] = extractDocSections(content.docs[dt.key] ?? "", dt.key);
    }
    return out;
  }, [content.docs]);

  const activeDocSections = useMemo(() => {
    if (isDocTab(tab)) return docTocHeadings[tab] ?? [];
    return [] as TocHeading[];
  }, [tab, docTocHeadings]);

  const globalResults = useMemo(() => {
    const q = globalSearch.trim().toLowerCase();
    if (!q) return [] as GlobalSearchResult[];

    const out: GlobalSearchResult[] = [];

    for (const dt of DOC_TABS) {
      for (const section of docSectionsByTab[dt.key]) {
        if (!section.content.toLowerCase().includes(q)) continue;
        out.push({
          id: `doc:${dt.key}:${section.id}`,
          title: `${dt.navLabel}: ${section.title}`,
          subtitle: formatSnippet(section.content, q),
          group: "docs",
          tab: dt.key,
          docAnchorKey: section.id,
        });
      }
    }

    for (const sample of content.samples) {
      const hay = `${sample.title}\n${sample.code}`;
      if (!hay.toLowerCase().includes(q)) continue;
      out.push({
        id: `sample:${sample.title}`,
        title: `Playground sample: ${sample.title}`,
        subtitle: formatSnippet(hay, q),
        group: "samples",
        tab: "playground",
      });
    }

    for (const moduleItem of content.stdlib) {
      const moduleSummary = normalizeModuleSummary(moduleItem.summary, "");
      const moduleHay = `${moduleItem.module}\n${moduleSummary}\n${moduleItem.docsMarkdown}`;
      if (moduleHay.toLowerCase().includes(q)) {
        out.push({
          id: `module:${moduleItem.module}`,
          title: `Std module: std/${moduleItem.module.replace(/\.fn$/, "")}`,
          subtitle: formatSnippet(moduleHay, q),
          group: "stdlib",
          tab: "stdlib",
          modulePath: moduleItem.module,
        });
      }

      for (const symbol of moduleItem.symbols) {
        const symbolKey = `${symbol.name}:${symbol.line}`;
        const symbolHay = `${symbol.name}\n${symbol.signature}\n${symbol.docsMarkdown}`;
        if (symbolHay.toLowerCase().includes(q)) {
          out.push({
            id: `symbol:${moduleItem.module}:${symbolKey}`,
            title: `Std symbol: ${symbol.name}`,
            subtitle: `std/${moduleItem.module.replace(/\.fn$/, "")} · ${formatSnippet(symbolHay, q)}`,
            group: "stdlib",
            tab: "stdlib",
            modulePath: moduleItem.module,
            symbolKey,
          });
        }

        for (const field of symbol.fields ?? []) {
          const fieldHay = `${field.name}\n${field.signature}\n${field.docsMarkdown}\n${field.inlineDoc ?? ""}`;
          if (!fieldHay.toLowerCase().includes(q)) continue;
          out.push({
            id: `field:${moduleItem.module}:${symbolKey}:${field.name}:${field.line}`,
            title: `Field: ${symbol.name}.${field.name}`,
            subtitle: `std/${moduleItem.module.replace(/\.fn$/, "")} · ${formatSnippet(fieldHay, q)}`,
            group: "stdlib",
            tab: "stdlib",
            modulePath: moduleItem.module,
            symbolKey,
            detailKey: `field:${field.name}:${field.line}`,
          });
        }

        for (const member of symbol.members ?? []) {
          const memberHay = `${member.name}\n${member.signature}\n${member.docsMarkdown}\n${member.inlineDoc ?? ""}`;
          if (!memberHay.toLowerCase().includes(q)) continue;
          out.push({
            id: `member:${moduleItem.module}:${symbolKey}:${member.name}:${member.line}`,
            title: `Member: ${symbol.name}.${member.name}`,
            subtitle: `std/${moduleItem.module.replace(/\.fn$/, "")} · ${formatSnippet(memberHay, q)}`,
            group: "stdlib",
            tab: "stdlib",
            modulePath: moduleItem.module,
            symbolKey,
            detailKey: `member:${member.name}:${member.line}`,
          });
        }
      }
    }

    return out.slice(0, 40);
  }, [globalSearch, content, docSectionsByTab]);

  const groupedGlobalResults = useMemo(() => {
    return {
      docs: globalResults.filter((r) => r.group === "docs"),
      stdlib: globalResults.filter((r) => r.group === "stdlib"),
      samples: globalResults.filter((r) => r.group === "samples"),
    };
  }, [globalResults]);

  const globalResultSections = useMemo(
    () =>
      [
        {
          key: "docs",
          label: "Docs",
          items: groupedGlobalResults.docs,
        },
        {
          key: "stdlib",
          label: "Standard Library",
          items: groupedGlobalResults.stdlib,
        },
        {
          key: "samples",
          label: "Playground Samples",
          items: groupedGlobalResults.samples,
        },
      ] as const,
    [groupedGlobalResults],
  );

  const filteredModules = useMemo(() => {
    const q = search.toLowerCase().trim();
    if (!q) return content.stdlib;
    return content.stdlib.filter((m) => {
      const moduleSummary = normalizeModuleSummary(m.summary, "");
      if (m.module.toLowerCase().includes(q)) return true;
      if (moduleSummary.toLowerCase().includes(q)) return true;
      if ((m.docsMarkdown ?? "").toLowerCase().includes(q)) return true;
      return m.symbols.some(
        (s) =>
          s.name.toLowerCase().includes(q) ||
          s.signature.toLowerCase().includes(q) ||
          (s.docsMarkdown ?? "").toLowerCase().includes(q) ||
          (s.fields ?? []).some(
            (f) =>
              f.name.toLowerCase().includes(q) ||
              f.signature.toLowerCase().includes(q) ||
              (f.docsMarkdown ?? "").toLowerCase().includes(q) ||
              (f.inlineDoc ?? "").toLowerCase().includes(q),
          ) ||
          (s.members ?? []).some(
            (m) =>
              m.name.toLowerCase().includes(q) ||
              m.signature.toLowerCase().includes(q) ||
              (m.docsMarkdown ?? "").toLowerCase().includes(q) ||
              (m.inlineDoc ?? "").toLowerCase().includes(q),
          ),
      );
    });
  }, [search, content]);

  const activeModule = useMemo(() => {
    if (!selectedModulePath) return null;
    return content.stdlib.find((m) => m.module === selectedModulePath) ?? null;
  }, [selectedModulePath, content]);

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

  const activeModuleSymbolGroups = useMemo(() => {
    if (!activeModule) {
      return {
        nonMethodSymbols: [] as StdSymbol[],
        methodGroups: [] as Array<{ owner: string; symbols: StdSymbol[] }>,
      };
    }

    const nonMethodSymbols = activeModule.symbols.filter(
      (s) => s.kind !== "method",
    );

    const byOwner = new Map<string, StdSymbol[]>();
    for (const symbol of activeModule.symbols) {
      if (symbol.kind !== "method") continue;
      const owner = symbol.owner ?? "(unknown)";
      const bucket = byOwner.get(owner);
      if (bucket) {
        bucket.push(symbol);
      } else {
        byOwner.set(owner, [symbol]);
      }
    }

    const methodGroups = Array.from(byOwner.entries()).map(
      ([owner, symbols]) => ({
        owner,
        symbols,
      }),
    );

    return {
      nonMethodSymbols,
      methodGroups,
    };
  }, [activeModule]);

  const renderSymbolPill = (modulePath: string, s: StdSymbol) => {
    const key = `${s.name}:${s.line}`;
    return (
      <button
        key={key}
        type="button"
        className={`symbol-pill ${
          activeSymbol &&
          activeSymbol.name === s.name &&
          activeSymbol.line === s.line
            ? "active"
            : ""
        }`}
        onClick={() => {
          setSelectedModulePath(modulePath);
          setSelectedSymbolKey(key);
          setSelectedDetailKey("");
          setIsStdlibModalOpen(true);
        }}
      >
        <span className="badge">{s.kind}</span>
        <span>{s.name}</span>
      </button>
    );
  };

  const openStdlibModule = (
    modulePath: string,
    symbolKey = "",
    detailKey = "",
  ) => {
    setSelectedModulePath(modulePath);
    setSelectedSymbolKey(symbolKey);
    setSelectedDetailKey(detailKey);
    setIsStdlibModalOpen(true);
  };

  const closeStdlibModal = () => {
    setIsStdlibModalOpen(false);
    setSelectedModulePath("");
    setSelectedSymbolKey("");
    setSelectedDetailKey("");
  };

  const activateGlobalResult = (result: GlobalSearchResult) => {
    setTab(result.tab);
    setIsMobileDrawerOpen(false);
    setIsSearchModalOpen(false);
    if (isDocTab(result.tab) && result.docAnchorKey) {
      setSelectedDocAnchorKey(result.docAnchorKey);
      window.setTimeout(() => {
        const headingTitle = result.title.includes(":")
          ? result.title.split(":").slice(1).join(":").trim()
          : result.title;
        scrollToDocAnchor(result.docAnchorKey ?? "", "smooth", headingTitle);
      }, 0);
    } else {
      setSelectedDocAnchorKey("");
    }
    if (result.tab === "stdlib" && result.modulePath) {
      setSearch("");
      openStdlibModule(
        result.modulePath,
        result.symbolKey ?? "",
        result.detailKey ?? "",
      );
    }
    setGlobalSearch("");
    setActiveGlobalResultIndex(-1);
  };

  useEffect(() => {
    if (typeof window === "undefined") return;

    const onKeyDown = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      const inEditable =
        target?.tagName === "INPUT" ||
        target?.tagName === "TEXTAREA" ||
        target?.isContentEditable;

      if (event.key === "/" && !inEditable) {
        event.preventDefault();
        openSearchModal();
      }
    };

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  useEffect(() => {
    if (!isSearchModalOpen) return;

    const id = window.setTimeout(() => {
      globalSearchInputRef.current?.focus();
      globalSearchInputRef.current?.select();
    }, 0);

    return () => window.clearTimeout(id);
  }, [isSearchModalOpen]);

  useEffect(() => {
    setActiveGlobalResultIndex(globalResults.length > 0 ? 0 : -1);
  }, [globalSearch, globalResults.length]);

  useEffect(() => {
    if (typeof document === "undefined") return;
    document.documentElement.dataset.theme = theme;
    const themeColorMeta = document.querySelector<HTMLMetaElement>(
      'meta[name="theme-color"]',
    );
    if (themeColorMeta) {
      themeColorMeta.content = theme === "light" ? "#f4f1e9" : "#0b1020";
    }
    try {
      window.localStorage.setItem(THEME_STORAGE_KEY, theme);
    } catch {
      // Ignore storage write failures (e.g. privacy mode).
    }
  }, [theme]);

  useEffect(() => {
    if (typeof window === "undefined") return;

    const onResize = () => {
      if (window.innerWidth > 980) {
        setIsMobileDrawerOpen(false);
      }
    };

    onResize();
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  useEffect(() => {
    if (typeof window === "undefined") return;

    let isCancelled = false;

    const load = async () => {
      try {
        const res = await fetch(withBasePath("versions/index.json"), {
          cache: "no-store",
        });
        if (!res.ok) {
          throw new Error(`Failed to load versions index: ${res.status}`);
        }
        const index = (await res.json()) as VersionsIndex;
        if (!index.available || index.available.length === 0) {
          throw new Error("Versions index is empty");
        }

        if (isCancelled) return;

        setVersionList(index.available);

        const params = new URLSearchParams(window.location.search);
        const requested = params.get("v");
        const nextVersion =
          requested && index.available.includes(requested)
            ? requested
            : index.latest;
        setSelectedVersion(nextVersion);
      } catch {
        try {
          const fallbackContent = await tryLoadBundledContent();
          if (isCancelled) return;
          setContent(fallbackContent);

          const fallbackVersions = fallbackContent.versions?.available?.length
            ? fallbackContent.versions.available
            : [fallbackContent.funVersion];
          setVersionList(fallbackVersions);

          const params = new URLSearchParams(window.location.search);
          const requested = params.get("v");
          const nextVersion =
            requested && fallbackVersions.includes(requested)
              ? requested
              : fallbackContent.funVersion;
          setSelectedVersion(nextVersion);
        } catch {
          if (isCancelled) return;
          setContent(EMPTY_CONTENT);
          setVersionList([DEFAULT_FUN_VERSION]);
          setSelectedVersion(DEFAULT_FUN_VERSION);
        }
      } finally {
        if (!isCancelled) {
          setVersionsReady(true);
        }
      }
    };

    void load();

    return () => {
      isCancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!versionsReady || !selectedVersion) return;

    const run = async () => {
      setIsVersionLoading(true);
      try {
        const nextContent = await tryLoadVersionContent(selectedVersion);
        setContent(nextContent);
      } catch {
        try {
          const fallbackContent = await tryLoadBundledContent();
          setContent(fallbackContent);

          const fallbackVersions = fallbackContent.versions?.available?.length
            ? fallbackContent.versions.available
            : [fallbackContent.funVersion];
          setVersionList((prev) => (prev.length > 1 ? prev : fallbackVersions));
        } catch {
          setContent(EMPTY_CONTENT);
          setVersionList((prev) =>
            prev.length > 1 ? prev : [DEFAULT_FUN_VERSION],
          );
        }
      } finally {
        setIsVersionLoading(false);
      }
    };

    void run();
  }, [selectedVersion, versionsReady]);

  useEffect(() => {
    if (typeof window === "undefined") return;

    const applyHash = () => {
      const value = window.location.hash.startsWith("#")
        ? window.location.hash.slice(1)
        : window.location.hash;
      const [route, query = ""] = value.split("?");
      const params = new URLSearchParams(query);

      const tabFromHash = parseTabHash(window.location.hash);
      if (tabFromHash && tabFromHash !== "stdlib") {
        setTab(tabFromHash);
        const anchor = params.get("anchor") ?? "";
        setSelectedDocAnchorKey(anchor);
        // With no anchor to scroll to, reset scroll explicitly - the SPA
        // swaps page content in place, so the browser won't do this on
        // its own the way a real page navigation would.
        if (!anchor) {
          setActiveDocAnchorKey("");
          window.scrollTo({ top: 0 });
        }
        return;
      }

      const parsed = parseStdlibHash(window.location.hash);
      if (!parsed) return;
      setTab("stdlib");
      setSearch("");
      setSelectedModulePath(parsed.modulePath);
      setSelectedSymbolKey(parsed.symbolKey);
      setSelectedDetailKey(parsed.detailKey);
      setSelectedDocAnchorKey("");
      setIsStdlibModalOpen(Boolean(parsed.modulePath || parsed.symbolKey));
    };

    applyHash();
    window.addEventListener("hashchange", applyHash);
    return () => window.removeEventListener("hashchange", applyHash);
  }, []);

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (!versionsReady) return;

    if (tab !== "stdlib") {
      const params = new URLSearchParams();
      if (isDocTab(tab) && selectedDocAnchorKey) {
        params.set("anchor", selectedDocAnchorKey);
      }
      const q = params.toString();
      const nextHash = q ? `#${tab}?${q}` : `#${tab}`;
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
    const nextHash = buildStdlibHash(modulePath, symbolKey, selectedDetailKey);

    if (window.location.hash !== nextHash) {
      const nextUrl = `${window.location.pathname}${window.location.search}${nextHash}`;
      window.history.replaceState(null, "", nextUrl);
    }
  }, [
    tab,
    versionsReady,
    activeModule,
    activeSymbol,
    selectedDetailKey,
    selectedDocAnchorKey,
  ]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (!isDocTab(tab)) return;
    const activeTab = tab;

    const id = window.setTimeout(() => {
      const nodes = Array.from(
        document.querySelectorAll<HTMLElement>("[data-doc-heading='true']"),
      );

      const next: TocHeading[] = nodes.map((el) => {
        const title =
          el.querySelector<HTMLElement>(".md-heading-inner")?.textContent ??
          el.textContent ??
          "";
        const level = Number.parseInt(el.tagName.slice(1), 10);
        return {
          id: el.id,
          title: title.trim(),
          level: Number.isFinite(level) ? level : 2,
        };
      });

      setDocTocHeadings((prev) => ({ ...prev, [activeTab]: next }));
    }, 0);

    return () => window.clearTimeout(id);
  }, [tab, content]);

  useEffect(() => {
    if (!isDocTab(tab)) return;
    if (!selectedDocAnchorKey) return;
    scrollToDocAnchor(selectedDocAnchorKey, "smooth");

    // Code blocks render as plain text until the shared Shiki highlighter
    // resolves, then re-render highlighted - often at a different height,
    // which can shift an anchor scrolled to above out from under the
    // viewport once that settles. Re-scroll (no animation, so it doesn't
    // fight the one above) once highlighting is actually ready.
    let cancelled = false;
    getSiteHighlighter().then(() => {
      if (cancelled) return;
      scrollToDocAnchor(selectedDocAnchorKey, "auto");
    });
    return () => {
      cancelled = true;
    };
  }, [tab, selectedDocAnchorKey, content]);

  useEffect(() => {
    if (!isDocTab(tab)) return;
    if (typeof window === "undefined") return;

    const ids = activeDocSections.map((h) => h.id);
    const targets = ids
      .map((id) => document.getElementById(id))
      .filter((el): el is HTMLElement => Boolean(el));

    if (targets.length === 0) return;

    const observer = new IntersectionObserver(
      (entries) => {
        if (Date.now() < suppressScrollSpyUntilRef.current) return;

        const visible = entries
          .filter((entry) => entry.isIntersecting)
          .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);

        if (visible.length > 0) {
          const topMost = visible[0].target as HTMLElement;
          setActiveDocAnchorKey(topMost.id);
        }
      },
      {
        root: null,
        rootMargin: "-15% 0px -70% 0px",
        threshold: [0, 1],
      },
    );

    for (const el of targets) observer.observe(el);
    return () => observer.disconnect();
  }, [tab, activeDocSections, content]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (!selectedVersion) return;

    const params = new URLSearchParams(window.location.search);
    if (params.get("v") === selectedVersion) return;
    params.set("v", selectedVersion);

    const nextUrl = `${window.location.pathname}?${params.toString()}${window.location.hash}`;
    window.history.replaceState(null, "", nextUrl);
  }, [selectedVersion]);

  useEffect(() => {
    if (!selectedModulePath) {
      setIsStdlibModalOpen(false);
      return;
    }

    if (!activeModule) {
      return;
    }

    if (selectedSymbolKey) {
      const found = activeModule.symbols.some(
        (s) => `${s.name}:${s.line}` === selectedSymbolKey,
      );
      if (!found) {
        setSelectedSymbolKey("");
        setSelectedDetailKey("");
      }
    }
  }, [activeModule, selectedModulePath, selectedSymbolKey]);

  useEffect(() => {
    if (!activeModule) {
      return;
    }

    if (!activeSymbol) {
      setSelectedDetailKey("");
      return;
    }

    if (!selectedDetailKey) return;

    const [kind, name, lineStr] = selectedDetailKey.split(":");
    const line = Number.parseInt(lineStr ?? "", 10);
    if (!Number.isFinite(line)) {
      setSelectedDetailKey("");
      return;
    }

    if (kind === "field") {
      const exists = (activeSymbol.fields ?? []).some(
        (f) => f.name === name && f.line === line,
      );
      if (!exists) setSelectedDetailKey("");
      return;
    }

    if (kind === "member") {
      const exists = (activeSymbol.members ?? []).some(
        (m) => m.name === name && m.line === line,
      );
      if (!exists) setSelectedDetailKey("");
      return;
    }

    if (kind === "variant") {
      const exists = (activeSymbol.variants ?? []).some(
        (v) => v.name === name && v.line === line,
      );
      if (!exists) setSelectedDetailKey("");
      return;
    }

    setSelectedDetailKey("");
  }, [activeModule, activeSymbol, selectedDetailKey]);

  useEffect(() => {
    if (!isStdlibModalOpen) return;
    setModalContentTab(selectedSymbolKey ? "symbol" : "module");
  }, [selectedModulePath, selectedSymbolKey, isStdlibModalOpen]);

  useEffect(() => {
    if (!selectedDetailKey) return;
    if (typeof window === "undefined") return;

    const id = window.setTimeout(() => {
      const el = document.getElementById(`detail-${selectedDetailKey}`);
      if (el) {
        el.scrollIntoView({ behavior: "smooth", block: "nearest" });
      }
    }, 0);

    return () => window.clearTimeout(id);
  }, [selectedDetailKey, activeSymbol]);

  useEffect(() => {
    if (!isStdlibModalOpen) return;

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        closeStdlibModal();
      }
    };

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [isStdlibModalOpen]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (typeof document === "undefined") return;
    if (!isStdlibModalOpen && !isSearchModalOpen) return;

    const body = document.body;
    const previousOverflow = body.style.overflow;
    const previousPaddingRight = body.style.paddingRight;
    const scrollbarWidth =
      window.innerWidth - document.documentElement.clientWidth;

    body.style.overflow = "hidden";
    if (scrollbarWidth > 0) {
      body.style.paddingRight = `${scrollbarWidth}px`;
    }

    return () => {
      body.style.overflow = previousOverflow;
      body.style.paddingRight = previousPaddingRight;
    };
  }, [isStdlibModalOpen, isSearchModalOpen]);

  const copyStdlibLink = async () => {
    if (typeof window === "undefined") return;
    if (!activeModule) return;

    const symbolKey = activeSymbol
      ? `${activeSymbol.name}:${activeSymbol.line}`
      : "";
    const hash = buildStdlibHash(
      activeModule.module,
      symbolKey,
      selectedDetailKey,
    );
    const url = `${window.location.origin}${window.location.pathname}${window.location.search}${hash}`;

    try {
      await copyTextToClipboard(url);
      setCopyStatus("ok");
    } catch {
      setCopyStatus("err");
    }

    window.setTimeout(() => {
      setCopyStatus("idle");
    }, 1500);
  };

  const copyStdlibDetailLink = async (detailKey: string) => {
    if (typeof window === "undefined") return;
    if (!activeModule) return;
    if (!activeSymbol) return;

    const symbolKey = `${activeSymbol.name}:${activeSymbol.line}`;
    const hash = buildStdlibHash(activeModule.module, symbolKey, detailKey);
    const url = `${window.location.origin}${window.location.pathname}${window.location.search}${hash}`;

    try {
      await copyTextToClipboard(url);
      setDetailCopyKey(detailKey);
      window.setTimeout(() => {
        setDetailCopyKey((prev) => (prev === detailKey ? "" : prev));
      }, 1500);
    } catch {
      setDetailCopyKey("");
    }
  };

  return (
    <div className="app-shell">
      <aside>
        <div className="drawer-mobile-bar">
          <button type="button" className="brand" onClick={goHome}>
            <img
              className="brand-logo"
              src={`${import.meta.env.BASE_URL}fun.png`}
              alt="Fun language logo"
              width={36}
              height={36}
            />
            <span className="brand-text">Fun Language Reference</span>
          </button>
          <div className="header-actions">
            <button
              type="button"
              className="theme-toggle"
              aria-label={
                theme === "dark"
                  ? "Switch to light theme"
                  : "Switch to dark theme"
              }
              aria-pressed={theme === "light"}
              title={
                theme === "dark"
                  ? "Switch to light theme"
                  : "Switch to dark theme"
              }
              onClick={toggleTheme}
            >
              <span aria-hidden="true">{theme === "dark" ? "☀" : "☾"}</span>
            </button>
            <button
              type="button"
              className="drawer-toggle"
              aria-expanded={isMobileDrawerOpen}
              aria-controls="sidebar-drawer-content"
              onClick={() => {
                setIsMobileDrawerOpen((prev) => !prev);
              }}
            >
              {isMobileDrawerOpen ? "Hide menu" : "Show menu"}
            </button>
          </div>
        </div>

        <div
          id="sidebar-drawer-content"
          className={`drawer-content ${isMobileDrawerOpen ? "open" : ""}`}
        >
          <p className="muted drawer-subtitle">
            Interactive docs + local runner
          </p>
          <div className="global-search-wrap">
            <button
              type="button"
              className="search global-search search-trigger"
              aria-label="Open global search"
              aria-haspopup="dialog"
              aria-expanded={isSearchModalOpen}
              onClick={openSearchModal}
            >
              <span className="search-trigger-label">
                {globalSearch.trim() || "Search everything"}
              </span>
              <span className="search-trigger-shortcut" aria-hidden="true">
                /
              </span>
            </button>
          </div>

          <div className="version-controls">
            <label htmlFor="version-select" className="muted small">
              Docs version
            </label>
            <select
              id="version-select"
              value={selectedVersion}
              onChange={(event) => {
                setSelectedVersion(event.target.value);
                setSearch("");
                setSelectedModulePath("");
                setSelectedSymbolKey("");
                setIsStdlibModalOpen(false);
                setIsMobileDrawerOpen(false);
              }}
            >
              {versionList.map((version) => (
                <option key={version} value={version}>
                  v{version}
                  {version === (versionList[0] ?? version) ? " (latest)" : ""}
                </option>
              ))}
            </select>
            {isVersionLoading && (
              <div className="muted small">Loading version...</div>
            )}
          </div>

          <nav>
            {TABS.map((t) => {
              const isActive = tab === t.key;
              const subItems =
                isActive && isDocTab(t.key)
                  ? (docTocHeadings[t.key] ?? []).filter((h) => h.level <= 3)
                  : [];
              return (
                <div className="nav-item" key={t.key}>
                  <button
                    onClick={() => {
                      if (!t.disabled) {
                        setTab(t.key);
                        // A top-level nav click always means "go to the top
                        // of this page" - never carry over a TOC anchor
                        // selected on whichever page was open before, doc
                        // tab or not, and never keep whatever scroll offset
                        // that page had (the SPA swaps content in place, so
                        // the browser has no reason to reset scroll itself).
                        setSelectedDocAnchorKey("");
                        setActiveDocAnchorKey("");
                        setIsMobileDrawerOpen(false);
                        if (typeof window !== "undefined") {
                          window.scrollTo({ top: 0 });
                        }
                      }
                    }}
                    className={
                      isActive
                        ? "active" + (t.disabled ? " disabled" : "")
                        : t.disabled
                          ? "disabled"
                          : ""
                    }
                    disabled={!!t.disabled}
                    title={t.tooltip}
                    style={
                      t.disabled ? { opacity: 0.6, cursor: "not-allowed" } : {}
                    }
                  >
                    {t.label}
                  </button>
                  {subItems.length > 0 && (
                    <div className="nav-subitems">
                      {subItems.map((h) => (
                        <button
                          key={h.id}
                          type="button"
                          className={`nav-subitem level-${Math.min(h.level, 3)} ${
                            activeDocAnchorKey === h.id ? "active" : ""
                          }`}
                          onClick={() => {
                            setSelectedDocAnchorKey(h.id);
                            scrollToDocAnchor(h.id, "smooth");
                            setIsMobileDrawerOpen(false);
                          }}
                        >
                          {h.title}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              );
            })}
          </nav>
          <div className="meta muted">
            <a href={releaseUrl} target="_blank" rel="noreferrer">
              Fun v{content.funVersion}
            </a>
          </div>
          <div className="meta muted">
            Generated {new Date(content.generatedAt).toLocaleString()}
          </div>
        </div>
      </aside>

      <main>
        {DOC_TABS.map(
          (dt) =>
            tab === dt.key && (
              <section className="panel" key={dt.key}>
                <h1>{dt.title}</h1>
                <p className="lead">{dt.lead}</p>
                <div className="doc-main">
                  <MarkdownWithPlayground
                    markdown={content.docs[dt.key] ?? ""}
                    sourcePath={dt.sourcePath}
                    headingPrefix={dt.key}
                  />
                </div>
              </section>
            ),
        )}

        {tab === "stdlib" && (
          <section className="panel stdlib-panel">
            <h1>Standard Library Explorer</h1>
            <p className="lead">
              Browse modules, then open one for an immersive, focused deep dive.
            </p>

            <div className="stdlib-toolbar search-sticky">
              <input
                className="search"
                type="search"
                aria-label="Search standard library"
                placeholder="Search module, symbol, signature, docs..."
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
              <div className="stdlib-count muted">
                {filteredModules.length} modules
              </div>
            </div>

            <div className="stdlib-grid">
              {filteredModules.map((m) => (
                <article
                  key={m.module}
                  className={`module-card ${
                    activeModule?.module === m.module ? "active" : ""
                  }`}
                >
                  <button
                    className="module-select"
                    type="button"
                    onClick={() => openStdlibModule(m.module)}
                  >
                    <div className="module-title">
                      std/{m.module.replace(/\.fn$/, "")}
                    </div>
                    <div className="module-summary">
                      {normalizeModuleSummary(m.summary)}
                    </div>
                    <div className="module-meta muted small">
                      {m.symbols.filter((s) => s.kind !== "method").length}{" "}
                      declarations ·{" "}
                      {m.symbols.filter((s) => s.kind === "method").length}{" "}
                      methods
                    </div>
                  </button>
                  <ul>
                    {m.symbols.length === 0 ? (
                      <li className="muted">No public declarations</li>
                    ) : (
                      m.symbols.slice(0, 4).map((s) => (
                        <li key={`${m.module}:${s.name}:${s.line}`}>
                          <button
                            className={`symbol-row ${
                              activeModule?.module === m.module &&
                              activeSymbol &&
                              activeSymbol.name === s.name &&
                              activeSymbol.line === s.line
                                ? "active"
                                : ""
                            }`}
                            type="button"
                            onClick={() =>
                              openStdlibModule(
                                m.module,
                                `${s.name}:${s.line}`,
                                "",
                              )
                            }
                          >
                            <span className="badge">{s.kind}</span>
                            <HighlightedCode
                              code={s.signature}
                              lang="fun"
                              inline
                              className="fun-inline-code"
                            />
                            {s.kind === "method" && s.owner && (
                              <span className="muted">@ {s.owner}</span>
                            )}
                          </button>
                        </li>
                      ))
                    )}
                  </ul>
                  {m.symbols.length > 4 && (
                    <div className="muted small">
                      +{m.symbols.length - 4} more symbols
                    </div>
                  )}
                </article>
              ))}
            </div>

            {isStdlibModalOpen && activeModule && (
              <div
                className="modal-backdrop"
                onClick={(event) => {
                  if (event.target === event.currentTarget) {
                    closeStdlibModal();
                  }
                }}
              >
                <div className="modal-card" role="dialog" aria-modal="true">
                  <div className="modal-head">
                    <div>
                      <div className="modal-eyebrow">Std Module</div>
                      <h2>std/{activeModule.module.replace(/\.fn$/, "")}</h2>
                      <p className="muted">
                        {normalizeModuleSummary(activeModule.summary)}
                      </p>
                    </div>
                    <div className="modal-actions">
                      <button
                        type="button"
                        className="copy-link-btn"
                        onClick={copyStdlibLink}
                      >
                        {copyStatus === "ok"
                          ? "Copied"
                          : copyStatus === "err"
                            ? "Copy failed"
                            : "Copy link"}
                      </button>
                      <button
                        className="modal-close"
                        type="button"
                        onClick={closeStdlibModal}
                      >
                        Close
                      </button>
                    </div>
                  </div>

                  <div className="modal-body">
                    <div className="modal-sidebar">
                      <div className="modal-section-title">Symbols</div>
                      {activeModuleSymbolGroups.nonMethodSymbols.length > 0 && (
                        <div className="symbol-group">
                          <div className="symbol-group-title muted small">
                            Public declarations
                          </div>
                          <div className="symbol-pills">
                            {activeModuleSymbolGroups.nonMethodSymbols.map(
                              (s) => renderSymbolPill(activeModule.module, s),
                            )}
                          </div>
                        </div>
                      )}

                      {activeModuleSymbolGroups.methodGroups.map((group) => {
                        const shouldOpen =
                          activeSymbol?.kind === "method" &&
                          (activeSymbol.owner ?? "") === group.owner;

                        return (
                          <details
                            className="symbol-group symbol-group-collapsible"
                            key={`methods:${group.owner}`}
                            open={shouldOpen}
                          >
                            <summary className="symbol-group-title muted small">
                              Methods · {group.owner}
                            </summary>
                            <div className="symbol-pills">
                              {group.symbols.map((s) =>
                                renderSymbolPill(activeModule.module, s),
                              )}
                            </div>
                          </details>
                        );
                      })}
                    </div>

                    <div className="modal-content">
                      {activeModule.symbols.length > 0 && (
                        <div
                          className="modal-content-tabs"
                          role="tablist"
                          aria-label="Module detail view"
                        >
                          <button
                            type="button"
                            role="tab"
                            aria-selected={modalContentTab === "module"}
                            className={`modal-content-tab ${
                              modalContentTab === "module" ? "active" : ""
                            }`}
                            onClick={() => setModalContentTab("module")}
                          >
                            Module
                          </button>
                          <button
                            type="button"
                            role="tab"
                            aria-selected={modalContentTab === "symbol"}
                            className={`modal-content-tab ${
                              modalContentTab === "symbol" ? "active" : ""
                            }`}
                            onClick={() => setModalContentTab("symbol")}
                            disabled={!activeSymbol}
                          >
                            Symbol{activeSymbol ? `: ${activeSymbol.name}` : ""}
                          </button>
                        </div>
                      )}

                      {modalContentTab === "module" &&
                        (activeModule.docsMarkdown ? (
                          <MarkdownWithPlayground
                            markdown={activeModule.docsMarkdown}
                            sourcePath={`stdlib/std/${activeModule.module}`}
                            enableRunnableFunBlocks={false}
                          />
                        ) : (
                          <p className="muted">No module-level docs found.</p>
                        ))}

                      {modalContentTab === "symbol" && activeSymbol && (
                        <article className="symbol-detail">
                          <h3>
                            {activeSymbol.name}{" "}
                            <span className="muted">
                              (line {activeSymbol.line})
                            </span>
                          </h3>
                          <HighlightedCode
                            code={activeSymbol.signature}
                            lang="fun"
                            className="fun-block"
                          />
                          {activeSymbol.docsMarkdown ? (
                            <MarkdownWithPlayground
                              markdown={activeSymbol.docsMarkdown}
                              sourcePath={`stdlib/std/${activeModule.module}`}
                              enableRunnableFunBlocks={false}
                            />
                          ) : (
                            <p className="muted">
                              No comment docs found above this declaration.
                            </p>
                          )}

                          {activeSymbol.kind === "compound" &&
                            (activeSymbol.fields?.length ?? 0) > 0 && (
                              <section className="compound-fields">
                                <h4>Fields</h4>
                                <div className="compound-fields-list">
                                  {(activeSymbol.fields ?? []).map((field) => (
                                    <article
                                      key={`${activeSymbol.name}:${field.name}:${field.line}`}
                                      id={`detail-field:${field.name}:${field.line}`}
                                      className={`compound-field-item ${
                                        selectedDetailKey ===
                                        `field:${field.name}:${field.line}`
                                          ? "active"
                                          : ""
                                      }`}
                                      onClick={() => {
                                        setSelectedDetailKey(
                                          `field:${field.name}:${field.line}`,
                                        );
                                      }}
                                    >
                                      <div className="compound-field-head">
                                        <strong>{field.name}</strong>
                                        <div className="compound-field-meta">
                                          <span className="muted small">
                                            line {field.line}
                                          </span>
                                          <button
                                            type="button"
                                            className="detail-link-btn"
                                            onClick={(event) => {
                                              event.stopPropagation();
                                              void copyStdlibDetailLink(
                                                `field:${field.name}:${field.line}`,
                                              );
                                            }}
                                          >
                                            {detailCopyKey ===
                                            `field:${field.name}:${field.line}`
                                              ? "Copied"
                                              : "Permalink"}
                                          </button>
                                        </div>
                                      </div>
                                      <HighlightedCode
                                        code={field.signature}
                                        lang="fun"
                                        className="fun-block"
                                      />
                                      {field.docsMarkdown ? (
                                        <MarkdownWithPlayground
                                          markdown={field.docsMarkdown}
                                          sourcePath={`stdlib/std/${activeModule.module}`}
                                          enableRunnableFunBlocks={false}
                                        />
                                      ) : field.inlineDoc ? (
                                        <p className="muted">
                                          {field.inlineDoc}
                                        </p>
                                      ) : (
                                        <p className="muted">
                                          No field-level docs found.
                                        </p>
                                      )}
                                    </article>
                                  ))}
                                </div>
                              </section>
                            )}

                          {activeSymbol.kind === "quirk" &&
                            (activeSymbol.members?.length ?? 0) > 0 && (
                              <section className="compound-fields">
                                <h4>Members</h4>
                                <div className="compound-fields-list">
                                  {(activeSymbol.members ?? []).map(
                                    (member) => (
                                      <article
                                        key={`${activeSymbol.name}:${member.name}:${member.line}`}
                                        id={`detail-member:${member.name}:${member.line}`}
                                        className={`compound-field-item ${
                                          selectedDetailKey ===
                                          `member:${member.name}:${member.line}`
                                            ? "active"
                                            : ""
                                        }`}
                                        onClick={() => {
                                          setSelectedDetailKey(
                                            `member:${member.name}:${member.line}`,
                                          );
                                        }}
                                      >
                                        <div className="compound-field-head">
                                          <strong>{member.name}</strong>
                                          <div className="compound-field-meta">
                                            <span className="muted small">
                                              line {member.line}
                                            </span>
                                            <button
                                              type="button"
                                              className="detail-link-btn"
                                              onClick={(event) => {
                                                event.stopPropagation();
                                                void copyStdlibDetailLink(
                                                  `member:${member.name}:${member.line}`,
                                                );
                                              }}
                                            >
                                              {detailCopyKey ===
                                              `member:${member.name}:${member.line}`
                                                ? "Copied"
                                                : "Permalink"}
                                            </button>
                                          </div>
                                        </div>
                                        <HighlightedCode
                                          code={member.signature}
                                          lang="fun"
                                          className="fun-block"
                                        />
                                        {member.docsMarkdown ? (
                                          <MarkdownWithPlayground
                                            markdown={member.docsMarkdown}
                                            sourcePath={`stdlib/std/${activeModule.module}`}
                                            enableRunnableFunBlocks={false}
                                          />
                                        ) : member.inlineDoc ? (
                                          <p className="muted">
                                            {member.inlineDoc}
                                          </p>
                                        ) : (
                                          <p className="muted">
                                            No member-level docs found.
                                          </p>
                                        )}
                                      </article>
                                    ),
                                  )}
                                </div>
                              </section>
                            )}

                          {activeSymbol.kind === "enum" &&
                            (activeSymbol.variants?.length ?? 0) > 0 && (
                              <section className="compound-fields">
                                <h4>Variants</h4>
                                <div className="compound-fields-list">
                                  {(activeSymbol.variants ?? []).map(
                                    (variant) => (
                                      <article
                                        key={`${activeSymbol.name}:${variant.name}:${variant.line}`}
                                        id={`detail-variant:${variant.name}:${variant.line}`}
                                        className={`compound-field-item ${
                                          selectedDetailKey ===
                                          `variant:${variant.name}:${variant.line}`
                                            ? "active"
                                            : ""
                                        }`}
                                        onClick={() => {
                                          setSelectedDetailKey(
                                            `variant:${variant.name}:${variant.line}`,
                                          );
                                        }}
                                      >
                                        <div className="compound-field-head">
                                          <strong>{variant.name}</strong>
                                          <div className="compound-field-meta">
                                            <span className="muted small">
                                              line {variant.line}
                                            </span>
                                            <button
                                              type="button"
                                              className="detail-link-btn"
                                              onClick={(event) => {
                                                event.stopPropagation();
                                                void copyStdlibDetailLink(
                                                  `variant:${variant.name}:${variant.line}`,
                                                );
                                              }}
                                            >
                                              {detailCopyKey ===
                                              `variant:${variant.name}:${variant.line}`
                                                ? "Copied"
                                                : "Permalink"}
                                            </button>
                                          </div>
                                        </div>

                                        {variant.docsMarkdown ? (
                                          <MarkdownWithPlayground
                                            markdown={variant.docsMarkdown}
                                            sourcePath={`stdlib/std/${activeModule.module}`}
                                            enableRunnableFunBlocks={false}
                                          />
                                        ) : variant.inlineDoc ? (
                                          <p className="muted">
                                            {variant.inlineDoc}
                                          </p>
                                        ) : (
                                          <p className="muted">
                                            No variant-level docs found.
                                          </p>
                                        )}
                                      </article>
                                    ),
                                  )}
                                </div>
                              </section>
                            )}
                        </article>
                      )}
                    </div>
                  </div>
                </div>
              </div>
            )}
          </section>
        )}

        {tab === "playground" && (
          <section className="panel">
            <h1>Interactive Playground</h1>
            <p className="lead">
              Edit and run snippets locally with your real Fun compiler.
            </p>
            {isGithubPages && (
              <div
                className="hint"
                style={{ color: "#ff7f9f", borderColor: "#ff7f9f" }}
              >
                Playground is disabled on GitHub Pages because there is no
                backend API available to run code. To use the Playground, run
                the site locally or set up a remote runner API.
              </div>
            )}
            {!isGithubPages && (
              <>
                <div className="hint">
                  Requires zig-out/bin/fun. If missing, run zig build in repo
                  root first.
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
              </>
            )}
          </section>
        )}
      </main>

      {isSearchModalOpen && (
        <div
          className="modal-backdrop"
          onClick={(event) => {
            if (event.target === event.currentTarget) {
              closeSearchModal();
            }
          }}
        >
          <div
            className="modal-card search-modal-card"
            role="dialog"
            aria-modal="true"
            aria-labelledby="global-search-title"
          >
            <div className="modal-head search-modal-head">
              <div>
                <div className="modal-eyebrow">Global Search</div>
                <h2 id="global-search-title">Search everything</h2>
                <p className="muted">
                  Docs, standard library, and playground samples. Press / to
                  open and Enter to jump.
                </p>
              </div>
              <div className="modal-actions">
                <button
                  className="modal-close"
                  type="button"
                  onClick={closeSearchModal}
                >
                  Close
                </button>
              </div>
            </div>

            <div className="search-modal-body">
              <div className="search-modal-input-row">
                <input
                  ref={globalSearchInputRef}
                  id="global-search-input"
                  className="search"
                  type="search"
                  aria-label="Search everything"
                  placeholder="Search everything"
                  value={globalSearch}
                  onChange={(e) => setGlobalSearch(e.target.value)}
                  onKeyDown={(event) => {
                    if (event.key === "ArrowDown") {
                      event.preventDefault();
                      setActiveGlobalResultIndex((prev) => {
                        if (globalResults.length === 0) return -1;
                        return (
                          (prev + 1 + globalResults.length) %
                          globalResults.length
                        );
                      });
                      return;
                    }

                    if (event.key === "ArrowUp") {
                      event.preventDefault();
                      setActiveGlobalResultIndex((prev) => {
                        if (globalResults.length === 0) return -1;
                        return (
                          (prev - 1 + globalResults.length) %
                          globalResults.length
                        );
                      });
                      return;
                    }

                    if (event.key === "Enter") {
                      if (activeGlobalResultIndex < 0) return;
                      event.preventDefault();
                      const selected = globalResults[activeGlobalResultIndex];
                      if (selected) {
                        activateGlobalResult(selected);
                      }
                      return;
                    }

                    if (event.key === "Escape") {
                      event.preventDefault();
                      if (globalSearch.trim()) {
                        setGlobalSearch("");
                        setActiveGlobalResultIndex(-1);
                      } else {
                        closeSearchModal();
                      }
                    }
                  }}
                />
                {globalSearch.trim() && (
                  <button
                    type="button"
                    className="modal-close search-clear-btn"
                    onClick={() => {
                      setGlobalSearch("");
                      setActiveGlobalResultIndex(-1);
                      globalSearchInputRef.current?.focus();
                    }}
                  >
                    Clear
                  </button>
                )}
              </div>

              <div className="search-modal-hint muted small">
                Use ↑ and ↓ to move through results.
              </div>

              {globalSearch.trim() ? (
                <div className="global-results search-modal-results">
                  {globalResults.length === 0 ? (
                    <div className="muted small">No results</div>
                  ) : (
                    globalResultSections.map((section) => {
                      if (section.items.length === 0) return null;

                      return (
                        <section
                          key={section.key}
                          className="global-result-group"
                        >
                          <div className="global-result-group-title muted small">
                            {section.label}
                          </div>
                          {section.items.map((result) => {
                            const absoluteIndex = globalResults.findIndex(
                              (item) => item.id === result.id,
                            );

                            return (
                              <button
                                key={result.id}
                                type="button"
                                className={`global-result-item ${
                                  absoluteIndex === activeGlobalResultIndex
                                    ? "active"
                                    : ""
                                }`}
                                onMouseEnter={() => {
                                  setActiveGlobalResultIndex(absoluteIndex);
                                }}
                                onClick={() => {
                                  activateGlobalResult(result);
                                }}
                              >
                                <div className="global-result-title">
                                  {result.title}
                                </div>
                                <div className="global-result-subtitle muted small">
                                  {result.subtitle}
                                </div>
                              </button>
                            );
                          })}
                        </section>
                      );
                    })
                  )}
                </div>
              ) : (
                <div className="search-empty-state muted">
                  Search docs, modules, symbols, and playground samples.
                </div>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
