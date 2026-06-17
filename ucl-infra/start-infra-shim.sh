#!/usr/bin/env bash
# Start the UCL experiment-infra shim on this GPU box (idempotent).
#
# ROOT-aware: the shim's state (session_key, workspace, runs.json, logs) lives
# under INFRA_SHIM_ROOT (default: the ucl-infra dir). The GPU broker passes a
# per-lease root so multiple concurrent shims never collide. The legacy static
# path leaves INFRA_SHIM_ROOT unset and gets the original single-shim behaviour.
set -euo pipefail
P=/cs/student/project_msc/2025/csml/sruppage
DIR="$P/ucl-infra"
PY="$P/memento-research-dev/.venv/bin/python"
ROOT="${INFRA_SHIM_ROOT:-$DIR}"
LOG="$ROOT/shim.log"
PORT="${INFRA_SHIM_PORT:-8770}"
HOST="${INFRA_SHIM_HOST:-127.0.0.1}"

mkdir -p "$ROOT"
if [ ! -s "$ROOT/session_key" ]; then
  umask 077
  openssl rand -hex 16 > "$ROOT/session_key"
  echo "Generated new session key at $ROOT/session_key"
fi

if curl -fsS -m 3 -X POST "http://$HOST:$PORT/api/list_runs" \
     -H 'Content-Type: application/json' \
     -d "{\"session_key\":\"$(cat "$ROOT/session_key")\"}" >/dev/null 2>&1; then
  echo "Shim already running on :$PORT"
  exit 0
fi

cd "$DIR"
INFRA_SHIM_ROOT="$ROOT" INFRA_SHIM_PORT="$PORT" INFRA_SHIM_HOST="$HOST" nohup "$PY" server.py > "$LOG" 2>&1 &
echo "Shim PID: $!"
# Ready = OUR shim answers. We check /api/list_runs with THIS root's session key,
# not just /docs: a /docs 200 could be a DIFFERENT process that happened to grab
# this port (collision), which would route the lease to the wrong shim. A 200 on
# an authenticated endpoint with our key proves it's the shim we just started.
key="$(cat "$ROOT/session_key")"
for i in $(seq 1 20); do
  if curl -fsS -m 2 -X POST "http://$HOST:$PORT/api/list_runs" \
       -H 'Content-Type: application/json' \
       -d "{\"session_key\":\"$key\"}" 2>/dev/null | grep -q '"runs"'; then
    echo "up after ${i}s on :$PORT (authenticated)"; exit 0
  fi
  sleep 1
done
echo "Shim did not come up (or another process holds :$PORT); last log lines:" >&2
tail -20 "$LOG" >&2
exit 1
