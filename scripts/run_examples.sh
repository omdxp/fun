#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PER_FILE_TIMEOUT_SEC="${PER_FILE_TIMEOUT_SEC:-120}"
PROGRESS_EVERY="${PROGRESS_EVERY:-6}"
CLEANUP_FUN_CACHE="${CLEANUP_FUN_CACHE:-1}"

cd "$REPO_ROOT"

if [[ -z "${FUN_STDLIB_DIR:-}" ]]; then
  export FUN_STDLIB_DIR="$REPO_ROOT/stdlib"
fi

echo "Using FUN_STDLIB_DIR=$FUN_STDLIB_DIR"

cleanup_leftovers() {
  if [[ "$CLEANUP_FUN_CACHE" -ne 1 ]]; then
    return
  fi

  # Remove compiler cache directories created next to example sources.
  find "$REPO_ROOT/examples" -type d -name ".fun-cache" -prune -exec rm -rf {} + 2>/dev/null || true

  # Remove known example output files created in repo root.
  rm -f \
    "$REPO_ROOT"/temp_*.c \
    "$REPO_ROOT"/main_exit_status_* \
    "$REPO_ROOT"/out.txt \
    "$REPO_ROOT"/out_copy.txt \
    "$REPO_ROOT"/tmp_fun_io.txt \
    "$REPO_ROOT"/_fun_c_file_io_demo.txt \
    "$REPO_ROOT"/_tmp_fs_try.txt 2>/dev/null || true
}

trap cleanup_leftovers EXIT

# Prefer Windows build output if present (WSL can execute .exe), otherwise use native binary.
# Honor a pre-set FUN_EXE (e.g. to run the corpus against a specific build).
FUN_EXE="${FUN_EXE:-}"
if [[ -n "$FUN_EXE" ]]; then
  :
elif [[ -f "$REPO_ROOT/fun-out/bin/fun.exe" ]]; then
  FUN_EXE="$REPO_ROOT/fun-out/bin/fun.exe"
elif [[ -f "$REPO_ROOT/fun-out/bin/fun" ]]; then
  FUN_EXE="$REPO_ROOT/fun-out/bin/fun"
else
  echo "Missing fun-out/bin/fun(.exe). Run 'fun build' first, or set FUN_EXE to point at a built fun binary." >&2
  exit 2
fi

USE_WINDOWS_PATHS=0
REPO_ROOT_WIN=""
WIN_PATH_CONV=""
MSVC_MODE=0
if [[ "${FUN_CC:-}" == "cl" || "${FUN_CC:-}" == "cl.exe" ]]; then
  MSVC_MODE=1
fi
if [[ "$FUN_EXE" == *.exe ]]; then
  USE_WINDOWS_PATHS=1
  if command -v wslpath >/dev/null 2>&1; then
    WIN_PATH_CONV="wslpath"
    REPO_ROOT_WIN="$(wslpath -w "$REPO_ROOT")"
  elif command -v cygpath >/dev/null 2>&1; then
    WIN_PATH_CONV="cygpath"
    REPO_ROOT_WIN="$(cygpath -w "$REPO_ROOT")"
  else
    echo "Neither wslpath nor cygpath found; cannot convert paths for fun.exe" >&2
    exit 2
  fi
fi

to_fun_path() {
  # When executing Windows fun.exe from WSL or Git Bash, pass Windows-style
  # paths but keep forward slashes: fun's basename() splits on '/' so
  # backslashes would prevent it from stripping the directory prefix when
  # it builds the output C path under fun-out/.
  local p="$1"
  if [[ $USE_WINDOWS_PATHS -eq 1 ]]; then
    "$WIN_PATH_CONV" -w "$p" | tr '\\' '/'
  else
    printf '%s' "$p"
  fi
}

is_runnable_file() {
  # runnable if it defines fun main(
  if [[ "$1" == */examples/stdlib/net_http_server.fn ]]; then
    return 1
  fi
  grep -Eq '^[[:space:]]*fun[[:space:]]+main[[:space:]]*\(' "$1"
}

