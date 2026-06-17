#!/usr/bin/env bash
# claim-gpu.sh <run_id> [holder] — claim a dedicated GPU for one experiment run.
#
# Finds a free GPU (the app's own serving box first, then other free lab boxes),
# starts an infra shim there on a lease-private port, opens a loopback tunnel
# from this (app) box to it, records the lease, and prints the endpoint as JSON:
#
#   {"run_id":"...","INFRA_SERVER_URL":"http://127.0.0.1:8781",
#    "INFRA_SESSION_KEY":"...","box":"lab-gpu-foo-l","local":true}
#
# Idempotent: claiming the same run_id twice returns the existing lease.
# Exit 0 + JSON on success; exit 3 (no free GPU) or 1 (error) with a JSON
# {"error":"..."} on failure, so callers can branch on rc.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/gpu-broker-lib.sh"

RUN_ID="${1:?usage: claim-gpu.sh <run_id> [holder]}"
HOLDER="${2:-unknown}"

# 1) Already leased? Return it unchanged (idempotent).
existing=$(with_leases_lock '
import json, os, sys
d = json.load(open(os.environ["LEASES_PATH"]))
e = d.get(sys.argv[1])
print(json.dumps(e) if e else "")
' "$RUN_ID")
if [ -n "$existing" ]; then
  blog "claim $RUN_ID: already leased, returning existing"
  echo "$existing" | python3 -c 'import json,sys; e=json.load(sys.stdin); print(json.dumps({"run_id":e["run_id"],"INFRA_SERVER_URL":"http://127.0.0.1:%d"%e["tunnel_port"],"INFRA_SESSION_KEY":e["session_key"],"box":e["box"],"local":e["local"]}))'
  exit 0
fi

# 2) Pick a free GPU box (serving box first). Skip boxes already holding a lease.
leased_boxes=$(with_leases_lock '
import json, os
d = json.load(open(os.environ["LEASES_PATH"]))
print("\n".join(sorted({v["box"] for v in d.values()})))
')

self_alias=$(fqdn_to_alias "$(self_fqdn)")
chosen=""; chosen_local=false
while read -r box; do
  [ -n "$box" ] || continue
  echo "$leased_boxes" | grep -qx "$box" && continue   # already leased to another run
  if [ "$box" = "$self_alias" ]; then
    if gpu_is_free ""; then chosen="$box"; chosen_local=true; break; fi
  else
    if gpu_is_free "$box"; then chosen="$box"; chosen_local=false; break; fi
  fi
done < <(candidate_boxes)

if [ -z "$chosen" ]; then
  blog "claim $RUN_ID: NO free GPU found"
  echo '{"error":"no free GPU available"}'
  exit 3
fi

# 3) Allocate lease-private ports not already in use by another lease.
#    Port-base config is passed via the environment (exported here) because the
#    python snippet reads it from os.environ.
export SHIM_PORT_BASE TUNNEL_PORT_BASE PORT_SPAN
read -r shim_port tunnel_port < <(with_leases_lock '
import json, os
d = json.load(open(os.environ["LEASES_PATH"]))
used_s = {v["shim_port"] for v in d.values()}
used_t = {v["tunnel_port"] for v in d.values()}
SB=int(os.environ["SHIM_PORT_BASE"]); TB=int(os.environ["TUNNEL_PORT_BASE"]); N=int(os.environ["PORT_SPAN"])
sp = next(p for p in range(SB, SB+N) if p not in used_s)
tp = next(p for p in range(TB, TB+N) if p not in used_t)
print(sp, tp)
')

session_key=$(openssl rand -hex 16)
box_fqdn=$(alias_to_fqdn "$chosen")
# Each lease gets its OWN shim ROOT (private session_key + workspace + runs.json),
# so concurrent shims never collide on the shared ucl-infra/ files. server.py
# honours INFRA_SHIM_ROOT. The root lives ON the GPU box; for the local box it's
# just a subdir of ucl-infra/.
lease_root="$DIR/leases/$RUN_ID"
blog "claim $RUN_ID: chose $chosen (local=$chosen_local) shim=$shim_port tunnel=$tunnel_port root=$lease_root"

# 4) Start the shim on the chosen box (loopback), in its private root with its key.
mk_root_cmd="mkdir -p '$lease_root'; umask 077; printf '%s' '$session_key' > '$lease_root/session_key'"
start_shim_cmd="INFRA_SHIM_ROOT='$lease_root' INFRA_SHIM_HOST=127.0.0.1 INFRA_SHIM_PORT=$shim_port bash $DIR/start-infra-shim.sh"
if [ "$chosen_local" = true ]; then
  bash -c "$mk_root_cmd" && eval "$start_shim_cmd" >>"$BROKER_LOG" 2>&1 \
    || { echo '{"error":"shim failed to start (local)"}'; exit 1; }
else
  ssh "${SSH_OPTS[@]}" "$chosen" "bash -lc '$mk_root_cmd; $start_shim_cmd'" >>"$BROKER_LOG" 2>&1 \
    || { echo '{"error":"shim failed to start (remote)"}'; exit 1; }
fi

# 5) Open the loopback tunnel: app box localhost:tunnel_port -> chosen box :shim_port.
#    (When local, the shim is already on this box, so the "tunnel" is a same-box
#     forward; still uniform so release is identical.)
if port_listening "$tunnel_port"; then :; else
  setsid ssh "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -N \
    -L "127.0.0.1:$tunnel_port:127.0.0.1:$shim_port" "$box_fqdn" \
    >>"$DIR/tunnel-$tunnel_port.log" 2>&1 < /dev/null &
  disown || true
fi
ok=false
for i in $(seq 1 15); do port_listening "$tunnel_port" && { ok=true; break; }; sleep 1; done
$ok || { echo '{"error":"tunnel failed to come up"}'; exit 1; }

# 6) Record the lease.
with_leases_lock '
import json, os, sys, time
path = os.environ["LEASES_PATH"]
d = json.load(open(path))
run_id, holder, box, box_fqdn, sp, tp, key, local = sys.argv[1:9]
d[run_id] = {"run_id": run_id, "holder": holder, "box": box, "box_fqdn": box_fqdn,
             "shim_port": int(sp), "tunnel_port": int(tp), "session_key": key,
             "local": local == "true", "claimed_at": int(time.time())}
json.dump(d, open(path, "w"), indent=2)
' "$RUN_ID" "$HOLDER" "$chosen" "$box_fqdn" "$shim_port" "$tunnel_port" "$session_key" "$chosen_local" >/dev/null

blog "claim $RUN_ID: leased $chosen -> localhost:$tunnel_port"
printf '{"run_id":"%s","INFRA_SERVER_URL":"http://127.0.0.1:%d","INFRA_SESSION_KEY":"%s","box":"%s","local":%s}\n' \
  "$RUN_ID" "$tunnel_port" "$session_key" "$chosen" "$chosen_local"
