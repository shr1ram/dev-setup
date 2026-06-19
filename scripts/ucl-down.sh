#!/usr/bin/env bash
# ucl-down.sh — tear DOWN the Memento/AutoResearch stack everywhere.
#
# Sweeps every UCL lab GPU box and stops anything this project left running, so
# a subsequent ucl-up.sh starts from a clean slate on a fresh box (no stale apps
# drifting on a box we moved off of — the exact cause of "the tunnel points at a
# box running old code"). Idempotent and best-effort: a box that's down or has
# nothing running is simply skipped.
#
# What it stops, on each box:
#   - the app worktrees (serve :8000 / dev :8001) via their start.sh stop
#   - the on-demand GPU broker leases (release every lease + prune)
#   - the legacy static infra shim (:8770) and its app-side tunnel (:8771)
#   - the Ollama wake-proxy (:11435)
#
# Usage:
#   ucl-down.sh                 # sweep all lab boxes
#   ucl-down.sh --box HOST ...  # only the named box(es) (alias, e.g. lab-gpu-scaup-l)
#   ucl-down.sh --quiet         # less chatter
set -uo pipefail   # NOTE: no -e; teardown must continue past per-box failures

PROJ=/cs/student/project_msc/2025/csml/sruppage
SSH_CONFIG="$HOME/.ssh/config"
# The lab hosts' ssh config sets `RemoteCommand /bin/bash` + `RequestTTY yes`, so
# `ssh <host>` (no command) forces bash and reads the script on stdin — we do NOT
# override RemoteCommand/RequestTTY here (that would drop back to the csh login
# shell, which mangles the script). Just add batch + timeout + clean control.
SSH_OPTS=(-o ControlMaster=no -o ControlPath=none
          -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

QUIET=false
BOXES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --box) BOXES+=("$2"); shift ;;
    --quiet) QUIET=true ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

info(){ $QUIET || printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok(){   $QUIET || printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }

# All single-GPU lab hosts from ssh config, unless specific boxes were named.
all_boxes() {
  grep -oE 'Host lab-gpu-[^ ]*-l' "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' | sort
}
[ "${#BOXES[@]}" -gt 0 ] || while IFS= read -r h; do [ -n "$h" ] && BOXES+=("$h"); done < <(all_boxes)

# The teardown script run ON each box. PIPED to `bash -s` via stdin (NOT embedded
# in the ssh command line): the lab boxes' LOGIN SHELL IS CSH, which mangles a
# `bash -lc '…'` argument (unmatched quotes, $() , undefined csh vars). Feeding
# the script on stdin to `bash -s` sidesteps csh entirely. $PROJ is interpolated
# here (single value); everything else stays literal ('REMOTE' quoting).
REMOTE_TEARDOWN=$(cat <<REMOTE
set -uo pipefail
PROJ="$PROJ"
# --- apps: stop both worktrees on their ports (start.sh stop is port-aware) ---
for wt in memento-research-serve memento-research-dev; do
  d="\$PROJ/\$wt"
  [ -d "\$d" ] || continue
  for p in 8000 8001; do
    if lsof -tiTCP:"\$p" -sTCP:LISTEN >/dev/null 2>&1; then
      ( cd "\$d" && PORT="\$p" bash start.sh stop >/dev/null 2>&1 ) || true
    fi
  done
done
# Belt-and-braces: kill any leftover app process still bound to 8000/8001.
for p in 8000 8001; do
  pids="\$(lsof -tiTCP:"\$p" -sTCP:LISTEN 2>/dev/null || true)"
  if [ -n "\$pids" ]; then
    echo "\$pids" | xargs kill -TERM 2>/dev/null || true
    sleep 1
    echo "\$pids" | xargs kill -9 2>/dev/null || true
  fi
done
# --- GPU broker: release every lease + prune (frees claimed lab GPUs) ---
if [ -x "\$PROJ/ucl-infra/gpu-leases.sh" ]; then
  rids="\$(bash "\$PROJ/ucl-infra/gpu-leases.sh" --json 2>/dev/null \
          | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
print(" ".join(d.keys()) if isinstance(d, dict) else "")' 2>/dev/null || true)"
  for rid in \$rids; do
    bash "\$PROJ/ucl-infra/release-gpu.sh" "\$rid" >/dev/null 2>&1 || true
  done
  bash "\$PROJ/ucl-infra/gpu-leases.sh" --prune >/dev/null 2>&1 || true
fi
# --- legacy static shim (:8770) + app-side tunnel (:8771) ---
for p in 8770 8771; do
  pids="\$(lsof -tiTCP:"\$p" -sTCP:LISTEN 2>/dev/null || true)"
  [ -n "\$pids" ] && echo "\$pids" | xargs kill -9 2>/dev/null || true
done
pkill -f 'server.py' 2>/dev/null || true
pkill -f 'ssh .*:8771:' 2>/dev/null || true
# --- Ollama wake-proxy (:11435) ---
pids="\$(lsof -tiTCP:11435 -sTCP:LISTEN 2>/dev/null || true)"
[ -n "\$pids" ] && echo "\$pids" | xargs kill -9 2>/dev/null || true
pkill -f 'ollama-proxy' 2>/dev/null || true
echo "TEARDOWN_DONE \$(hostname -s 2>/dev/null || hostname)"
REMOTE
)

info "Tearing down the stack on ${#BOXES[@]} box(es)..."
stopped=0
for box in "${BOXES[@]}"; do
  # ssh with NO command -> the config's `RemoteCommand /bin/bash` runs bash,
  # which reads the teardown script on stdin (the rx.sh pattern). Filter the
  # login banner so the TEARDOWN_DONE marker is detectable.
  out=$(printf '%s\n' "$REMOTE_TEARDOWN" | ssh "${SSH_OPTS[@]}" "$box" 2>/dev/null \
        | grep -vE '^(\*\*|Pseudo-terminal|Warning:|Last login|post-quantum|vulnerable|upgraded|See https|=====|UCL |This is)')
  if printf '%s' "$out" | grep -q TEARDOWN_DONE; then
    ok "cleaned $box"
    stopped=$((stopped + 1))
  fi
done
ok "Teardown complete — $stopped/${#BOXES[@]} box(es) reachable and cleaned."
