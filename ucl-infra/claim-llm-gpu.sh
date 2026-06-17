#!/usr/bin/env bash
# claim-llm-gpu.sh <holder> — claim a dedicated GPU for an app's LOCAL LLM.
#
# Phase 3 of the GPU broker. Mirrors claim-gpu.sh but, instead of an experiment
# shim, it starts the Ollama wake-proxy on the claimed GPU box and returns the
# base URL the app should point DEFAULT_API_BASE_URL at. Claimed ONCE per app at
# startup (not per request), released on app shutdown.
#
# Unlike experiments, the LLM is a long-lived service the app hits constantly, so
# we prefer the app's OWN serving box (zero network hop) and only reach out to a
# remote free box if the local GPU is already taken by another app/lease.
#
# Prints {"holder":"...","DEFAULT_API_BASE_URL":"http://127.0.0.1:<port>/v1",
#         "box":"...","local":true}.  Exit 3 = no free GPU, 1 = error.
# Idempotent per holder (the lease key is "llm:<holder>").
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/gpu-broker-lib.sh"

HOLDER="${1:?usage: claim-llm-gpu.sh <holder>}"
# holder is interpolated into command strings + paths — reject unsafe tokens.
valid_id "$HOLDER" || { echo '{"error":"invalid holder"}'; exit 2; }
LEASE_ID="llm:$HOLDER"
OLLAMA_BASE=11435   # wake-proxy port on the GPU box (loopback)

# Idempotent: existing lease -> return it.
existing=$(with_leases_lock '
import json, os, sys
d = json.load(open(os.environ["LEASES_PATH"]))
e = d.get(sys.argv[1])
print(json.dumps(e) if e else "")
' "$LEASE_ID")
if [ -n "$existing" ]; then
  echo "$existing" | python3 -c 'import json,sys; e=json.load(sys.stdin); print(json.dumps({"holder":e["holder"],"DEFAULT_API_BASE_URL":"http://127.0.0.1:%d/v1"%e["tunnel_port"],"box":e["box"],"local":e["local"]}))'
  exit 0
fi

# Pick a free GPU (serving box first), skipping boxes already leased.
leased_boxes=$(with_leases_lock '
import json, os
d = json.load(open(os.environ["LEASES_PATH"]))
print("\n".join(sorted({v["box"] for v in d.values()})))
')
self_alias=$(fqdn_to_alias "$(self_fqdn)")
chosen=""; chosen_local=false
while read -r box; do
  [ -n "$box" ] || continue
  echo "$leased_boxes" | grep -qx "$box" && continue
  if [ "$box" = "$self_alias" ]; then gpu_is_free "" && { chosen="$box"; chosen_local=true; break; }
  else gpu_is_free "$box" && { chosen="$box"; chosen_local=false; break; }; fi
done < <(candidate_boxes)
[ -n "$chosen" ] || { echo '{"error":"no free GPU available"}'; exit 3; }

# Allocate a private wake-proxy port (on the box) + tunnel port (on app box).
export SHIM_PORT_BASE TUNNEL_PORT_BASE PORT_SPAN
read -r proxy_port tunnel_port < <(with_leases_lock '
import json, os
d = json.load(open(os.environ["LEASES_PATH"]))
used_s = {v["shim_port"] for v in d.values()}
used_t = {v["tunnel_port"] for v in d.values()}
SB=int(os.environ["SHIM_PORT_BASE"]); TB=int(os.environ["TUNNEL_PORT_BASE"]); N=int(os.environ["PORT_SPAN"])
sp = next(p for p in range(SB, SB+N) if p not in used_s)
tp = next(p for p in range(TB, TB+N) if p not in used_t)
print(sp, tp)
')
box_fqdn=$(alias_to_fqdn "$chosen")
blog "claim-llm $HOLDER: chose $chosen (local=$chosen_local) proxy=$proxy_port tunnel=$tunnel_port"

# Start the wake-proxy on the chosen box at proxy_port. Remote: connect by FQDN
# (not the lab-gpu-* alias, which carries ProxyJump/forced-RemoteCommand/socket
# options that break box-to-box ssh) and pipe the command to bash via stdin (the
# login shell is csh). Mirrors claim-gpu.sh's remote shim start.
start_cmd="OLLAMA_PROXY_PORT=$proxy_port bash $DIR/start-ollama-proxy.sh"
if [ "$chosen_local" = true ]; then
  eval "$start_cmd" >>"$BROKER_LOG" 2>&1 || { echo '{"error":"wake-proxy failed (local)"}'; exit 1; }
else
  printf '%s\n' "$start_cmd" | ssh "${SSH_OPTS[@]}" "$box_fqdn" bash >>"$BROKER_LOG" 2>&1 \
    || { echo '{"error":"wake-proxy failed (remote)"}'; exit 1; }
fi

# Tunnel: app box localhost:tunnel_port -> chosen box :proxy_port.
if ! port_listening "$tunnel_port"; then
  setsid ssh "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -N \
    -L "127.0.0.1:$tunnel_port:127.0.0.1:$proxy_port" "$box_fqdn" \
    >>"$DIR/tunnel-$tunnel_port.log" 2>&1 < /dev/null &
  disown || true
fi
ok=false
for i in $(seq 1 15); do port_listening "$tunnel_port" && { ok=true; break; }; sleep 1; done
$ok || { echo '{"error":"llm tunnel failed"}'; exit 1; }

# Record the lease (reuses the shim_port field for the proxy port).
with_leases_lock '
import json, os, sys, time
path = os.environ["LEASES_PATH"]
d = json.load(open(path))
lid, holder, box, box_fqdn, sp, tp, local = sys.argv[1:8]
d[lid] = {"run_id": lid, "holder": holder, "kind": "llm", "box": box, "box_fqdn": box_fqdn,
          "shim_port": int(sp), "tunnel_port": int(tp), "session_key": "",
          "local": local == "true", "claimed_at": int(time.time())}
json.dump(d, open(path, "w"), indent=2)
' "$LEASE_ID" "$HOLDER" "$chosen" "$box_fqdn" "$proxy_port" "$tunnel_port" "$chosen_local" >/dev/null

blog "claim-llm $HOLDER: leased $chosen -> localhost:$tunnel_port"
printf '{"holder":"%s","DEFAULT_API_BASE_URL":"http://127.0.0.1:%d/v1","box":"%s","local":%s}\n' \
  "$HOLDER" "$tunnel_port" "$chosen" "$chosen_local"
