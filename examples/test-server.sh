#!/usr/bin/env bash
# test-server.sh — the throwaway PostgreSQL server the live oracles talk to.
#
#   examples/test-server.sh start    start it and wait until it accepts connections
#   examples/test-server.sh stop     remove it (the data goes with it)
#   examples/test-server.sh status   say whether it is running
#
# It is a Docker container on a loopback-only port, with credentials that
# exist for no other purpose — so the oracles never need a real server's:
#
#   127.0.0.1:54320   user tuo   database tuo_test   password tuo-test-only
#
# The image's default `pg_hba.conf` demands scram-sha-256 for every TCP
# connection, so a passing live run has authenticated with SCRAM.
#
# PG_IMAGE may name another image (default: postgres:16).
set -uo pipefail

NAME="tuonelang-db-test"
PORT="54320"
IMAGE="${PG_IMAGE:-postgres:16}"

running() {
  [ -n "$(docker ps -q --filter "name=^${NAME}$")" ]
}

case "${1:-}" in
  start)
    if running; then
      echo "$NAME is already running on 127.0.0.1:$PORT"
      exit 0
    fi
    docker run -d --rm --name "$NAME" -p "127.0.0.1:$PORT:5432" \
      -e POSTGRES_USER=tuo -e POSTGRES_DB=tuo_test -e POSTGRES_PASSWORD=tuo-test-only \
      "$IMAGE" >/dev/null || exit 1
    # The image starts a temporary server to initialize, then restarts; the
    # real one is up when the log has said "ready" twice.
    for _ in $(seq 1 60); do
      if [ "$(docker logs "$NAME" 2>&1 | grep -c 'database system is ready to accept connections')" -ge 2 ]; then
        echo "$NAME is ready on 127.0.0.1:$PORT"
        exit 0
      fi
      sleep 1
    done
    echo "error: $NAME did not become ready; see \`docker logs $NAME\`" >&2
    exit 1
    ;;
  stop)
    docker rm -f "$NAME" >/dev/null 2>&1
    echo "$NAME removed"
    ;;
  status)
    if running; then echo "$NAME is running on 127.0.0.1:$PORT"; else echo "$NAME is not running"; exit 1; fi
    ;;
  *)
    echo "usage: $0 start|stop|status" >&2
    exit 2
    ;;
esac
