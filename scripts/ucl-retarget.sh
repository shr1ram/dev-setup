#!/usr/bin/env bash
# ucl-retarget.sh — point the Mac->app tunnel at whatever box is ACTUALLY
# serving the Memento/AutoResearch app, without tearing anything down.
#
# Why this exists: ucl-up.sh writes ~/dev-setup/ucl-hosts.env and reloads the
# tunnel, but it ALSO tears everything down first (clean redeploy). When the app
# gets (re)started manually on a box — e.g. after a box reboot, or starting the
# serve+dev worktrees by hand — ucl-hosts.env goes stale and the tunnel keeps
# forwarding to the OLD box, so localhost:8000/8001 break with "connection
# refused" even though the apps are healthy. This script fixes that symptom at
# its source: it DISCOVERS the serving box, rewrites ucl-hosts.env, and reloads
# the tunnel. Idempotent, no teardown, no redeploy.
#
# Usage:
#   ucl-retarget.sh                 # auto-discover the serving box and retarget
#   ucl-retarget.sh HOST            # force a box (short alias, e.g. lab-gpu-scaup-l)
#   ucl-retarget.sh --dry-run       # show what it would write, change nothing
set -euo pipefail

HOSTS_ENV="$HOME/dev-setup/ucl-hosts.env"
SSH_CONFIG="$HOME/.ssh/config"
SSH_OPTS=(-o RemoteCommand=none -o RequestTTY=no -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new)
LAUNCH_LABEL="com.shr1ram.ucl-app-tunnel"
# Ports the app worktrees serve on (serve -> 8000, dev -> 8001). A box "serves"
# if either is listening.
APP_PORTS=(8000 8001)

info(){ printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok(){ printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die(){ printf '\033[0;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

PIN=""; DRY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=true ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    lab-gpu-*) PIN="$1" ;;
    *) die "unknown arg: $1 (expected a lab-gpu-*-l host, --dry-run, or --help)" ;;
  esac
  shift
done

fqdn(){ echo "${1#lab-gpu-}" | sed 's/$/.cs.ucl.ac.uk/'; }  # lab-gpu-scaup-l -> scaup-l.cs.ucl.ac.uk

# Is HOST currently serving the app on any APP_PORT? Returns 0 (true) if so.
# The remote side prints SERVING when a listener exists on any app port; we build
# the alternation from APP_PORTS (":8000|:8001") and grep for it. (Deliberately
# NOT using printf %q — it mangled the regex; a plain string is correct here.)
host_serving() {
  local h="$1" alt
  alt="$(printf ':%s|' "${APP_PORTS[@]}")"; alt="${alt%|}"   # -> ":8000|:8001"
  ssh "${SSH_OPTS[@]}" "$h" "bash -lc 'ss -ltn 2>/dev/null | grep -qE \"$alt\" && echo SERVING'" 2>/dev/null | grep -q SERVING
}

APP=""
if [ -n "$PIN" ]; then
  APP="$PIN"
  info "Pinned to $APP (skipping discovery)."
else
  # Scan all lab boxes in parallel; first one found serving wins. Prefer the box
  # the tunnel ALREADY points at if it is still serving (avoids needless churn).
  hosts=$(grep -o 'Host lab-gpu-[^ ]*-l' "$SSH_CONFIG" | awk '{print $2}' | sort -u)
  current=""
  [ -f "$HOSTS_ENV" ] && current="$(awk -F= '/^UCL_APP_HOST=/{print $2; exit}' "$HOSTS_ENV")"
  info "Scanning lab boxes for the one(s) serving the app on :${APP_PORTS[*]} ..."
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  for h in $hosts; do
    ( host_serving "$h" && echo "$h" > "$tmp/hit.$h" ) &
  done
  wait
  SERVING=()
  for h in $hosts; do
    [ -f "$tmp/hit.$h" ] && SERVING+=("$h")
  done

  if [ "${#SERVING[@]}" -eq 0 ]; then
    die "no lab box is serving the app on :${APP_PORTS[*]}. Start it (bash start.sh start in a worktree) or run ucl-up.sh."
  elif [ "${#SERVING[@]}" -eq 1 ]; then
    APP="${SERVING[0]}"
    ok "found app serving on $APP"
  else
    # Ambiguous: more than one box is serving (usually a stale deployment left
    # running on an old box). Don't guess — but prefer the box the tunnel already
    # points at if it is among them (no churn), else require an explicit pick.
    warn "MORE THAN ONE box is serving: ${SERVING[*]}"
    warn "This usually means a stale deployment is still up on an old box."
    if [ -n "$current" ] && printf '%s\n' "${SERVING[@]}" | grep -qx "$current"; then
      APP="$current"
      info "Keeping the current target $APP (it is among the serving boxes)."
      info "To switch, re-run: ucl-retarget.sh <host>   (and consider stopping the stale box)."
    else
      die "Ambiguous — pick one explicitly: ucl-retarget.sh <host>   (serving: ${SERVING[*]})"
    fi
  fi
fi

NEW_HOST="$APP"; NEW_FQDN="$(fqdn "$APP")"

if $DRY; then
  info "(dry-run) would set UCL_APP_HOST=$NEW_HOST / UCL_APP_FQDN=$NEW_FQDN and reload the tunnel."
  exit 0
fi

# Rewrite ONLY the app host/fqdn lines; leave UCL_INFRA_* untouched (the broker
# manages infra per-run). Create the file if missing.
if [ -f "$HOSTS_ENV" ] && grep -q '^UCL_APP_HOST=' "$HOSTS_ENV"; then
  tmp_env=$(mktemp)
  sed -e "s|^UCL_APP_HOST=.*|UCL_APP_HOST=$NEW_HOST|" \
      -e "s|^UCL_APP_FQDN=.*|UCL_APP_FQDN=$NEW_FQDN|" "$HOSTS_ENV" > "$tmp_env"
  mv "$tmp_env" "$HOSTS_ENV"
else
  cat > "$HOSTS_ENV" <<EOF
# UCL host selection — written by ucl-retarget.sh
UCL_APP_HOST=$NEW_HOST
UCL_APP_FQDN=$NEW_FQDN
EOF
fi
ok "ucl-hosts.env -> app=$NEW_HOST ($NEW_FQDN)"

# Reload the Mac->app tunnel LaunchAgent so it reconnects to the new box.
PLIST="$HOME/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
if [ -f "$PLIST" ]; then
  info "Reloading Mac app tunnel (-> $NEW_HOST) ..."
  launchctl unload "$PLIST" 2>/dev/null || true
  sleep 1
  launchctl load "$PLIST" 2>/dev/null || warn "launchctl load failed — run: launchctl load $PLIST"
else
  warn "tunnel plist not found ($PLIST) — install it via dev-setup, then re-run."
fi

# Verify reachability from the Mac (give the tunnel a few seconds to settle).
info "Verifying localhost:${APP_PORTS[*]} ..."
sleep 3
for p in "${APP_PORTS[@]}"; do
  if curl -fsS -m6 -o /dev/null "http://localhost:$p/" 2>/dev/null; then
    ok "localhost:$p reachable"
  else
    warn "localhost:$p not reachable yet (worktree may not be running on that port, or tunnel still settling)"
  fi
done
