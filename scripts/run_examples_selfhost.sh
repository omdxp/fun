#!/usr/bin/env bash
# Validates the examples/ corpus against the SELF-HOSTED compiler.
#
# selfhost/cli/main.fn is deliberately narrow today (see its own header
# comment): positional args only, compiles straight to a .c file, and
# never shells a C compiler or runs the result. So unlike
# scripts/run_examples.sh (which drives the bootstrap compiler's own
# -in/-no-exec CLI directly), this harness does the "shell cc, run the
# binary" steps itself around the self-hosted binary's one compile step --
# proving codegen-output equivalence without waiting on selfhost's own CLI
# to grow process-spawning support.
#
# Also: selfhost's codegen has no type-checker of its own yet (see
# codegen.fn's own header comment) -- it emits whatever the AST says and
# leans on the C compiler to catch real type errors. So examples/error_cases
# (files that are SUPPOSED to fail a Fun-level type/semantic check) are
# skipped here, not scored as failures -- that's a known, tracked gap
# ([[project_self_hosting_plan]]), not a new regression to chase.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELFHOST_EXE="${SELFHOST_EXE:-}"
CC="${CC:-cc}"
PER_FILE_TIMEOUT_SEC="${PER_FILE_TIMEOUT_SEC:-60}"

cd "$REPO_ROOT"

if [[ -z "$SELFHOST_EXE" || ! -x "$SELFHOST_EXE" ]]; then
  echo "SELFHOST_EXE must point at a built self-hosted compiler binary." >&2
  exit 2
fi

if [[ -z "${FUN_STDLIB_DIR:-}" ]]; then
  export FUN_STDLIB_DIR="$REPO_ROOT/stdlib"
fi

WORKDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORKDIR"
  # Some examples write output files relative to CWD (repo root, since
  # compiled binaries run with `cd "$REPO_ROOT"` below) -- same leftovers
  # scripts/run_examples.sh's own cleanup_leftovers already guards
  # against for the bootstrap compiler's run.
  find "$REPO_ROOT/examples" -type d -name ".fun-cache" -prune -exec rm -rf {} + 2>/dev/null || true
  rm -f \
    "$REPO_ROOT"/temp_*.c \
    "$REPO_ROOT"/main_exit_status_* \
    "$REPO_ROOT"/out.txt \
    "$REPO_ROOT"/out_copy.txt \
    "$REPO_ROOT"/tmp_fun_io.txt \
    "$REPO_ROOT"/_fun_c_file_io_demo.txt \
    "$REPO_ROOT"/_tmp_fs_try.txt 2>/dev/null || true
}
trap cleanup EXIT

run_with_timeout() {
  local -a cmd=("$@")
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status --kill-after=2s "${PER_FILE_TIMEOUT_SEC}s" "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

is_runnable_file() {
  if [[ "$1" == */examples/stdlib/net_http_server.fn ]]; then
    return 1
  fi
  grep -Eq '^[[:space:]]*fun[[:space:]]+main[[:space:]]*\(' "$1"
}

is_skipped() {
  local rel="$1"
  # Negative examples that need a Fun-level type/semantic check selfhost
  # doesn't implement yet -- see this script's own header comment.
  case "$rel" in
    examples/test_circular.fn) return 0 ;;
    examples/pub_visibility/private_access.fn) return 0 ;;
    examples/advanced/unused_variable_expect.fn) return 0 ;;
    examples/advanced/asm_arch_specific.fn) return 0 ;;
    examples/error_cases/*) return 0 ;;
  esac
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

declare -A expected
expected["examples/test.fn"]=$'The factorial of'
expected["examples/advanced/custom_functions.fn"]=$'The result of subtracting'
expected["examples/advanced/fit_exhaustive_ok.fn"]=$'x was true'
expected["examples/advanced/fit_exhaustive_warning.fn"]=$'x was true'
expected["examples/advanced/for_loops.fn"]=$'arr[0]=1\narr[2]=3'
expected["examples/imports/main.fn"]=$'grand_child\nchild'

mapfile -t files < <(find "$REPO_ROOT/examples" -type f -name '*.fn' | sort)

echo "Using SELFHOST_EXE=$SELFHOST_EXE"
echo "Checking ${#files[@]} example files against the self-hosted compiler..."

failed=()
skipped_count=0
declare -A fail_out

idx=0
for full in "${files[@]}"; do
  idx=$((idx + 1))
  rel="${full#"$REPO_ROOT/"}"

  if is_skipped "$rel"; then
    skipped_count=$((skipped_count + 1))
    continue
  fi

  out_c="$WORKDIR/$idx.c"
  out_bin="$WORKDIR/$idx.bin"

  # Pass a repo-relative path, not $full (absolute) -- selfhost's own
  # _normalize_path has a known, pre-existing bug (see
  # [[project_self_hosting_plan]]) that strips a leading empty path segment
  # from an absolute path, turning it into a relative-looking path that
  # fails to resolve. Not what this harness is validating; work around it.
  set +e
  compile_out="$(run_with_timeout "$SELFHOST_EXE" "$rel" "$out_c" 2>&1)"
  compile_ec=$?
  set -e

  if [[ $compile_ec -ne 0 ]]; then
    failed+=("$rel (selfhost compile exit=$compile_ec)")
    fail_out["$rel"]="$compile_out"
    continue
  fi

  runnable=0
  if is_runnable_file "$full"; then
    runnable=1
  fi

  # A helper module (no main()) won't link -- only check it compiles to a
  # valid object, matching the bootstrap script's own -no-exec semantics
  # (compile-only, no linking) for non-runnable files.
  set +e
  if [[ $runnable -eq 1 ]]; then
    cc_out="$("$CC" "$out_c" -o "$out_bin" -pthread 2>&1)"
  else
    cc_out="$("$CC" -c "$out_c" -o "$out_bin.o" 2>&1)"
  fi
  cc_ec=$?
  set -e

  if [[ $cc_ec -ne 0 ]]; then
    failed+=("$rel (cc exit=$cc_ec)")
    fail_out["$rel"]="$cc_out"
    continue
  fi

  if [[ $runnable -eq 0 ]]; then
    continue
  fi

  set +e
  run_out="$(cd "$REPO_ROOT" && run_with_timeout "$out_bin" 2>&1)"
  run_ec=$?
  set -e

  expected_ec="$(expected_run_exit_code "$rel")"
  if [[ $run_ec -ne $expected_ec ]]; then
    failed+=("$rel (run exit=$run_ec, expected=$expected_ec)")
    fail_out["$rel"]="$run_out"
    continue
  fi

  if [[ -n "${expected[$rel]+x}" ]]; then
    while IFS= read -r needle; do
      [[ -z "$needle" ]] && continue
      if ! grep -Fq -- "$needle" <<<"$run_out"; then
        failed+=("$rel (missing: $needle)")
        fail_out["$rel"]="$run_out"
        break
      fi
    done <<<"${expected[$rel]}"
  fi
done

echo "Total: ${#files[@]}  Skipped(no-typecheck-yet): $skipped_count  Failed: ${#failed[@]}"

if [[ ${#failed[@]} -gt 0 ]]; then
  echo
  echo "Failures:"
  printf '%s\n' "${failed[@]}" | sort -u | sed 's/^/FAIL: /'

  echo
  echo "Failure details:"
  for item in "${failed[@]}"; do
    rel="${item%% (*}"
    echo "--- $rel ---"
    if [[ -n "${fail_out[$rel]+x}" ]]; then
      printf '%s\n' "${fail_out[$rel]}" | tail -n 40
    else
      echo "(no captured output)"
    fi
  done
  exit 1
fi

exit 0
