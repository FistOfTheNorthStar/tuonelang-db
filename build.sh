#!/usr/bin/env bash
# build.sh — select which parts of tuonelang-db are compiled.
#
# tuonelang has no feature system: `tdg.toml` has no `[features]` table, the
# language has no `#[cfg]` (attributes are a fixed, compiler-known set) and no
# preprocessor, and `tuo` accepts no `--features`/`--cfg`. What it does have is
# the file-list form of every command — "all given files are checked as one
# program" — so the unit of selection is the *file set*, and this script is what
# turns a flag into one.
#
#   ./build.sh --postgresql          core + the PostgreSQL adapter
#   ./build.sh --vector              core + the embedded vector store
#   ./build.sh --core                the backend-neutral layer alone
#   ./build.sh --all                 every backend (default)
#   ./build.sh --postgresql --live   also run the live oracles against a server
#
#   ./build.sh --postgresql --command run --entry examples/live_check.tuo
#
# TUO may be set to a `tuo` binary; otherwise the one on PATH is used.
# Run ./build.sh --help for the full flag list.
set -uo pipefail

TUO="${TUO:-tuo}"

# --- the feature map ---------------------------------------------------------
#
# One line per feature: the flag that selects it, and the sources it pulls in.
# `core` is backend-neutral and is implied by every backend, because every
# backend is written against `db::bytes` and `db::error`.
CORE_SRC=(src/db/*.tuo)
PG_SRC=(src/pg/*.tuo)
VEC_SRC=(src/vec/*.tuo)

want_core=0
want_pg=0
want_vec=0
run_live=0
command="check"
entry=""
explicit=0

usage() {
  cat <<'USAGE'
build.sh — compile a selected subset of tuonelang-db.

FEATURES
  --postgresql      The PostgreSQL adapter (pg::*). Implies --core.
  --vector          The embedded vector store (vec::*). Implies --core.
  --core            The backend-neutral layer alone (db::bytes, db::error,
                    db::math).
  --all             Every feature. The default when no feature flag is given.

ACTIONS
  --command <cmd>   tuo subcommand to run: check (default), verify, fmt, build, run.
  --entry <file>    Program entry to prepend to the file list (for run/build).
  --live            After the static checks, run the live oracles in examples/.
                    The PostgreSQL ones need a running server; the vector one
                    needs only a writable /tmp. Implies --postgresql.
  --list            Print the selected file list and exit without compiling.
  -h, --help        This message.

ENVIRONMENT
  TUO               Path to the `tuo` binary (default: the one on PATH).

EXAMPLES
  ./build.sh --postgresql
  ./build.sh --vector
  ./build.sh --core --command verify
  ./build.sh --postgresql --live
  ./build.sh --postgresql --command run --entry examples/live_check.tuo
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --postgresql|--postgres|--pg) want_pg=1; explicit=1 ;;
    --vector|--vec)               want_vec=1; explicit=1 ;;
    --core)                       want_core=1; explicit=1 ;;
    --all)                        want_pg=1; want_vec=1; want_core=1; explicit=1 ;;
    --live)                       run_live=1; want_pg=1; want_vec=1; explicit=1 ;;
    --list)                       command="list" ;;
    --command)                    shift; command="${1:-}" ;;
    --entry)                      shift; entry="${1:-}" ;;
    -h|--help)                    usage; exit 0 ;;
    *) echo "error: unknown flag '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# No feature flag at all means everything, so a bare ./build.sh still works.
if [ "$explicit" -eq 0 ]; then
  want_pg=1
  want_vec=1
  want_core=1
fi

# Every backend is written against the core, so selecting one selects it.
if [ "$want_pg" -eq 1 ] || [ "$want_vec" -eq 1 ]; then
  want_core=1
fi

# --- assemble the file list --------------------------------------------------
SRC=()
selected=()
if [ "$want_core" -eq 1 ]; then SRC+=("${CORE_SRC[@]}"); selected+=("core"); fi
if [ "$want_pg" -eq 1 ];   then SRC+=("${PG_SRC[@]}");   selected+=("postgresql"); fi
if [ "$want_vec" -eq 1 ];  then SRC+=("${VEC_SRC[@]}");  selected+=("vector"); fi

if [ "${#SRC[@]}" -eq 0 ]; then
  echo "error: no features selected" >&2
  exit 2
fi

if [ "$command" = "list" ]; then
  printf 'features: %s\n' "${selected[*]}"
  printf '%s\n' "${SRC[@]}"
  exit 0
fi

case "$command" in
  check|verify|fmt) ;;
  run|build)
    if [ -z "$entry" ]; then
      echo "error: --command $command needs --entry <file>" >&2
      exit 2
    fi
    ;;
  *) echo "error: unknown --command '$command'" >&2; exit 2 ;;
esac

if ! command -v "$TUO" >/dev/null 2>&1 && [ ! -x "$TUO" ]; then
  echo "error: no \`tuo\` binary found. Set TUO=/path/to/tuo." >&2
  exit 2
fi

printf '=== features: %s ===\n' "${selected[*]}"

failed=0
check() {
  if [ "$1" -eq 0 ]; then echo "PASS $2"; else echo "FAIL $2"; failed=1; fi
}

case "$command" in
  fmt)
    "$TUO" fmt --check "${SRC[@]}"; check $? "fmt --check"
    ;;
  run|build)
    "$TUO" "$command" "$entry" "${SRC[@]}"; check $? "$command $entry"
    ;;
  check|verify)
    "$TUO" "$command" "${SRC[@]}"; check $? "$command"
    ;;
esac

# --- live oracles ------------------------------------------------------------
# These are PostgreSQL-specific by construction: they talk to a real server.
if [ "$run_live" -eq 1 ] && [ "$failed" -eq 0 ]; then
  if [ "$want_pg" -eq 1 ]; then
    printf '\n=== live: protocol oracle ===\n'
    "$TUO" run examples/live_check.tuo "${SRC[@]}"; check $? "live_check"

    printf '\n=== live: guide patterns ===\n'
    "$TUO" run examples/crud_check.tuo "${SRC[@]}"; check $? "crud_check"
  fi

  # The vector oracle needs no server — only a writable /tmp.
  if [ "$want_vec" -eq 1 ]; then
    printf '\n=== live: vector oracle ===\n'
    "$TUO" run examples/vector_check.tuo "${SRC[@]}"; check $? "vector_check"
  fi
fi

printf '\n'
if [ "$failed" -eq 0 ]; then echo "OK (${selected[*]})"; else echo "FAILED (${selected[*]})"; fi
exit "$failed"
