#!/usr/bin/env bash
# gpu-free-scan.sh — report how many UCL lab GPUs are currently free, as JSON.
#
# Used by the app's "UCL GPU" status light (src/onemancompany/api/routes.py
# _scan_ucl_gpu_sync). Reuses gpu-broker-lib.sh's gpu_is_free / candidate_boxes
# (the same scan claim-gpu.sh uses) so "free" means exactly what the broker
# would accept for a claim. SSHes each lab box, so it is SLOW (~seconds × N
# boxes) — the caller caches the result for ~10 minutes.
#
# Prints a single JSON line on stdout: {"free": <int>, "total": <int>}.
# "total" is the number of reachable lab boxes scanned; "free" is how many of
# those have a GPU under the broker's free threshold (<10% util AND <10% mem).
#
# Env:
#   GPU_SCAN_LIMIT  cap the number of boxes scanned (default 30; 0 = no cap).
#   The shared lib lives next to this script.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/gpu-broker-lib.sh"

LIMIT="${GPU_SCAN_LIMIT:-30}"

free=0
total=0
n=0
# candidate_boxes prints the serving box first, then the other lab -l hosts.
while IFS= read -r box; do
  [ -n "$box" ] || continue
  if [ "$LIMIT" -gt 0 ] 2>/dev/null && [ "$n" -ge "$LIMIT" ]; then break; fi
  n=$((n + 1))
  # Local box (the serving host) is checked directly (no SSH); others via SSH.
  if [ "$box" = "$(fqdn_to_alias "$(self_fqdn)")" ]; then
    if gpu_is_free ""; then free=$((free + 1)); fi
    total=$((total + 1))
  else
    # gpu_is_free returns non-zero both for "busy" and "unreachable"; only count
    # a box in `total` if we actually got a reading. Probe reachability cheaply
    # by reusing the same query — a box we can't reach is simply not counted.
    if out=$(ssh -n "${SSH_OPTS[@]}" "$(alias_to_fqdn "$box")" \
          "bash -c 'nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1'" 2>/dev/null) \
       && [ -n "$out" ]; then
      total=$((total + 1))
      IFS=',' read -r util used tot <<<"$out"
      util=$(echo "$util" | tr -dc '0-9'); used=$(echo "$used" | tr -dc '0-9'); tot=$(echo "$tot" | tr -dc '0-9')
      if [ "${tot:-0}" -gt 0 ] 2>/dev/null; then
        pct=$(( used * 100 / tot ))
        if [ "${util:-100}" -lt 10 ] 2>/dev/null && [ "$pct" -lt 10 ]; then
          free=$((free + 1))
        fi
      fi
    fi
  fi
done < <(candidate_boxes)

printf '{"free": %d, "total": %d}\n' "$free" "$total"
