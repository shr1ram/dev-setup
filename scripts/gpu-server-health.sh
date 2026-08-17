#!/usr/bin/env bash
# Health check for our self-served vLLM 27B servers + their grid drivers.
# Usage: ./scripts/gpu-server-health.sh
#
# Reports, per box where WE hold a vLLM server or a grid driver:
#   - server:  is /v1/models reachable, and does a REAL completion succeed?
#              (a server can pass /health yet refuse client connections under
#               load — probe like a worker does, not just a ping)
#   - uptime:  how long the server process has run (stale servers >~36h are a
#              known degradation risk; flagged, not restarted)
#   - driver:  is there a run_pilot/run_grid driver, and does it have a WORKING
#              local server? A driver whose 127.0.0.1 endpoint is dead is an
#              ORPHAN — it writes APIConnectionError into the SHARED NFS ledger,
#              polluting the arm's logs on every box (this bit us 2026-08-17).
#   - errors:  recent APIConnectionError / APITimeoutError count in the arm's
#              grid logs (the client-side signal server /metrics never shows).
#
# This is a CHECK ONLY — it never restarts or kills anything. It prints a
# verdict per box (OK / WARN / BROKEN) so a human decides what to act on.
#
# Assumes the two big TP-2 servers on the standard ports; extend PORTS if more.

set -uo pipefail

SSH_CONFIG="${HOME}/.ssh/config"
REPO="/cs/student/project_msc/2025/csml/sruppage/thesis/auto-research-loop"
TRACES="$REPO/data/traces-final-grid"
API_KEY="x"                       # our servers accept any key
STALE_HOURS=36                    # server uptime past this = WARN (degradation risk)
ERR_WINDOW_MIN=10                 # look back this many minutes for client errors
ERR_WARN=20                       # >this many conn/timeout errors in the window = WARN

# Candidate boxes: the multi-GPU workstations (url-gpu-*) that can serve 27B,
# plus any lab duck we might have put a server on. Discovered from ssh config so
# nothing is hardcoded; a box with no server/driver of ours is silently skipped.
url_hosts=$(grep -o 'Host url-gpu-[^ ]*' "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' | sort)
lab_hosts=$(grep -o 'Host lab-gpu-[^ ]*-l' "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' | sort)
all_hosts=$(printf '%s\n%s' "$url_hosts" "$lab_hosts")

C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_BAD=$'\033[1;31m'; C_DIM=$'\033[2m'; C_0=$'\033[0m'

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10
          -o ServerAliveCountMax=3 -o RemoteCommand=none -o RequestTTY=no
          -o ControlMaster=no -o ControlPath=none)

# Remote payload (runs under `bash -c`, NOT bash -lc: login shell is csh and
# sourcing the NFS profile is slow). Emits key=value lines the local side parses.
# It: (1) lists our api_server procs + their port + uptime; (2) for each, does a
# real completion probe; (3) lists our run_pilot drivers + the port they target +
# whether that port is live locally; (4) counts recent client-side errors in the
# arm's grid logs.
read -r -d '' REMOTE <<'PAYLOAD'
REPO="/cs/student/project_msc/2025/csml/sruppage/thesis/auto-research-loop"
TRACES="$REPO/data/traces-final-grid"
API_KEY="x"; ERR_WINDOW_MIN=10
me=$(id -un)

# --- our vLLM api_server processes: pid, uptime(s), port ---
ps -u "$me" -o pid=,etimes=,args= 2>/dev/null | grep 'vllm.entrypoints.openai.api_server' | grep -v grep | while read -r pid etimes rest; do
  port=$(echo "$rest" | grep -oE '\-\-port [0-9]+' | awk '{print $2}' | head -1)
  [ -z "$port" ] && continue
  # real completion probe (like a worker): tiny request, short cap
  t0=$(date +%s)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $API_KEY" \
    "http://127.0.0.1:$port/v1/chat/completions" \
    -d '{"model":"qwen27b","messages":[{"role":"user","content":"ok"}],"max_tokens":3,"temperature":0}' 2>/dev/null)
  t1=$(date +%s)
  echo "SERVER pid=$pid port=$port uptime_s=$etimes probe_http=$code probe_s=$((t1-t0))"
done

# --- our grid drivers: which arm, which port they target, is that port live? ---
ps -u "$me" -o pid=,args= 2>/dev/null | grep 'run_pilot.py' | grep -v grep | while read -r pid rest; do
  arm=$(echo "$rest" | grep -oE 'final-grid-[a-z0-9-]+' | head -1)
  # the port the driver's workers use = VLLM_BASE_URL in its environ
  purl=$(tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep '^VLLM_BASE_URL=' | head -1 | grep -oE '[0-9]+/v1' | grep -oE '^[0-9]+')
  live="?"
  if [ -n "$purl" ]; then
    lc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$purl/v1/models" 2>/dev/null)
    [ "$lc" = "200" ] && live=yes || live=NO
  fi
  echo "DRIVER pid=$pid arm=$arm target_port=${purl:-none} target_live=$live"
done

