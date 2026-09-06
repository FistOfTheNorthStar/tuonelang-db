#!/usr/bin/env bash
# run-tests.sh — the whole validation suite for tuonelang-db.
#
#   ./run-tests.sh                 specs + formatting (no server needed)
#   ./run-tests.sh --live          also run the live oracles against a real server
#   ./run-tests.sh --core          check only the backend-neutral layer
#   ./run-tests.sh --postgresql    check the core + the PostgreSQL adapter
#   ./run-tests.sh --vector        check the core + the embedded vector store
#
# Feature selection is shared with ./build.sh — see its --help for the flags
# and for why the file list, rather than a compiler flag, is what selects a
# feature. With no feature flag, every feature is tested.
#
# TUO may be set to a `tuo` binary; otherwise the one on PATH is used.
set -uo pipefail

TUO="${TUO:-tuo}"

# Split the arguments into feature flags (handed to build.sh, which owns the
# feature map) and the --live switch this script acts on itself.
live=0
features=()
for arg in "$@"; do
  case "$arg" in
    --live) live=1 ;;
    *)      features+=("$arg") ;;
  esac
done

# build.sh --list is the single source of truth for which files a feature set
# selects, so the two scripts can never disagree about it.
# (read -r, not mapfile: macOS ships bash 3.2, which has no mapfile.)
SRC=()
while IFS= read -r line; do
  SRC+=("$line")
done < <(./build.sh "${features[@]+"${features[@]}"}" --list | tail -n +2)
if [ "${#SRC[@]}" -eq 0 ]; then
  echo "error: no sources selected" >&2
  exit 2
fi
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

# Which features are in play decides which oracles can run at all.
have_pg=0
have_vec=0
for f in "${SRC[@]}"; do
  case "$f" in
    src/pg/*)  have_pg=1 ;;
    src/vec/*) have_vec=1 ;;
  esac
done

if [ "$live" -eq 1 ]; then
  if [ "$have_pg" -eq 1 ]; then
    step "Live: protocol oracle"
    "$TUO" run examples/live_check.tuo "${SRC[@]}"; check $? "live_check"

    step "Live: guide patterns"
    "$TUO" run examples/crud_check.tuo "${SRC[@]}"
    rc=$?
    # crud_check exits with the row count on success paths it verifies; 0 is pass.
    check $((rc == 0 ? 0 : 1)) "crud_check (exit $rc)"
  fi

  # The vector oracle writes to /tmp and needs no server, so it runs wherever
  # the feature is selected.
  if [ "$have_vec" -eq 1 ]; then
    step "Live: vector oracle"
    "$TUO" run examples/vector_check.tuo "${SRC[@]}"; check $? "vector_check"

    # The guide's worked example, run and diffed against the output the guide
    # promises — so the documentation cannot drift away from the library.
    step "Live: guide example"
    guide_out=$("$TUO" run examples/guide_example.tuo "${SRC[@]}" 2>&1)
    guide_want=$'red  1.000\ncrimson  0.994'
    if [ "$guide_out" = "$guide_want" ]; then
      check 0 "guide_example (output matches docs/VECTOR_GUIDE.md)"
    else
      printf 'expected:\n%s\ngot:\n%s\n' "$guide_want" "$guide_out"
      check 1 "guide_example (output matches docs/VECTOR_GUIDE.md)"
    fi
  fi
else
  printf '\n(skipping live checks; pass --live to run them against a server)\n'
fi

printf '\n'
if [ "$failed" -eq 0 ]; then echo "all checks passed"; else echo "SOME CHECKS FAILED"; fi
exit "$failed"
