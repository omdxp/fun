import { useMemo } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import RunCodeBlock from "./RunCodeBlock";
import HighlightedCode from "./HighlightedCode";

type Props = {
  markdown: string;
  sourcePath?: string;
  headingPrefix?: string;
  enableRunnableFunBlocks?: boolean;
  dropLeadingH1?: boolean;
};

const REPO_URL = (
  import.meta.env.VITE_REPO_URL ?? "https://github.com/omdxp/fun"
).replace(/\/+$/, "");

function isExternalUrl(href: string) {
  return /^(https?:|mailto:|tel:)/i.test(href);
}

function normalizeRepoPath(rawPath: string, sourcePath?: string) {
  const baseParts = sourcePath
    ? sourcePath.split("/").slice(0, -1).filter(Boolean)
    : [];

  const inParts = rawPath.split("/").filter((p) => p.length > 0);
  const out = rawPath.startsWith("/") ? [] : [...baseParts];

  for (const p of inParts) {
    if (p === ".") continue;
    if (p === "..") {
      if (out.length > 0) out.pop();
      continue;
    }
    out.push(p);
  }

  return out.join("/");
}

function resolveHref(href: string | undefined, sourcePath?: string) {
  if (!href) return href;
  if (href.startsWith("#")) return href;
  if (isExternalUrl(href)) return href;

  const [pathAndQuery, hashPart] = href.split("#", 2);
  const [pathPart, queryPart] = pathAndQuery.split("?", 2);
  const normalizedPath = normalizeRepoPath(pathPart, sourcePath);
  const isFile = /\.[^/]+$/.test(normalizedPath);
  const mode = isFile ? "blob" : "tree";

  let out = `${REPO_URL}/${mode}/main/${normalizedPath}`;
  if (queryPart) out += `?${queryPart}`;
  if (hashPart) out += `#${hashPart}`;
  return out;
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

/**
 * Maps each heading's source line to its assigned id, computed once from
 * the raw markdown text rather than during the h1-h6 render callbacks
 * below. Assigning ids via a mutable counter *during render* is exactly
 * the kind of impure render React 18 StrictMode double-invokes to catch:
 * it calls each heading's render function twice, and a shared, mutated-
 * in-place counter sees both calls, handing out a spurious "-2" suffix
 * even for a heading with no real duplicate. This memo is a pure read at
 * render time; the mutation happens only here, once, off the render path.
 */
function computeHeadingIdsByLine(markdown: string, headingPrefix?: string) {
  const byLine = new Map<number, string>();
  const counts = new Map<string, number>();
  const lines = markdown.split(/\r?\n/);
  let inFence = false;

  lines.forEach((line, index) => {
    if (/^```/.test(line.trim())) {
      inFence = !inFence;
      return;
    }
    if (inFence) return;

    const match = line.match(/^(#{1,6})\s+(.+)$/);
    if (!match) return;

    const title = cleanHeadingText(match[2]) || "section";
    const slug = slugifyHeading(title);
    const key = headingPrefix ? `${headingPrefix}-${slug}` : slug;
    const seen = counts.get(key) ?? 0;
    counts.set(key, seen + 1);
    const id = seen === 0 ? key : `${key}-${seen + 1}`;
    // remark positions are 1-indexed.
    byLine.set(index + 1, id);
  });

  return byLine;
}

function flattenText(node: unknown): string {
  if (typeof node === "string" || typeof node === "number") {
    return String(node);
  }

  if (Array.isArray(node)) {
    return node.map((item) => flattenText(item)).join("");
  }

  if (node && typeof node === "object" && "props" in node) {
    const withProps = node as { props?: { children?: unknown } };
    return flattenText(withProps.props?.children);
  }

  return "";
}

function buildHeadingPermalink(headingPrefix: string | undefined, id: string) {
  if (typeof window === "undefined") return "";

  const route = headingPrefix ?? "";

  if (!route) {
    return `${window.location.origin}${window.location.pathname}${window.location.search}#${id}`;
  }

  const params = new URLSearchParams();
  params.set("anchor", id);
  return `${window.location.origin}${window.location.pathname}${window.location.search}#${route}?${params.toString()}`;
}

async function copyText(text: string) {
  if (typeof window === "undefined" || !text) return;

  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }

  const textArea = document.createElement("textarea");
  textArea.value = text;
  textArea.setAttribute("readonly", "true");
  textArea.style.position = "absolute";
  textArea.style.left = "-9999px";
  document.body.appendChild(textArea);
  textArea.select();
  document.execCommand("copy");
  document.body.removeChild(textArea);
}

export default function MarkdownWithPlayground({
  markdown,
  sourcePath,
  headingPrefix,
  enableRunnableFunBlocks = true,
  dropLeadingH1 = false,
}: Props) {
  // Each doc tab already renders its own <h1> + lead line from DOC_TABS in
  // App.tsx; the source markdown also opens with its own top-level heading
  // (useful when reading the file directly on GitHub). Rendered together
  // that's the same title twice in a row, so the tab view drops the
  // markdown's copy rather than stripping it from the source file itself.
  const effectiveMarkdown = useMemo(() => {
    if (!dropLeadingH1) return markdown;
    return markdown.replace(/^#[^#][^\n]*\n+/, "");
  }, [markdown, dropLeadingH1]);

  const headingIdsByLine = useMemo(
    () => computeHeadingIdsByLine(effectiveMarkdown, headingPrefix),
    [effectiveMarkdown, headingPrefix],
  );

  const headingRenderer =
    (Tag: "h1" | "h2" | "h3" | "h4" | "h5" | "h6") =>
    (props: {
      children?: unknown;
      node?: { position?: { start?: { line?: number } } };
    }) => {
      const text = flattenText(props.children).trim();
      const line = props.node?.position?.start?.line;
      const id =
        (line !== undefined && headingIdsByLine.get(line)) ||
        (headingPrefix ? `${headingPrefix}-section` : "section");
      const permalink = buildHeadingPermalink(headingPrefix, id);
      return (
        <Tag id={id} data-doc-heading="true">
          <span className="md-heading-inner">{props.children}</span>
          {headingPrefix && (
            <button
              type="button"
              className="md-heading-link"
              aria-label={`Copy link to ${text || "section"}`}
              title="Copy heading link"
              onClick={(event) => {
                event.preventDefault();
                event.stopPropagation();
                void copyText(permalink);
              }}
            >
              #
            </button>
          )}
        </Tag>
      );
    };

  return (
    <ReactMarkdown
      className="md-content"
      remarkPlugins={[remarkGfm]}
      components={{
        // `code()` below already returns a full `<pre>` for every block
        // form (a runnable block, a highlighted block, or the plain
        // fallback) - without this override, react-markdown's own default
        // `pre` wraps that in a second, unstyled `<pre>`, doubling the box
        // around every fenced code block.
        pre: (props) => <>{props.children}</>,
        // A wide table needs to scroll horizontally rather than squeeze
        // its columns, but `overflow-x: auto` directly on the <table>
        // (its old home) forces `display: block`, which breaks the
        // browser's own column-width distribution: a table narrower than
        // its container no longer stretches to fill it, leaving a dead
        // gap next to a header background sized to the content instead
        // of the row. Scrolling lives on this wrapper div instead, so the
        // table itself stays a real table and lays out its columns
        // normally.
        table: (props) => (
          <div className="md-table-wrap">
            <table>{props.children}</table>
          </div>
        ),
        h1: headingRenderer("h1"),
        h2: headingRenderer("h2"),
        h3: headingRenderer("h3"),
        h4: headingRenderer("h4"),
        h5: headingRenderer("h5"),
        h6: headingRenderer("h6"),
        a(props) {
          const { href, children } = props;
          const resolved = resolveHref(href, sourcePath);
          const openInNewTab = Boolean(
            resolved &&
            !resolved.startsWith("#") &&
            (resolved !== href || isExternalUrl(resolved)),
          );
          return (
            <a
              href={resolved}
              className={openInNewTab ? "md-external-link" : undefined}
              target={openInNewTab ? "_blank" : undefined}
              rel={openInNewTab ? "noopener noreferrer" : undefined}
            >
              {children}
            </a>
          );
        },
        code(props) {
          const { className, children } = props;
          const text = String(children).replace(/\n$/, "");
          const isBlock = Boolean(className);
          const isFun = className?.includes("language-fun");
          const lang = className?.match(/language-(\w+)/)?.[1];

          if (isBlock && isFun && enableRunnableFunBlocks) {
            return <RunCodeBlock initialCode={text} />;
          }

          if (isBlock && lang) {
            return (
              <HighlightedCode
                code={text}
                lang={lang}
                className="md-pre"
                showCopy
              />
            );
          }

          if (isBlock) {
            return (
              <HighlightedCode
                code={text}
                lang=""
                className="md-pre"
                showCopy
              />
            );
          }

          const inlineText = String(children);
          return (
            <HighlightedCode
              code={inlineText}
              lang="fun"
              inline
              className="md-inline-code"
            />
          );
        },
      }}
    >
      {effectiveMarkdown}
    </ReactMarkdown>
  );
}
