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
# run_id/holder are interpolated into command strings + paths — reject anything
# that isn't a safe token to prevent command/path injection.
valid_id "$RUN_ID"  || { echo '{"error":"invalid run_id"}'; exit 2; }
valid_id "$HOLDER"  || { echo '{"error":"invalid holder"}'; exit 2; }

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

# 3) ATOMICALLY reserve box + ports + key in ONE locked transaction. This closes
#    the select/allocate/persist race (cubic): the scan above is unlocked (it does
#    slow SSH probes), so two concurrent claims could pick the same free box. The
#    reserve RE-CHECKS under the lock that $chosen isn't already leased and that
#    the chosen ports are free, then writes a "reserving" placeholder lease so any
#    concurrent claim sees them taken. If the box was grabbed first, the reserve
#    prints CONFLICT and we bail (the caller can retry).
export SHIM_PORT_BASE TUNNEL_PORT_BASE PORT_SPAN
session_key=$(openssl rand -hex 16)
box_fqdn=$(alias_to_fqdn "$chosen")
reserve=$(RUN_ID="$RUN_ID" CHOSEN="$chosen" CHOSEN_FQDN="$box_fqdn" CHOSEN_LOCAL="$chosen_local" \
          SKEY="$session_key" HOLDER="$HOLDER" with_leases_lock '
import json, os, time
path = os.environ["LEASES_PATH"]
d = json.load(open(path))
run_id = os.environ["RUN_ID"]; box = os.environ["CHOSEN"]
# Re-check under the lock. A finalized idempotent lease for this run_id was
# already returned earlier (before the scan), so ANY entry here -- including one
# keyed by this same run_id -- means a CONCURRENT reservation is in flight; treat
# it as a conflict so two concurrent claims for the same run cannot overwrite each
# other. Likewise any OTHER run already holding this box conflicts.
if run_id in d or any(v["box"] == box for v in d.values()):
    print("CONFLICT"); raise SystemExit
used_s = {v["shim_port"] for v in d.values()}
used_t = {v["tunnel_port"] for v in d.values()}
SB=int(os.environ["SHIM_PORT_BASE"]); TB=int(os.environ["TUNNEL_PORT_BASE"]); N=int(os.environ["PORT_SPAN"])
try:
    sp = next(p for p in range(SB, SB+N) if p not in used_s)
    tp = next(p for p in range(TB, TB+N) if p not in used_t)
except StopIteration:
    print("CONFLICT"); raise SystemExit
# Write a placeholder lease so concurrent claims see this box+ports reserved.
d[run_id] = {"run_id": run_id, "holder": os.environ["HOLDER"], "box": box,
             "box_fqdn": os.environ["CHOSEN_FQDN"], "shim_port": sp, "tunnel_port": tp,
             "session_key": os.environ["SKEY"], "local": os.environ["CHOSEN_LOCAL"] == "true",
             "claimed_at": int(time.time()), "status": "reserving"}
json.dump(d, open(path, "w"), indent=2)
print(sp, tp)
')
if [ "$reserve" = "CONFLICT" ] || [ -z "$reserve" ]; then
  blog "claim $RUN_ID: reserve CONFLICT on $chosen (lost the race) — caller may retry"
  echo '{"error":"no free GPU available"}'
  exit 3
fi
read -r shim_port tunnel_port <<<"$reserve"

# From here the reservation exists; any failure must tear down whatever partially
# started so the box/ports don't leak. We do this DIRECTLY from the local vars
# (shim_port/tunnel_port/box_fqdn/chosen_local) rather than via release-gpu.sh —
# release reads the lease record to find the ports/host, but the failure we most
# need to handle is "the lease record vanished" (concurrent release/prune), where
# release would no-op and leak the shim+tunnel (cubic). Cleared once we finalize.
_reserved=1
cleanup_reservation() {
  [ "${_reserved:-0}" = 1 ] || return 0
  # IMPORTANT: only kill listeners we can confirm are OURS. If the reservation
  # vanished (concurrent release/prune), another claim may have grabbed these same
  # ports and started ITS shim/tunnel — a blind port-based kill would terminate
  # that lease (cubic). So we match on identity, not just the port.

  # Tunnel: kill the ssh -L on tunnel_port ONLY if its command line is exactly our
  # forward (-L 127.0.0.1:<tunnel_port>:127.0.0.1:<shim_port>). A different run's
  # tunnel has a different shim_port in its forward spec.
  # grep -F throughout: the forward spec and the lease root contain '.' chars (and
  # run_id may contain '.'), which as a regex would match unintended strings and
  # could kill the wrong shim/tunnel (cubic). Fixed-string matching only.
  local tp; tp=$(lsof -tiTCP:"${tunnel_port:-0}" -sTCP:LISTEN 2>/dev/null | head -1 || true)
  if [ -n "$tp" ]; then
    if tr '\0' ' ' < "/proc/$tp/cmdline" 2>/dev/null | grep -qF -- "127.0.0.1:${tunnel_port}:127.0.0.1:${shim_port}"; then
      kill "$tp" 2>/dev/null || true
    fi
  fi
  rm -f "$DIR/tunnel-${tunnel_port:-x}.log" 2>/dev/null || true

  # Shim: kill the process on shim_port ONLY if its INFRA_SHIM_ROOT is OUR lease
  # root (leases/$RUN_ID). Another run's shim on a reassigned port has a different
  # root, so it is left alone. Done on the box that owns the shim.
  local root="$DIR/leases/$RUN_ID"
  local sc="for pid in \$(lsof -tiTCP:${shim_port:-0} -sTCP:LISTEN 2>/dev/null); do
      if tr '\0' '\n' < /proc/\$pid/environ 2>/dev/null | grep -qxF \"INFRA_SHIM_ROOT=$root\"; then kill \$pid 2>/dev/null; fi
    done; rm -rf '$root'; true"
  if [ "${chosen_local:-true}" = true ]; then
    bash -c "$sc" >/dev/null 2>&1 || true
  else
    printf '%s\n' "$sc" | ssh "${SSH_OPTS[@]}" "${box_fqdn:-}" bash >/dev/null 2>&1 || true
  fi
  # best-effort drop OUR lease entry (no-op if already gone)
  with_leases_lock '
import json, os, sys
p = os.environ["LEASES_PATH"]; d = json.load(open(p)); d.pop(sys.argv[1], None)
json.dump(d, open(p, "w"), indent=2)
' "$RUN_ID" >/dev/null 2>&1 || true
  blog "claim $RUN_ID: cleanup torn down OUR shim/tunnel (port $shim_port/$tunnel_port)"
}
trap cleanup_reservation EXIT
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
  printf '%s\n%s\n' "$mk_root_cmd" "$start_shim_cmd" \
    | ssh "${SSH_OPTS[@]}" "$box_fqdn" bash >>"$BROKER_LOG" 2>&1 \
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

# 6) Finalize the reservation: drop the "reserving" status so the lease is live.
#    (The placeholder already holds box/ports/key, written atomically in step 3.)
#    If the reservation entry has vanished (e.g. a concurrent release/prune removed
#    it), FAIL — exit non-zero so the EXIT trap tears down the shim/tunnel we
#    started and we don't print success for a lease that isn't persisted.
finalize=$(with_leases_lock '
import json, os, sys
path = os.environ["LEASES_PATH"]
d = json.load(open(path))
e = d.get(sys.argv[1])
if not e:
    print("MISSING"); raise SystemExit
e.pop("status", None)
json.dump(d, open(path, "w"), indent=2)
print("OK")
' "$RUN_ID")
if [ "$finalize" != "OK" ]; then
  blog "claim $RUN_ID: reservation vanished before finalize — aborting (trap will clean up)"
  echo '{"error":"reservation lost before finalize"}'
  exit 1
fi

# Success — keep the lease; disarm the cleanup trap.
_reserved=0
trap - EXIT
blog "claim $RUN_ID: leased $chosen -> localhost:$tunnel_port"
printf '{"run_id":"%s","INFRA_SERVER_URL":"http://127.0.0.1:%d","INFRA_SESSION_KEY":"%s","box":"%s","local":%s}\n' \
  "$RUN_ID" "$tunnel_port" "$session_key" "$chosen" "$chosen_local"
