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
for i in $(seq 1 20); do
  curl -fsS -m 2 "http://$HOST:$PORT/docs" >/dev/null 2>&1 && { echo "up after ${i}s on :$PORT"; exit 0; }
  sleep 1
done
echo "Shim did not come up; last log lines:" >&2
tail -20 "$LOG" >&2
exit 1
