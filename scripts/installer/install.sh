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
dest_stdlib="$dest_share"

mkdir -p "$dest_bin" "$dest_share"

# Copy binaries
cp -f "$src_bin/fun" "$dest_bin/fun" 2>/dev/null || cp -f "$src_bin/fun.exe" "$dest_bin/fun"
cp -f "$src_bin/fls" "$dest_bin/fls" 2>/dev/null || cp -f "$src_bin/fls.exe" "$dest_bin/fls"
chmod 755 "$dest_bin/fun" "$dest_bin/fls" || true

# Copy stdlib signatures
mkdir -p "$prefix/share"
cp -R "$src_share" "$prefix/share/"

# Write an env snippet for shells/tools to pick up.
env_snippet="$dest_share/env.sh"
mkdir -p "$dest_share"
cat >"$env_snippet" <<EOF
# Fun environment
export FUN_STDLIB_DIR="$dest_stdlib"
EOF

# Persist FUN_STDLIB_DIR into the user's shell profile (best-effort).
# We keep this idempotent via a marked block.
marker_begin="# BEGIN FUN ENV (installed by fun)"
marker_end="# END FUN ENV (installed by fun)"

shell_path="${SHELL:-}"
shell_name="${shell_path##*/}"

append_block_sh() {
  profile="$1"
  mkdir -p "$(dirname -- "$profile")" 2>/dev/null || true
  if [ -f "$profile" ] && grep -q "$marker_begin" "$profile"; then
    return 0
  fi
  {
    echo
    echo "$marker_begin"
    echo ". \"$env_snippet\""
    echo "$marker_end"
  } >>"$profile"
}

append_block_fish() {
  profile="$1"
  mkdir -p "$(dirname -- "$profile")" 2>/dev/null || true
  if [ -f "$profile" ] && grep -q "$marker_begin" "$profile"; then
    return 0
  fi
  {
    echo
    echo "$marker_begin"
    echo "set -gx FUN_STDLIB_DIR \"$dest_stdlib\""
    echo "$marker_end"
  } >>"$profile"
}

persisted="no"
case "$shell_name" in
  zsh)
    append_block_sh "$HOME/.zshrc" && persisted="yes"
    ;;
  bash)
    # Prefer an existing profile file; otherwise default to .bashrc.
    if [ -f "$HOME/.bashrc" ]; then
      append_block_sh "$HOME/.bashrc" && persisted="yes"
    elif [ -f "$HOME/.bash_profile" ]; then
      append_block_sh "$HOME/.bash_profile" && persisted="yes"
    else
      append_block_sh "$HOME/.bashrc" && persisted="yes"
    fi
    ;;
  fish)
    append_block_fish "$HOME/.config/fish/config.fish" && persisted="yes"
    ;;
  *)
    persisted="no"
    ;;
esac

echo "Installed fun to: $prefix"
echo "Installed fls to: $prefix"
echo "Stdlib installed to: $dest_share"
echo "FUN_STDLIB_DIR snippet: $env_snippet"
if [ "$persisted" = "yes" ]; then
  echo "FUN_STDLIB_DIR persisted for shell: $shell_name"
else
  echo "To enable in your shell: . \"$env_snippet\""
fi
echo "Ensure $dest_bin is on your PATH."
