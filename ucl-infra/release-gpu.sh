#!/usr/bin/env bash
# release-gpu.sh <run_id> — release the GPU lease for one run: kill its tunnel,
# stop its shim on the GPU box, and drop the lease entry. Idempotent (a missing
# lease is a no-op, exit 0) so it's safe to call on every run-terminal path.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/gpu-broker-lib.sh"

RUN_ID="${1:?usage: release-gpu.sh <run_id>}"

lease=$(with_leases_lock '
import json, os, sys
d = json.load(open(os.environ["LEASES_PATH"]))
e = d.get(sys.argv[1])
print(json.dumps(e) if e else "")
' "$RUN_ID")

if [ -z "$lease" ]; then
  blog "release $RUN_ID: no lease (no-op)"
  exit 0
fi

read -r box box_fqdn shim_port tunnel_port is_local kind < <(echo "$lease" | python3 -c '
import json,sys
e=json.load(sys.stdin)
print(e["box"], e["box_fqdn"], e["shim_port"], e["tunnel_port"], str(e["local"]).lower(), e.get("kind","exp"))
')

# 1) Kill the loopback tunnel listening on tunnel_port (the ssh -L process).
#    Every step here is best-effort: a release MUST always reach step 3 (drop the
#    lease) even if the tunnel/shim are already gone, so guard against set -e.
tpid=$(lsof -tiTCP:"$tunnel_port" -sTCP:LISTEN 2>/dev/null | head -1 || true)
if [ -n "$tpid" ]; then
  kill "$tpid" 2>/dev/null || true
  blog "release $RUN_ID: killed tunnel pid $tpid (:$tunnel_port)"
fi
rm -f "$DIR/tunnel-$tunnel_port.log" 2>/dev/null || true

# 2) Stop the service on the GPU box bound to shim_port. For an experiment lease
#    that's the server.py shim; for an LLM lease it's the Ollama wake-proxy (and
#    its on-demand `ollama serve`). Match by port so we never kill another
#    lease's service.
if [ "$kind" = "llm" ]; then
  stop_cmd="for pid in \$(lsof -tiTCP:$shim_port -sTCP:LISTEN 2>/dev/null); do kill \$pid 2>/dev/null; done; pkill -f \"ollama-wake-proxy.py\" 2>/dev/null; pkill -f \"ollama serve\" 2>/dev/null; true"
else
  stop_cmd="for pid in \$(lsof -tiTCP:$shim_port -sTCP:LISTEN 2>/dev/null); do kill \$pid 2>/dev/null; done; true"
fi
if [ "$is_local" = true ]; then
  bash -c "$stop_cmd" >/dev/null 2>&1 || true
else
  ssh "${SSH_OPTS[@]}" "$box" "bash -lc '$stop_cmd'" >/dev/null 2>&1 || true
fi
blog "release $RUN_ID: stopped shim on $box :$shim_port"

# 3) Remove the per-lease shim root (private key/workspace/runs.json). Give the
#    shim a moment to actually exit first — pkill is async and a still-open
#    server.py would otherwise keep the dir alive past the rm.
sleep 1
lease_root="$DIR/leases/$RUN_ID"
if [ "$is_local" = true ]; then
  rm -rf "$lease_root" 2>/dev/null || true
else
  ssh "${SSH_OPTS[@]}" "$box" "rm -rf '$lease_root'" 2>/dev/null || true
fi

# 4) Drop the lease.
with_leases_lock '
import json, os, sys
path = os.environ["LEASES_PATH"]
d = json.load(open(path))
d.pop(sys.argv[1], None)
json.dump(d, open(path, "w"), indent=2)
' "$RUN_ID" >/dev/null

blog "release $RUN_ID: lease removed"
echo "released $RUN_ID (box=$box port=$tunnel_port)"
