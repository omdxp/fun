import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import RunCodeBlock from "./RunCodeBlock";

type Props = {
  markdown: string;
  sourcePath?: string;
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

export default function MarkdownWithPlayground({
  markdown,
  sourcePath,
}: Props) {
  return (
    <ReactMarkdown
      className="md-content"
      remarkPlugins={[remarkGfm]}
      components={{
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

          if (isBlock && isFun) {
            return <RunCodeBlock initialCode={text} />;
          }

          if (isBlock) {
            return (
              <pre className="md-pre">
                <code>{text}</code>
              </pre>
            );
          }

          return <code className="md-inline-code">{children}</code>;
        },
      }}
    >
      {markdown}
    </ReactMarkdown>
  );
}
