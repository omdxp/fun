import { createHighlighterCore, type HighlighterCore } from "shiki/core";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import shellscriptLang from "@shikijs/langs/shellscript";
import yamlLang from "@shikijs/langs/yaml";
import powershellLang from "@shikijs/langs/powershell";
import { useEffect, useState } from "react";

import funGrammarRaw from "../generated/fun.tmLanguage.json";
import funThemeDark from "../generated/fun-web-color-theme.json";
import funThemeLight from "../generated/fun-web-light-color-theme.json";

// The site's own syntax colors are sourced directly from the same VS Code
// theme files the editors use (editors/vscode/themes/fun-web*), so the
// website and every editor share one palette by construction instead of
// a hand-copied CSS approximation that can silently drift out of sync.
const FUN_LANG_NAME = "fun";
const THEME_DARK_NAME = "Fun Web";
const THEME_LIGHT_NAME = "Fun Web Light";

const funGrammar = { ...(funGrammarRaw as Record<string, unknown>), name: FUN_LANG_NAME };

let highlighterPromise: Promise<HighlighterCore> | null = null;

export function getSiteHighlighter(): Promise<HighlighterCore> {
  if (!highlighterPromise) {
    highlighterPromise = createHighlighterCore({
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      langs: [funGrammar as any, shellscriptLang, yamlLang, powershellLang],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      themes: [funThemeDark as any, funThemeLight as any],
      engine: createJavaScriptRegexEngine(),
    });
  }
  return highlighterPromise;
}

/** React hook returning the singleton highlighter once it resolves, null until then. */
export function useSiteHighlighter(): HighlighterCore | null {
  const [highlighter, setHighlighter] = useState<HighlighterCore | null>(null);

  useEffect(() => {
    let cancelled = false;
    getSiteHighlighter()
      .then((h) => {
        if (!cancelled) setHighlighter(h);
      })
      .catch((err) => {
        // Falls back to plain text below; log so a real failure is
        // visibly distinct from the brief "still loading" window.
        console.error("Failed to load the syntax highlighter", err);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return highlighter;
}

/**
 * Renders `code` as dual-theme (light/dark) Shiki HTML for `lang`. Falls
 * back to an escaped, unhighlighted `<pre>` if the language isn't loaded.
 */
export function highlightToHtml(
  highlighter: HighlighterCore,
  code: string,
  lang: string,
): string {
  const loaded = highlighter.getLoadedLanguages();
  const resolvedLang = loaded.includes(lang) ? lang : null;

  if (!resolvedLang) {
    return `<pre class="shiki-fallback"><code>${escapeHtml(code)}</code></pre>`;
  }

  return highlighter.codeToHtml(code, {
    lang: resolvedLang,
    themes: { light: THEME_LIGHT_NAME, dark: THEME_DARK_NAME },
    defaultColor: false,
  });
}

export function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

const SHIKI_HTML_RE = /^<pre[^>]*style="([^"]*)"[^>]*><code>([\s\S]*)<\/code><\/pre>\s*$/;

export type HighlightFragment = {
  style: string;
  innerHtml: string;
};

/**
 * The same highlight as `highlightToHtml`, but split into the outer
 * `<pre>`'s inline style (the `--shiki-*` custom properties) and the
 * inner `<code>`'s HTML, so a caller can drop it into its own `<pre>`/
 * `<code>` elements (needed anywhere that already owns those elements
 * for other reasons, like a scroll-synced editor overlay).
 */
export function highlightToFragment(
  highlighter: HighlighterCore,
  code: string,
  lang: string,
): HighlightFragment {
  const html = highlightToHtml(highlighter, code, lang);
  const match = html.match(SHIKI_HTML_RE);
  if (!match) {
    return { style: "", innerHtml: escapeHtml(code) };
  }
  return { style: match[1], innerHtml: match[2] };
}

/** Parses a `style="..."` attribute string into a React style object. */
export function parseStyleAttr(style: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const decl of style.split(";")) {
    const idx = decl.indexOf(":");
    if (idx === -1) continue;
    const prop = decl.slice(0, idx).trim();
    const value = decl.slice(idx + 1).trim();
    if (prop && value) out[prop] = value;
  }
  return out;
}

export { FUN_LANG_NAME };
