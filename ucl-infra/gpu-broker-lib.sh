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

# Box-to-box SSH from the app box to a peer GPU box. We connect by the box's
# FQDN (e.g. wigeon-l.cs.ucl.ac.uk), NOT the lab-gpu-* ssh-config alias: the
# alias carries ProxyJump knuckles + a forced `RemoteCommand /bin/bash` + a
# ControlPath under ~/.ssh/sockets that doesn't exist box-side — all of which
# break a plain `ssh host cmd`. The FQDN resolves on the internal network and
# takes a command argument cleanly. ControlMaster/Path off avoids the socket dir.
SSH_OPTS=(-o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o RequestTTY=no
          -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new)

blog() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$BROKER_LOG"; }

# Reject identifiers that aren't a safe token before they reach shell-eval'd
# command strings or filesystem paths (a crafted run_id/holder could otherwise
# inject commands or escape the leases dir). Allow [A-Za-z0-9._:-] only; ':' is
# permitted for the "llm:<app>" lease-id convention.
#
# CRUCIALLY also reject "." / ".." and any "/" so the id can't traverse out of the
# leases dir — release-gpu.sh does `rm -rf "$DIR/leases/<id>"`, so a "../.." id
# would target (and destroy) parent directories.
valid_id() {
  case "$1" in
    *[!A-Za-z0-9._:-]*|'' ) return 1 ;;   # charset whitelist (no "/")
    .|..|*/* )              return 1 ;;   # exact dot/dotdot, or any slash
    *..* )                  return 1 ;;   # any ".." substring (path traversal)
    *) return 0 ;;
  esac
}

# The box this broker is running on (the app/serving box).
self_fqdn() { hostname -f 2>/dev/null || hostname; }
# lab-gpu-aylesbury-l  <->  aylesbury-l.cs.ucl.ac.uk
fqdn_to_alias() { echo "lab-gpu-${1%%.*}"; }   # aylesbury-l.cs.ucl.ac.uk -> lab-gpu-aylesbury-l
alias_to_fqdn() { echo "${1#lab-gpu-}.cs.ucl.ac.uk"; }

# --- lease file (JSON object keyed by run_id), guarded by flock -----------------
# Seed an empty lease file. MUST be called only while holding the flock — doing
# the size-check+write outside the lock races a concurrent claim/release and can
# clobber leases.json, losing active entries (cubic).
_ensure_leases_locked() { [ -s "$LEASES" ] || echo '{}' > "$LEASES"; }

# run a python snippet against the lease file under an exclusive lock. The python
# reads LEASES (json), receives argv, prints whatever it wants to stdout. The lock
# is on a SEPARATE file ($LEASES_LOCK), so we can acquire it before the data file
# exists, then seed the data file inside the critical section.
with_leases_lock() {  # with_leases_lock <py-snippet> [args...]
  local snippet="$1"; shift
  exec 9>"$LEASES_LOCK"
  flock 9
  _ensure_leases_locked
  LEASES_PATH="$LEASES" python3 -c "$snippet" "$@"
  local rc=$?
  flock -u 9
  return $rc
}

# Seed the lease file if missing, holding the lock (for callers that then read it
# directly, e.g. gpu-leases.sh). Read-only consumers should still expect the file
# to be a complete JSON object since every writer writes it atomically under lock.
ensure_leases() {
  exec 9>"$LEASES_LOCK"
  flock 9
  _ensure_leases_locked
  flock -u 9
}

# Is a TCP port already LISTENing locally?
port_listening() { lsof -tiTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# GPU free? (mirrors gpu-status: <10% util AND <10% mem). Arg: ssh target ("" = local)
gpu_is_free() {  # gpu_is_free <ssh-target-or-empty-for-local>
  local target="$1" out
  if [ -z "$target" ]; then
    out=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1)
  else
    # $target is an alias (lab-gpu-foo-l) — SSH via its FQDN (see SSH_OPTS note).
    # Two gotchas baked in here:
    #  -n           : without it ssh reads stdin; inside a `while read box` loop it
    #                 swallows the remaining loop input and the scan stops after the
    #                 first remote box.
    #  bash -c '...' : the boxes' login shell is csh, which can't parse `2>/dev/null`
    #                 ("Ambiguous output redirect"). Force bash for the command so
    #                 the redirects + pipe work.
    out=$(ssh -n "${SSH_OPTS[@]}" "$(alias_to_fqdn "$target")" \
      "bash -c 'nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1'" 2>/dev/null)
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
