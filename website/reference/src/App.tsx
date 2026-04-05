import { useEffect, useMemo, useState } from "react";

import MarkdownWithPlayground from "./components/MarkdownWithPlayground";
import RunCodeBlock from "./components/RunCodeBlock";
import { highlightFun } from "./utils/funHighlight";
import bundledContent from "./generated/content.json";

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
    language: string;
    reference: string;
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
  tab: Extract<TabKey, "language" | "reference">;
};

type TocHeading = {
  id: string;
  title: string;
  level: number;
};

const initialContent = bundledContent as ReferenceContent;

type TabKey = "language" | "reference" | "stdlib" | "playground";

const isGithubPages =
  typeof window !== "undefined" &&
  window.location.hostname.endsWith("github.io");
const TABS: Array<{
  key: TabKey;
  label: string;
  disabled?: boolean;
  tooltip?: string;
}> = [
  { key: "language", label: "Language Guide" },
  { key: "reference", label: "Reference" },
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
    tab: "language" as TabKey,
    modulePath: "",
    symbolKey: "",
    detailKey: "",
    docAnchorKey: params.get("anchor") ?? "",
  };
}

function getInitialVersion() {
  if (typeof window === "undefined") {
    return initialContent.funVersion;
  }

  const params = new URLSearchParams(window.location.search);
  return params.get("v") || initialContent.funVersion;
}

