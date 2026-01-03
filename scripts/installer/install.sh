#!/usr/bin/env sh
set -eu

# Usage:
#   ./install.sh [--prefix <dir>]
# Default prefix:
#   $HOME/.local

prefix="$HOME/.local"
if [ "${1:-}" = "--prefix" ] && [ -n "${2:-}" ]; then
  prefix="$2"
fi

bundle_root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
src_bin="$bundle_root/bin"
src_share="$bundle_root/share/fun"

if [ ! -d "$src_bin" ]; then
  echo "Missing 'bin' directory next to installer" >&2
  exit 1
fi
if [ ! -d "$src_share" ]; then
  echo "Missing 'share/fun' directory next to installer" >&2
  exit 1
fi

dest_bin="$prefix/bin"
dest_share="$prefix/share/fun"

mkdir -p "$dest_bin" "$dest_share"

# Copy binaries
cp -f "$src_bin/fun" "$dest_bin/fun" 2>/dev/null || cp -f "$src_bin/fun.exe" "$dest_bin/fun"
cp -f "$src_bin/fls" "$dest_bin/fls" 2>/dev/null || cp -f "$src_bin/fls.exe" "$dest_bin/fls"
chmod 755 "$dest_bin/fun" "$dest_bin/fls" || true

# Copy stdlib signatures
mkdir -p "$prefix/share"
cp -R "$src_share" "$prefix/share/"

echo "Installed fun to: $prefix"
echo "Installed fls to: $prefix"
echo "Stdlib installed to: $dest_share"
echo "Ensure $dest_bin is on your PATH."