# --- recent client-side errors in the grid logs for arms this box drives ---
# (shared NFS: errors from ANY box land here, but counting per-box driver arms
#  localises them enough to flag an orphan.)
for arm in $(ps -u "$me" -o args= 2>/dev/null | grep run_pilot.py | grep -v grep | grep -oE 'final-grid-[a-z0-9-]+' | sort -u); do
  # find the arm's grid ledger dir via any of its manifests' config_hash
  tdir=$(ls -d "$TRACES/${arm#final-grid-}"* 2>/dev/null | head -1)
  [ -z "$tdir" ] && continue
  h=$(find "$tdir" -name manifest.json 2>/dev/null | head -1 | xargs grep -oE '"config_hash": *"[^"]*"' 2>/dev/null | grep -oE '[a-f0-9]{12}' | head -1)
  [ -z "$h" ] && continue
  g="$TRACES/grid/$h"
  conn=$(find "$g" -name '*.log' -newermt "-${ERR_WINDOW_MIN} minutes" 2>/dev/null | xargs -r grep -c 'APIConnectionError' 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
  tout=$(find "$g" -name '*.log' -newermt "-${ERR_WINDOW_MIN} minutes" 2>/dev/null | xargs -r grep -c 'APITimeoutError' 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
  echo "ERRORS arm=$arm conn=$conn timeout=$tout window_min=$ERR_WINDOW_MIN"
done
PAYLOAD

B64=$(printf '%s' "$REMOTE" | base64)

echo "vLLM server health — probing boxes where we hold a server or driver..."
echo ""

tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT

for host in $all_hosts; do
  (
    out=$(ssh "${SSH_OPTS[@]}" "$host" "echo $B64 | base64 -d | bash -c 'eval \"\$(cat)\"'" </dev/null 2>/dev/null <<<"$REMOTE")
    # nothing of ours on this box → skip
    [ -z "$out" ] && exit 0
    {
      echo "### $host"
      echo "$out"
    } > "$tmpdir/$host"
  ) &
done
wait

any=0
for host in $all_hosts; do
  f="$tmpdir/$host"; [ -f "$f" ] || continue
  any=1
  hn=$(sed -n 's/^### //p' "$f")
  echo "${C_0}== $hn =="

  # servers
  grep '^SERVER ' "$f" | while read -r _ kv; do
    eval "$(echo "$kv" | tr ' ' '\n' | sed 's/^/L_/')"
    up_h=$(( L_uptime_s / 3600 ))
    v="$C_OK OK"; note=""
    if [ "$L_probe_http" != "200" ]; then v="$C_BAD BROKEN"; note="completion probe HTTP $L_probe_http (server refusing real work)"
    elif [ "$up_h" -ge "$STALE_HOURS" ]; then v="$C_WARN WARN"; note="uptime ${up_h}h ≥ ${STALE_HOURS}h (stale — connection handling can degrade; consider a fresh restart between arms)"
    else note="uptime ${up_h}h, probe ${L_probe_s}s"; fi
    printf "  server :%b%s%b  port %s  (%s)\n" "$v" "" "$C_0" "$L_port" "$note"
  done

  # drivers (orphan detection: target_live=NO)
  grep '^DRIVER ' "$f" | while read -r _ kv; do
    eval "$(echo "$kv" | tr ' ' '\n' | sed 's/^/L_/')"
    if [ "$L_target_live" = "NO" ]; then
      printf "  driver :%b BROKEN%b  arm %s  → port %s is DEAD (ORPHAN driver: pollutes the shared ledger with APIConnectionError — kill it)\n" "$C_BAD" "$C_0" "$L_arm" "$L_target_port"
    elif [ "$L_target_live" = "yes" ]; then
      printf "  driver :%b OK%b      arm %s  → port %s live\n" "$C_OK" "$C_0" "$L_arm" "$L_target_port"
    else
      printf "  driver :%b WARN%b    arm %s  → no VLLM_BASE_URL in env\n" "$C_WARN" "$C_0" "$L_arm"
    fi
  done

  # client-side error rates
  grep '^ERRORS ' "$f" | while read -r _ kv; do
    eval "$(echo "$kv" | tr ' ' '\n' | sed 's/^/L_/')"
    tot=$(( L_conn + L_timeout ))
    if [ "$tot" -gt "$ERR_WARN" ]; then
      printf "  errors :%b WARN%b    arm %s  conn=%s timeout=%s in last %smin (something upstream is failing — check for an orphan driver on another box)\n" "$C_WARN" "$C_0" "$L_arm" "$L_conn" "$L_timeout" "$L_window_min"
    else
      printf "  errors :%b OK%b      arm %s  conn=%s timeout=%s in last %smin\n" "$C_OK" "$C_0" "$L_arm" "$L_conn" "$L_timeout" "$L_window_min"
    fi
  done
  echo ""
done

if [ "$any" = 0 ]; then
  echo "  (no vLLM servers or grid drivers of ours found on any box)"
fi
echo "${C_DIM}check-only — nothing was restarted or killed. Act on BROKEN/WARN yourself.${C_0}"
