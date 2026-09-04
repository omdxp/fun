/**
 * Copy `text` to the clipboard, throwing on failure so callers can show an
 * accurate "copied" vs "copy failed" state.
 *
 * The async Clipboard API only exists in a secure context (HTTPS or localhost);
 * over plain HTTP `navigator.clipboard` is undefined, so we fall back to the
 * legacy `execCommand('copy')`. That fallback returns a boolean and can silently
 * no-op, so the boolean is honored and a rejection is thrown when the copy did
 * not actually happen, rather than reporting success either way.
 */
export async function copyTextToClipboard(text: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }

  const textArea = document.createElement("textarea");
  textArea.value = text;
  textArea.setAttribute("readonly", "true");
  textArea.style.position = "fixed";
  textArea.style.top = "0";
  textArea.style.left = "-9999px";
  document.body.appendChild(textArea);
  const selection = document.getSelection();
  const previousRange =
    selection && selection.rangeCount > 0 ? selection.getRangeAt(0) : null;
  textArea.focus();
  textArea.select();
  // iOS Safari needs an explicit selection range.
  textArea.setSelectionRange(0, textArea.value.length);
  let ok = false;
  try {
    ok = document.execCommand("copy");
  } finally {
    document.body.removeChild(textArea);
    if (previousRange && selection) {
      selection.removeAllRanges();
      selection.addRange(previousRange);
    }
  }
  if (!ok) {
    throw new Error("Clipboard copy command was rejected by the browser");
  }
}