function formatSnippet(text: string, q: string) {
  const lower = text.toLowerCase();
  const idx = lower.indexOf(q.toLowerCase());
  if (idx < 0) return text.slice(0, 120);
  const start = Math.max(0, idx - 36);
  const end = Math.min(text.length, idx + q.length + 56);
  return text.slice(start, end).replace(/\s+/g, " ").trim();
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

function extractDocSections(
  markdown: string,
  tab: Extract<TabKey, "language" | "reference">,
) {
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
  const res = await fetch(`./versions/${version}/content.json`, {
    cache: "no-store",
  });
  if (!res.ok) {
    throw new Error(`Failed to load version ${version}`);
  }
  return (await res.json()) as ReferenceContent;
}

export default function App() {
  const initial = getInitialHashState();
  const [content, setContent] = useState<ReferenceContent>(initialContent);
  const [versionList, setVersionList] = useState<string[]>(
    initialContent.versions?.available?.length
      ? initialContent.versions.available
      : [initialContent.funVersion],
  );
  const [selectedVersion, setSelectedVersion] = useState(getInitialVersion());
  const [tab, setTab] = useState<TabKey>(initial.tab);
  const [search, setSearch] = useState("");
  const [globalSearch, setGlobalSearch] = useState("");
  const [activeGlobalResultIndex, setActiveGlobalResultIndex] = useState(-1);
  const [selectedModulePath, setSelectedModulePath] = useState(
    initial.modulePath,
  );
  const [selectedSymbolKey, setSelectedSymbolKey] = useState(initial.symbolKey);
  const [selectedDetailKey, setSelectedDetailKey] = useState(initial.detailKey);
  const [selectedDocAnchorKey, setSelectedDocAnchorKey] = useState(
    initial.docAnchorKey,
  );
  const [activeDocAnchorKey, setActiveDocAnchorKey] = useState("");
  const [languageTocHeadings, setLanguageTocHeadings] = useState<TocHeading[]>(
    [],
  );
  const [referenceTocHeadings, setReferenceTocHeadings] = useState<
    TocHeading[]
  >([]);
  const [isStdlibModalOpen, setIsStdlibModalOpen] = useState(
    Boolean(initial.modulePath || initial.symbolKey),
  );
  const [isVersionLoading, setIsVersionLoading] = useState(false);
  const [copyStatus, setCopyStatus] = useState<"idle" | "ok" | "err">("idle");
  const [detailCopyKey, setDetailCopyKey] = useState("");
  const [isMobileDrawerOpen, setIsMobileDrawerOpen] = useState(false);
  const releaseUrl = `https://github.com/omdxp/fun/releases/tag/v${content.funVersion}`;

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

  const languageSections = useMemo(
    () => extractDocSections(content.docs.language, "language"),
    [content.docs.language],
  );

  const referenceSections = useMemo(
    () => extractDocSections(content.docs.reference, "reference"),
    [content.docs.reference],
  );

  const activeDocSections = useMemo(() => {
    if (tab === "language") return languageTocHeadings;
    if (tab === "reference") return referenceTocHeadings;
    return [] as TocHeading[];
  }, [tab, languageTocHeadings, referenceTocHeadings]);

  const globalResults = useMemo(() => {
    const q = globalSearch.trim().toLowerCase();
    if (!q) return [] as GlobalSearchResult[];

    const out: GlobalSearchResult[] = [];

    for (const section of languageSections) {
      if (!section.content.toLowerCase().includes(q)) continue;
      out.push({
        id: `doc:language:${section.id}`,
        title: `Language Guide: ${section.title}`,
        subtitle: formatSnippet(section.content, q),
        group: "docs",
        tab: "language",
        docAnchorKey: section.id,
      });
    }

    for (const section of referenceSections) {
      if (!section.content.toLowerCase().includes(q)) continue;
      out.push({
        id: `doc:reference:${section.id}`,
        title: `Reference: ${section.title}`,
        subtitle: formatSnippet(section.content, q),
        group: "docs",
        tab: "reference",
        docAnchorKey: section.id,
      });
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
  }, [globalSearch, content, languageSections, referenceSections]);

  const groupedGlobalResults = useMemo(() => {
    return {
      docs: globalResults.filter((r) => r.group === "docs"),
      stdlib: globalResults.filter((r) => r.group === "stdlib"),
      samples: globalResults.filter((r) => r.group === "samples"),
    };
  }, [globalResults]);

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
    if (
      (result.tab === "language" || result.tab === "reference") &&
      result.docAnchorKey
    ) {
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
        const el = document.getElementById("global-search-input");
        el?.focus();
      }
    };

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  useEffect(() => {
    setActiveGlobalResultIndex(globalResults.length > 0 ? 0 : -1);
  }, [globalSearch, globalResults.length]);

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

    const load = async () => {
      try {
        const res = await fetch("./versions/index.json", { cache: "no-store" });
        if (!res.ok) return;
        const index = (await res.json()) as VersionsIndex;
        if (!index.available || index.available.length === 0) return;

        setVersionList(index.available);

        const params = new URLSearchParams(window.location.search);
        const requested = params.get("v");
        const nextVersion =
          requested && index.available.includes(requested)
            ? requested
            : index.latest;
        setSelectedVersion(nextVersion);
      } catch {
        // Fall back to bundled content when versions index is unavailable.
      }
    };

    void load();
  }, []);

  useEffect(() => {
    if (!selectedVersion) return;

    const run = async () => {
      setIsVersionLoading(true);
      try {
        const nextContent = await tryLoadVersionContent(selectedVersion);
        setContent(nextContent);
      } catch {
        setContent(initialContent);
      } finally {
        setIsVersionLoading(false);
      }
    };

    void run();
  }, [selectedVersion]);

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
        setSelectedDocAnchorKey(params.get("anchor") ?? "");
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

    if (tab !== "stdlib") {
      const params = new URLSearchParams();
      if ((tab === "language" || tab === "reference") && selectedDocAnchorKey) {
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
    activeModule,
    activeSymbol,
    selectedDetailKey,
    selectedDocAnchorKey,
  ]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (tab !== "language" && tab !== "reference") return;

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

      if (tab === "language") {
        setLanguageTocHeadings(next);
      } else {
        setReferenceTocHeadings(next);
      }
    }, 0);

    return () => window.clearTimeout(id);
  }, [tab, content]);

  useEffect(() => {
    if (tab !== "language" && tab !== "reference") return;
    if (!selectedDocAnchorKey) return;
    scrollToDocAnchor(selectedDocAnchorKey, "smooth");
  }, [tab, selectedDocAnchorKey, content]);

  useEffect(() => {
    if (tab !== "language" && tab !== "reference") return;
    if (typeof window === "undefined") return;

    const ids = activeDocSections.map((h) => h.id);
    const targets = ids
      .map((id) => document.getElementById(id))
      .filter((el): el is HTMLElement => Boolean(el));

    if (targets.length === 0) return;

    const observer = new IntersectionObserver(
      (entries) => {
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
    if (!activeModule) {
      setIsStdlibModalOpen(false);
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
  }, [activeModule, selectedSymbolKey]);

  useEffect(() => {
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

    setSelectedDetailKey("");
  }, [activeSymbol, selectedDetailKey]);

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
    if (!isStdlibModalOpen) return;

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
  }, [isStdlibModalOpen]);

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

  const copyStdlibDetailLink = async (detailKey: string) => {
    if (typeof window === "undefined") return;
    if (!activeModule) return;
    if (!activeSymbol) return;

    const symbolKey = `${activeSymbol.name}:${activeSymbol.line}`;
    const hash = buildStdlibHash(activeModule.module, symbolKey, detailKey);
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
          <div className="brand">Fun Language Reference</div>
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

        <div
          id="sidebar-drawer-content"
          className={`drawer-content ${isMobileDrawerOpen ? "open" : ""}`}
        >
          <p className="muted drawer-subtitle">
            Interactive docs + local runner
          </p>
          <div className="global-search-wrap">
            <input
              id="global-search-input"
              className="search global-search"
              placeholder="Search everything (/ to focus)"
              value={globalSearch}
              onChange={(e) => setGlobalSearch(e.target.value)}
              onKeyDown={(event) => {
                if (!globalSearch.trim()) return;

                if (event.key === "ArrowDown") {
                  event.preventDefault();
                  setActiveGlobalResultIndex((prev) => {
                    if (globalResults.length === 0) return -1;
                    return (
                      (prev + 1 + globalResults.length) % globalResults.length
                    );
                  });
                  return;
                }

                if (event.key === "ArrowUp") {
                  event.preventDefault();
                  setActiveGlobalResultIndex((prev) => {
                    if (globalResults.length === 0) return -1;
                    return (
                      (prev - 1 + globalResults.length) % globalResults.length
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
                  setGlobalSearch("");
                  setActiveGlobalResultIndex(-1);
                }
              }}
            />
            {globalSearch.trim() && (
              <div className="global-results">
                {globalResults.length === 0 ? (
                  <div className="muted small">No results</div>
                ) : (
                  (
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
                    ] as const
                  ).map((section) => {
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
            )}
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
            {TABS.map((t) => (
              <button
                key={t.key}
                onClick={() => {
                  if (!t.disabled) {
                    setTab(t.key);
                    if (t.key !== "language" && t.key !== "reference") {
                      setSelectedDocAnchorKey("");
                    }
                    setIsMobileDrawerOpen(false);
                  }
                }}
                className={
                  tab === t.key
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
            ))}
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
        {tab === "language" && (
          <section className="panel">
            <h1>Language Features</h1>
            <p className="lead">
              This page is sourced from docs/language.md and includes runnable
              Fun code blocks.
            </p>
            <div className="doc-layout">
              <div className="doc-main">
                <MarkdownWithPlayground
                  markdown={content.docs.language}
                  sourcePath="docs/language.md"
                  headingPrefix="language"
                />
              </div>
              {languageTocHeadings.length > 0 && (
                <aside
                  className="doc-toc"
                  aria-label="Language guide table of contents"
                >
                  <div className="doc-toc-title">On this page</div>
                  {languageTocHeadings
                    .filter((h) => h.level <= 3)
                    .map((heading) => (
                      <button
                        key={heading.id}
                        type="button"
                        className={`doc-toc-item level-${Math.min(heading.level, 3)} ${
                          activeDocAnchorKey === heading.id ? "active" : ""
                        }`}
                        onClick={() => {
                          setSelectedDocAnchorKey(heading.id);
                          scrollToDocAnchor(heading.id, "smooth");
                        }}
                      >
                        {heading.title}
                      </button>
                    ))}
                </aside>
              )}
            </div>
          </section>
        )}

        {tab === "reference" && (
          <section className="panel">
            <h1>Comprehensive Reference</h1>
            <p className="lead">
              Syntax, semantics, runtime behavior, and interop details.
            </p>
            <div className="doc-layout">
              <div className="doc-main">
                <MarkdownWithPlayground
                  markdown={content.docs.reference}
                  sourcePath="docs/reference.md"
                  headingPrefix="reference"
                />
              </div>
              {referenceTocHeadings.length > 0 && (
                <aside
                  className="doc-toc"
                  aria-label="Reference table of contents"
                >
                  <div className="doc-toc-title">On this page</div>
                  {referenceTocHeadings
                    .filter((h) => h.level <= 3)
                    .map((heading) => (
                      <button
                        key={heading.id}
                        type="button"
                        className={`doc-toc-item level-${Math.min(heading.level, 3)} ${
                          activeDocAnchorKey === heading.id ? "active" : ""
                        }`}
                        onClick={() => {
                          setSelectedDocAnchorKey(heading.id);
                          scrollToDocAnchor(heading.id, "smooth");
                        }}
                      >
                        {heading.title}
                      </button>
                    ))}
                </aside>
              )}
            </div>
          </section>
        )}

        {tab === "stdlib" && (
          <section className="panel stdlib-panel">
            <h1>Standard Library Explorer</h1>
            <p className="lead">
              Browse modules, then open one for an immersive, focused deep dive.
            </p>

            <div className="stdlib-toolbar">
              <input
                className="search"
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
                            <code className="fun-inline-code">
                              {highlightFun(s.signature)}
                            </code>
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
                      {activeModule.docsMarkdown ? (
                        <MarkdownWithPlayground
                          markdown={activeModule.docsMarkdown}
                          sourcePath={`stdlib/std/${activeModule.module}`}
                        />
                      ) : (
                        <p className="muted">No module-level docs found.</p>
                      )}

                      {activeSymbol && (
                        <article className="symbol-detail">
                          <h3>
                            {activeSymbol.name}{" "}
                            <span className="muted">
                              (line {activeSymbol.line})
                            </span>
                          </h3>
                          <pre className="fun-block">
                            <code>{highlightFun(activeSymbol.signature)}</code>
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
                                      <pre className="fun-block">
                                        <code>
                                          {highlightFun(field.signature)}
                                        </code>
                                      </pre>
                                      {field.docsMarkdown ? (
                                        <MarkdownWithPlayground
                                          markdown={field.docsMarkdown}
                                          sourcePath={`stdlib/std/${activeModule.module}`}
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
                                        <pre className="fun-block">
                                          <code>
                                            {highlightFun(member.signature)}
                                          </code>
                                        </pre>
                                        {member.docsMarkdown ? (
                                          <MarkdownWithPlayground
                                            markdown={member.docsMarkdown}
                                            sourcePath={`stdlib/std/${activeModule.module}`}
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
    </div>
  );
}