is_expected_fail() {
  local rel="$1"
  # Intentional negative examples.
  if [[ "$rel" == "examples/test_circular.fn" ]]; then
    return 0
  fi

  # Private visibility example should fail.
  if [[ "$rel" == "examples/pub_visibility/private_access.fn" ]]; then
    return 0
  fi

  # Unused variable expect example should fail.
  if [[ "$rel" == "examples/advanced/unused_variable_expect.fn" ]]; then
    return 0
  fi

  # Arch-specific asm example fails during codegen on mismatched targets.
  if [[ "$rel" == "examples/advanced/asm_arch_specific.fn" ]]; then
    return 0
  fi

  # GNU inline asm examples are not supported by MSVC.
  if [[ $MSVC_MODE -eq 1 ]] && [[ "$rel" == "examples/advanced/asm_basic.fn" || \
      "$rel" == "examples/advanced/asm_computed_operand.fn" || \
      "$rel" == "examples/advanced/asm_operands.fn" ]]; then
    return 0
  fi

  # `u256` in this example needs a `_BitInt` past 128 bits, which no
  # compiler CI actually provides today: Apple's clang and
  # mainline LLVM clang both cap `_BitInt` at 128 bits regardless of
  # platform, and Ubuntu's default GCC (13.x) doesn't recognize
  # `_BitInt` as a keyword at all, under any -std flag - only a newer
  # GCC (confirmed on GCC 15) lifts the cap. Expected to fail on every
  # CI platform until CI ships a new enough GCC.
  if [[ "$rel" == "examples/let_and_lowlevel_types.fn" ]]; then
    return 0
  fi

  # Direct files in examples/error_cases are meant to fail.
  if [[ "$rel" =~ ^examples/error_cases/[^/]+\.fn$ ]]; then
    return 0
  fi

  # Circular dependency demonstration (each file fails on its own).
  if [[ "$rel" =~ ^examples/error_cases/circular_dependency/[^/]+\.fn$ ]]; then
    return 0
  fi

  # NOTE: Files under examples/error_cases/duplicate_symbols/* are helper modules;
  # they should compile successfully on their own.
  return 1
}

expected_run_exit_code() {
  local rel="$1"
  if [[ "$rel" == "examples/main_exit_status.fn" ]]; then
    echo 7
    return
  fi
  echo 0
}

run_with_timeout() {
  local -a cmd=("$@")
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status --kill-after=2s "${PER_FILE_TIMEOUT_SEC}s" "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

# Not `declare -A` (bash 4+ only): macOS ships bash 3.2 by default and never
# upgrades it (GPLv3 licensing), so this needs to run on that too.
# `expected_content_for`/`fail_out_write`/`fail_out_read` below replace the
# two associative arrays this used to be with a case statement and a small
# file-backed lookup, both bash-3.2-compatible.
expected_content_for() {
  case "$1" in
    "examples/test.fn") printf '%s' $'The factorial of' ;;
    "examples/advanced/custom_functions.fn") printf '%s' $'The result of subtracting' ;;
    "examples/advanced/fit_exhaustive_ok.fn") printf '%s' $'x was true' ;;
    "examples/advanced/fit_exhaustive_warning.fn") printf '%s' $'x was true' ;;
    "examples/advanced/for_loops.fn") printf '%s' $'arr[0]=1\narr[2]=3' ;;
    "examples/imports/main.fn") printf '%s' $'grand_child\nchild' ;;
    *) return 1 ;;
  esac
}

# `mapfile`/`readarray` are also bash 4+; a plain read loop works everywhere.
files=()
while IFS= read -r f; do
  files+=("$f")
done < <(find "$REPO_ROOT/examples" -type f -name '*.fn' | sort)

echo "Running ${#files[@]} example files..."

failed=()
unexpected_pass=()
expected_fail_count=0

