#!/usr/bin/env sh
set -eu

prefix="$HOME/.local"
if [ "${1:-}" = "--prefix" ] && [ -n "${2:-}" ]; then
  prefix="$2"
fi

rm -f "$prefix/bin/fun" || true
rm -f "$prefix/bin/fls" || true
rm -rf "$prefix/share/fun" || true

# Best-effort: remove persisted FUN_STDLIB_DIR block from common shell profiles.
marker_begin="# BEGIN FUN ENV (installed by fun)"
marker_end="# END FUN ENV (installed by fun)"

strip_block() {
  profile="$1"
  [ -f "$profile" ] || return 0
  grep -q "$marker_begin" "$profile" || return 0
  tmp="$(mktemp 2>/dev/null || echo "")"
  if [ -z "$tmp" ]; then
    return 0
  fi
  awk -v b="$marker_begin" -v e="$marker_end" '
    $0==b {inblock=1; next}
    $0==e {inblock=0; next}
    inblock==0 {print}
  ' "$profile" >"$tmp" && mv "$tmp" "$profile" || rm -f "$tmp"
}

strip_block "$HOME/.zshrc"
strip_block "$HOME/.bashrc"
strip_block "$HOME/.bash_profile"
strip_block "$HOME/.config/fish/config.fish"

echo "Uninstalled fun from: $prefix"
