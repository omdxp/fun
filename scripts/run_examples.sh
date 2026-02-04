#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PER_FILE_TIMEOUT_SEC="${PER_FILE_TIMEOUT_SEC:-120}"
PROGRESS_EVERY="${PROGRESS_EVERY:-6}"

cd "$REPO_ROOT"

if [[ -z "${FUN_STDLIB_DIR:-}" ]]; then
  export FUN_STDLIB_DIR="$REPO_ROOT/stdlib"
fi

# Prefer Windows build output if present (WSL can execute .exe), otherwise use native binary.
FUN_EXE=""
if [[ -f "$REPO_ROOT/zig-out/bin/fun.exe" ]]; then
  FUN_EXE="$REPO_ROOT/zig-out/bin/fun.exe"
elif [[ -f "$REPO_ROOT/zig-out/bin/fun" ]]; then
  FUN_EXE="$REPO_ROOT/zig-out/bin/fun"
else
  echo "Missing zig-out/bin/fun(.exe). Run 'zig build' first." >&2
  exit 2
fi

USE_WINDOWS_PATHS=0
REPO_ROOT_WIN=""
if [[ "$FUN_EXE" == *.exe ]]; then
  USE_WINDOWS_PATHS=1
  if command -v wslpath >/dev/null 2>&1; then
    REPO_ROOT_WIN="$(wslpath -w "$REPO_ROOT")"
  else
    echo "wslpath not found; cannot convert paths for fun.exe" >&2
    exit 2
  fi
fi

to_fun_path() {
  # When executing Windows fun.exe from WSL, pass Windows-style paths.
  local p="$1"
  if [[ $USE_WINDOWS_PATHS -eq 1 ]]; then
    wslpath -w "$p"
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

  # Direct files in examples/error_cases are meant to fail.
  if [[ "$rel" =~ ^examples/error_cases/[^/]+\.fn$ ]]; then
    return 0
  fi

  # Arch-specific asm example is expected to fail on some targets.
  if [[ "$rel" == "examples/advanced/asm_arch_specific.fn" ]]; then
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

run_with_timeout() {
  local -a cmd=("$@")
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status --kill-after=2s "${PER_FILE_TIMEOUT_SEC}s" "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

# Minimal output assertions (only where we have stable strings).
# Format: expected[relpath]=$'line1\nline2\n...'
declare -A expected
expected["examples/test.fn"]=$'The factorial of'
expected["examples/advanced/custom_functions.fn"]=$'The result of subtracting'
expected["examples/advanced/fit_exhaustive_ok.fn"]=$'x was true'
expected["examples/advanced/fit_exhaustive_warning.fn"]=$'x was true'
expected["examples/advanced/for_loops.fn"]=$'arr[0]=1\narr[2]=3'
expected["examples/imports/main.fn"]=$'grand_child\nchild'

mapfile -t files < <(find "$REPO_ROOT/examples" -type f -name '*.fn' | sort)

echo "Running ${#files[@]} example files..."

failed=()
unexpected_pass=()
expected_fail_count=0

idx=0
for full in "${files[@]}"; do
  idx=$((idx + 1))
  if [[ "$PROGRESS_EVERY" -gt 0 ]] && (( idx % PROGRESS_EVERY == 0 )); then
    echo "... $idx/${#files[@]}"
  fi

  rel="${full#"$REPO_ROOT/"}"

  if is_expected_fail "$rel"; then
    # Always compile-only for expected-fail examples.
    in_path="$(to_fun_path "$full")"
    workdir="$REPO_ROOT"
    if [[ $USE_WINDOWS_PATHS -eq 1 ]]; then workdir="$REPO_ROOT_WIN"; fi
    set +e
    out="$(run_with_timeout "$FUN_EXE" -in "$in_path" -no-exec 2>&1)"
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

  if [[ $ec -ne 0 ]]; then
    failed+=("$rel (exit=$ec)")
    continue
  fi

  if [[ -n "${expected[$rel]+x}" ]]; then
    while IFS= read -r needle; do
      [[ -z "$needle" ]] && continue
      if ! grep -Fq -- "$needle" <<<"$out"; then
        failed+=("$rel (missing: $needle)")
        break
      fi
    done <<<"${expected[$rel]}"
  fi

done

echo "Total: ${#files[@]}  Failed: ${#failed[@]}  ExpectedFail: $expected_fail_count  UnexpectedPass: ${#unexpected_pass[@]}"

if [[ ${#failed[@]} -gt 0 ]]; then
  echo
  echo "Failures:"
  printf '%s\n' "${failed[@]}" | sort -u | sed 's/^/FAIL: /'
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
