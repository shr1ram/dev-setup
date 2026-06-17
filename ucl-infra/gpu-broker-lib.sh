#!/usr/bin/env bash
# gpu-broker-lib.sh — shared helpers for the dynamic GPU broker.
#
# The broker hands each experiment run its OWN GPU: it finds a free GPU (the
# app's own serving box first, then other free lab boxes), starts an infra shim
# there, opens a loopback tunnel from the app box to that shim, and records the
# claim in a lease file. release-gpu.sh tears it all down.
#
# This file is sourced by claim-gpu.sh / release-gpu.sh / gpu-leases.sh — it is
# not executed directly. All state lives under $DIR (ucl-infra/).
set -euo pipefail

P=/cs/student/project_msc/2025/csml/sruppage
DIR="$P/ucl-infra"
LEASES="$DIR/leases.json"
LEASES_LOCK="$DIR/leases.lock"
BROKER_LOG="$DIR/broker.log"

# Port pools. Each concurrent lease gets a distinct shim port (on its GPU box)
# and a distinct local tunnel port (on the app box). 8770/8771 stay reserved for
# the legacy static shim so the broker never collides with it.
SHIM_PORT_BASE=8780     # shim listens here ON the GPU box (loopback)
TUNNEL_PORT_BASE=8781   # app box forwards localhost:<this> -> gpu box :shim_port
PORT_SPAN=40            # supports up to ~40 concurrent leases

SSH_OPTS=(-o ControlMaster=no -o ControlPath=none -o BatchMode=yes
          -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new)

blog() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$BROKER_LOG"; }

# The box this broker is running on (the app/serving box).
self_fqdn() { hostname -f 2>/dev/null || hostname; }
# lab-gpu-aylesbury-l  <->  aylesbury-l.cs.ucl.ac.uk
fqdn_to_alias() { echo "lab-gpu-${1%%.*}"; }   # aylesbury-l.cs.ucl.ac.uk -> lab-gpu-aylesbury-l
alias_to_fqdn() { echo "${1#lab-gpu-}.cs.ucl.ac.uk"; }

# --- lease file (JSON object keyed by run_id), guarded by flock -----------------
ensure_leases() { [ -s "$LEASES" ] || echo '{}' > "$LEASES"; }

# run a python snippet against the lease file under an exclusive lock. The python
# reads LEASES (json), receives argv, prints whatever it wants to stdout.
with_leases_lock() {  # with_leases_lock <py-snippet> [args...]
  local snippet="$1"; shift
  ensure_leases
  exec 9>"$LEASES_LOCK"
  flock 9
  LEASES_PATH="$LEASES" python3 -c "$snippet" "$@"
  local rc=$?
  flock -u 9
  return $rc
}

# Is a TCP port already LISTENing locally?
port_listening() { lsof -tiTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# GPU free? (mirrors gpu-status: <10% util AND <10% mem). Arg: ssh target ("" = local)
gpu_is_free() {  # gpu_is_free <ssh-target-or-empty-for-local>
  local target="$1" out
  if [ -z "$target" ]; then
    out=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1)
  else
    out=$(ssh "${SSH_OPTS[@]}" "$target" 'nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1' 2>/dev/null)
  fi
  [ -n "$out" ] || return 1
  local util used total
  IFS=',' read -r util used total <<<"$out"
  util=$(echo "$util" | tr -dc '0-9'); used=$(echo "$used" | tr -dc '0-9'); total=$(echo "$total" | tr -dc '0-9')
  [ "${total:-0}" -gt 0 ] 2>/dev/null || return 1
  local pct=$(( used * 100 / total ))
  [ "${util:-100}" -lt 10 ] 2>/dev/null && [ "$pct" -lt 10 ]
}

# Candidate lab boxes from ssh config (single-GPU -l hosts), serving box first.
candidate_boxes() {
  local self; self=$(fqdn_to_alias "$(self_fqdn)")
  echo "$self"   # always try the local serving box first
  grep -oE 'Host lab-gpu-[^ ]*-l' "$HOME/.ssh/config" 2>/dev/null | awk '{print $2}' \
    | grep -v "^$self\$" | sort
}
