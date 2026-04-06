import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import RunCodeBlock from "./RunCodeBlock";
import { highlightFun } from "../utils/funHighlight";

type Props = {
  markdown: string;
  sourcePath?: string;
  headingPrefix?: string;
  enableRunnableFunBlocks?: boolean;
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

  const route =
    headingPrefix === "language" || headingPrefix === "reference"
      ? headingPrefix
      : "";

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
}: Props) {
  const headingCounts = new Map<string, number>();

  const makeHeadingId = (text: string) => {
    const slug = slugifyHeading(text);
    const key = headingPrefix ? `${headingPrefix}-${slug}` : slug;
    const seen = headingCounts.get(key) ?? 0;
    headingCounts.set(key, seen + 1);
    return seen === 0 ? key : `${key}-${seen + 1}`;
  };

  const headingRenderer =
    (Tag: "h1" | "h2" | "h3" | "h4" | "h5" | "h6") =>
    (props: { children?: unknown }) => {
      const text = flattenText(props.children).trim();
      const id = makeHeadingId(text || "section");
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

          if (isBlock && isFun && enableRunnableFunBlocks) {
            return <RunCodeBlock initialCode={text} />;
          }

          if (isBlock) {
            return (
              <pre className="md-pre">
                <code>{text}</code>
              </pre>
            );
          }

          const inlineText = String(children);
          return (
            <code className="md-inline-code">{highlightFun(inlineText)}</code>
          );
        },
      }}
    >
      {markdown}
    </ReactMarkdown>
  );
}
