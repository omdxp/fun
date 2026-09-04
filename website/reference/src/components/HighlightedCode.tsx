import { useMemo, useState } from "react";

import {
  highlightToFragment,
  parseStyleAttr,
  useSiteHighlighter,
} from "../utils/shikiHighlighter";
import { copyTextToClipboard } from "../utils/clipboard";

type Props = {
  code: string;
  lang: string;
  inline?: boolean;
  className?: string;
  showCopy?: boolean;
};

/**
 * Renders `code` highlighted via the site's shared Shiki instance, falling
 * back to plain unstyled text for the brief moment before that instance
 * finishes loading (module load, not per render).
 */
export default function HighlightedCode({
  code,
  lang,
  inline = false,
  className,
  showCopy = false,
}: Props) {
  const highlighter = useSiteHighlighter();
  const [copyStatus, setCopyStatus] = useState<"idle" | "ok" | "err">("idle");

  const fragment = useMemo(() => {
    if (!highlighter) return null;
    return highlightToFragment(highlighter, code, lang);
  }, [highlighter, code, lang]);

  const copyCode = async () => {
    try {
      await copyTextToClipboard(code);
      setCopyStatus("ok");
    } catch {
      setCopyStatus("err");
    }
    window.setTimeout(() => setCopyStatus("idle"), 1600);
  };

  const copyButton = showCopy && !inline && (
    <button
      type="button"
      className="code-copy-btn"
      onClick={copyCode}
      title="Copy code"
    >
      {copyStatus === "ok"
        ? "Copied"
        : copyStatus === "err"
          ? "Copy failed"
          : "Copy"}
    </button>
  );

  if (!fragment) {
    const plainPre = (
      <pre className={className}>
        <code>{code}</code>
      </pre>
    );
    if (inline) return <code className={className}>{code}</code>;
    if (!showCopy) return plainPre;
    return (
      <div className="code-block-shell">
        {copyButton}
        {plainPre}
      </div>
    );
  }

  const style = parseStyleAttr(fragment.style);
  const shikiClassName = className ? `shiki ${className}` : "shiki";

  if (inline) {
    return (
      <code
        className={shikiClassName}
        style={style}
        dangerouslySetInnerHTML={{ __html: fragment.innerHtml }}
      />
    );
  }

  const highlightedPre = (
    <pre className={shikiClassName} style={style}>
      <code dangerouslySetInnerHTML={{ __html: fragment.innerHtml }} />
    </pre>
  );

  if (!showCopy) return highlightedPre;

  return (
    <div className="code-block-shell">
      {copyButton}
      {highlightedPre}
    </div>
  );
}
