#!/usr/bin/env sh
set -eu

prefix="$HOME/.local"
if [ "${1:-}" = "--prefix" ] && [ -n "${2:-}" ]; then
  prefix="$2"
fi

rm -f "$prefix/bin/fun" || true
rm -f "$prefix/bin/fls" || true
rm -rf "$prefix/share/fun" || true

echo "Uninstalled fun from: $prefix"