# File-backed stand-in for an associative array keyed by a failed file's
# relative path (there's no bash-3.2 equivalent) -- one file per failure,
# named by the path with '/' replaced so it's a valid filename.
FAIL_OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$FAIL_OUT_DIR"; cleanup_leftovers' EXIT

fail_out_write() {
  local rel="$1" content="$2"
  printf '%s' "$content" >"$FAIL_OUT_DIR/${rel//\//_}"
}

fail_out_read() {
  local rel="$1" f="$FAIL_OUT_DIR/${rel//\//_}"
  [[ -f "$f" ]] && cat "$f"
}

idx=0
for full in "${files[@]}"; do
  idx=$((idx + 1))
  if [[ "$PROGRESS_EVERY" -gt 0 ]] && (( idx % PROGRESS_EVERY == 0 )); then
    echo "... $idx/${#files[@]}"
  fi

  rel="${full#"$REPO_ROOT/"}"

  if is_expected_fail "$rel"; then
    # Run without -no-exec so codegen runs (needed for arch-check errors etc.).
    # All expected-fail files error during Fun compilation before C compilation.
    in_path="$(to_fun_path "$full")"
    workdir="$REPO_ROOT"
    if [[ $USE_WINDOWS_PATHS -eq 1 ]]; then workdir="$REPO_ROOT_WIN"; fi
    set +e
    out="$(run_with_timeout "$FUN_EXE" -in "$in_path" 2>&1)"
    ec=$?
    set -e

    if [[ $ec -eq 0 ]]; then
      unexpected_pass+=("$rel")
    else
      expected_fail_count=$((expected_fail_count + 1))
    fi
    continue
  fi

  runnable=0
  if is_runnable_file "$full"; then
    runnable=1
  fi

  # If not runnable, compile-only.
  in_path="$(to_fun_path "$full")"
  args=("-in" "$in_path")
  if [[ $runnable -eq 0 ]]; then
    args+=("-no-exec")
  fi

  set +e
  out="$(run_with_timeout "$FUN_EXE" "${args[@]}" 2>&1)"
  ec=$?
  set -e

  expected_ec=0
  if [[ $runnable -eq 1 ]]; then
    expected_ec="$(expected_run_exit_code "$rel")"
  fi

  if [[ $ec -ne $expected_ec ]]; then
    failed+=("$rel (exit=$ec)")
    fail_out_write "$rel" "$out"
    continue
  fi

  if expected_content="$(expected_content_for "$rel")"; then
    while IFS= read -r needle; do
      [[ -z "$needle" ]] && continue
      if ! grep -Fq -- "$needle" <<<"$out"; then
        failed+=("$rel (missing: $needle)")
        fail_out_write "$rel" "$out"
        break
      fi
    done <<<"$expected_content"
  fi

done

echo "Total: ${#files[@]}  Failed: ${#failed[@]}  ExpectedFail: $expected_fail_count  UnexpectedPass: ${#unexpected_pass[@]}"

if [[ ${#failed[@]} -gt 0 ]]; then
  echo
  echo "Failures:"
  printf '%s\n' "${failed[@]}" | sort -u | sed 's/^/FAIL: /'

  echo
  echo "Failure details:"
  for item in "${failed[@]}"; do
    rel="${item%% (*}"
    echo "--- $rel ---"
    if captured="$(fail_out_read "$rel")" && [[ -n "$captured" ]]; then
      printf '%s\n' "$captured" | tail -n 40
    else
      echo "(no captured output)"
    fi
  done
fi

if [[ ${#unexpected_pass[@]} -gt 0 ]]; then
  echo
  echo "Unexpected passes (negative examples returned exit 0):"
  printf '%s\n' "${unexpected_pass[@]}" | sort -u | sed 's/^/UNEXPECTED PASS: /'
fi

if [[ ${#failed[@]} -gt 0 ]] || [[ ${#unexpected_pass[@]} -gt 0 ]]; then
  exit 1
fi

exit 0
