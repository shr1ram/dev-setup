#!/usr/bin/env bash
# gpu-leases.sh [--prune] — list active GPU leases, or prune dead ones.
#
#   gpu-leases.sh            list current leases (human-readable)
#   gpu-leases.sh --json     dump the raw lease file
#   gpu-leases.sh --prune    release leases whose tunnel is dead OR whose shim no
#                            longer answers (reaps GPUs leaked by an app crash /
#                            killed run). Safe to run from cron / the watchdog.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/gpu-broker-lib.sh"
ensure_leases

case "${1:-}" in
  --json) cat "$LEASES"; exit 0 ;;
  --prune)
    # For each lease, a tunnel that no longer LISTENs locally => the run/app is
    # gone; release it (which also stops the now-orphaned shim).
    mapfile -t dead < <(with_leases_lock '
import json, os
d = json.load(open(os.environ["LEASES_PATH"]))
for run_id, e in d.items():
    print(run_id + "\t" + str(e["tunnel_port"]))
')
    n=0
    for row in "${dead[@]}"; do
      [ -n "$row" ] || continue
      rid="${row%%	*}"; tport="${row##*	}"
      if ! port_listening "$tport"; then
        blog "prune: tunnel :$tport for $rid is dead — releasing"
        "$HERE/release-gpu.sh" "$rid" >/dev/null 2>&1 || true
        n=$((n+1))
      fi
    done
    echo "pruned $n dead lease(s)"
    exit 0 ;;
  ""|--list)
    ensure_leases
    LEASES_PATH="$LEASES" python3 -c '
import json, os, time
d = json.load(open(os.environ["LEASES_PATH"]))
if not d:
    print("no active GPU leases"); raise SystemExit
hdr = ("RUN_ID", "BOX", "LOCAL", "TUNNEL", "SHIM", "HOLDER", "AGE")
print("{:<16} {:<20} {:<6} {:<7} {:<6} {:<10} {}".format(*hdr))
now = int(time.time())
for run_id, e in sorted(d.items()):
    age = str(now - e.get("claimed_at", now)) + "s"
    print("{:<16} {:<20} {:<6} {:<7} {:<6} {:<10} {}".format(
        run_id, e["box"], str(e["local"]), e["tunnel_port"], e["shim_port"], e.get("holder", "?"), age))
' ;;
  *) echo "usage: gpu-leases.sh [--prune|--json|--list]" >&2; exit 2 ;;
esac
