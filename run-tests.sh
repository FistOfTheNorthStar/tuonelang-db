#!/usr/bin/env bash
# run-tests.sh — the whole validation suite for tuonelang-postgresql.
#
#   ./run-tests.sh            specs + formatting (no server needed)
#   ./run-tests.sh --live     also run the live oracles against a real server
#
# TUO may be set to a `tuo` binary; otherwise the one on PATH is used.
set -uo pipefail

TUO="${TUO:-tuo}"
SRC=(src/pg/*.tuo)
failed=0

step() { printf '\n=== %s ===\n' "$1"; }
check() {
  if [ "$1" -eq 0 ]; then echo "PASS $2"; else echo "FAIL $2"; failed=1; fi
}

if ! command -v "$TUO" >/dev/null 2>&1 && [ ! -x "$TUO" ]; then
  echo "error: no \`tuo\` binary found. Set TUO=/path/to/tuo." >&2
  exit 2
fi

step "Front end (check)"
"$TUO" check "${SRC[@]}"; check $? "check"

step "Specs (verify)"
"$TUO" verify "${SRC[@]}"; check $? "verify"

step "Formatting"
"$TUO" fmt --check "${SRC[@]}" examples/*.tuo; check $? "fmt --check"

if [ "${1:-}" = "--live" ]; then
  step "Live: protocol oracle"
  "$TUO" run examples/live_check.tuo "${SRC[@]}"; check $? "live_check"

  step "Live: guide patterns"
  "$TUO" run examples/crud_check.tuo "${SRC[@]}"
  rc=$?
  # crud_check exits with the row count on success paths it verifies; 0 is pass.
  check $((rc == 0 ? 0 : 1)) "crud_check (exit $rc)"
else
  printf '\n(skipping live checks; pass --live to run them against a server)\n'
fi

printf '\n'
if [ "$failed" -eq 0 ]; then echo "all checks passed"; else echo "SOME CHECKS FAILED"; fi
exit "$failed"
