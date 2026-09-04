import { useMemo } from "react";

import {
  highlightToFragment,
  parseStyleAttr,
  useSiteHighlighter,
} from "../utils/shikiHighlighter";

type Props = {
  code: string;
  lang: string;
  inline?: boolean;
  className?: string;
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
}: Props) {
  const highlighter = useSiteHighlighter();

  const fragment = useMemo(() => {
    if (!highlighter) return null;
    return highlightToFragment(highlighter, code, lang);
  }, [highlighter, code, lang]);

  if (!fragment) {
    return inline ? (
      <code className={className}>{code}</code>
    ) : (
      <pre className={className}>
        <code>{code}</code>
      </pre>
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

  return (
    <pre className={shikiClassName} style={style}>
      <code dangerouslySetInnerHTML={{ __html: fragment.innerHtml }} />
    </pre>
  );
}
