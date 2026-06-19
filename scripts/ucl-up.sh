#!/usr/bin/env bash
# ucl-up.sh — bring the Memento/AutoResearch stack up on UCL GPUs from the Mac.
#
# TEARS DOWN any previous deployment everywhere first (ucl-down.sh), then picks a
# free GPU box, SSHes in, starts the app (+ local Ollama proxy when llm=local),
# writes the chosen host to ~/dev-setup/ucl-hosts.env, and reloads the Mac->app
# LaunchAgent so localhost:8000 points at the new box.
#
# Experiment GPUs are ON-DEMAND: the app runs with the GPU broker (default on),
# which claims a free GPU + spins up a per-run shim only WHEN an experiment runs.
# There is no always-on static shim, so nothing experiment-related is started
# here — the broker scripts already live on every box at $PROJ/ucl-infra.
#
# Host count is decided by the LLM profile (env-profiles/current on the box):
#   LLM=local -> 2 boxes (Ollama needs a GPU + experiments need a separate one)
#   LLM=api   -> 1 box   (only experiments need a GPU; LLM is the remote proxy)
#
# Usage:
#   ucl-up.sh                      # auto: read profile, pick free box(es), full bring-up
#   ucl-up.sh --split              # force 2 boxes
#   ucl-up.sh --single             # force 1 box
#   ucl-up.sh --app HOST --infra HOST   # pin specific boxes (short alias, e.g. lab-gpu-scaup-l)
#   ucl-up.sh --dry-run            # show selection + plan, start nothing
set -euo pipefail

PROJ=/cs/student/project_msc/2025/csml/sruppage
# The active worktree to serve. The bare "memento-research" clone no longer
# exists — work lives in git worktrees: "-dev" (feature branch, the one we
# develop+test) and "-serve" (stable). Override with MEMENTO_REPO if needed.
REPO="${MEMENTO_REPO:-$PROJ/memento-research-dev}"
HOSTS_ENV="$HOME/dev-setup/ucl-hosts.env"
SSH_CONFIG="$HOME/.ssh/config"
SSH_OPTS=(-o RemoteCommand=none -o RequestTTY=no -o ControlMaster=no -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new)
LAUNCH_LABEL="com.shr1ram.ucl-app-tunnel"

MODE="auto"; PIN_APP=""; PIN_INFRA=""; DRY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --split) MODE="split" ;;
    --single) MODE="single" ;;
    --app) PIN_APP="$2"; shift ;;
    --infra) PIN_INFRA="$2"; shift ;;
    --dry-run) DRY=true ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

info(){ printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok(){ printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die(){ printf '\033[0;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

# --- read the LLM profile off the box (decides 1 vs 2 hosts) ---
read_profile() {
  ssh "${SSH_OPTS[@]}" knuckles "bash -lc 'grep -E ^LLM= $REPO/env-profiles/current 2>/dev/null | cut -d= -f2'" 2>/dev/null | tr -d '[:space:]'
}

# --- discover free lab hosts (mirrors gpu-status: <10% util AND <10% mem) ---
free_hosts() {
  local hosts; hosts=$(grep -o 'Host lab-gpu-[^ ]*-l' "$SSH_CONFIG" | awk '{print $2}' | sort)
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  for h in $hosts; do
    ( out=$(ssh "${SSH_OPTS[@]}" "$h" 'nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader' 2>/dev/null) \
        && echo "$out" > "$tmp/$h" ) &
  done
  wait
  for h in $hosts; do
    [ -s "$tmp/$h" ] || continue
    IFS=',' read -r util used total < "$tmp/$h"
    util=${util%% *}; used=$(echo "$used"|awk '{print $1}'); total=$(echo "$total"|awk '{print $1}')
    [ "${total:-0}" -gt 0 ] 2>/dev/null || continue
    local pct=$(( used * 100 / total ))
    if [ "${util:-100}" -lt 10 ] 2>/dev/null && [ "$pct" -lt 10 ]; then echo "$h"; fi
  done
}

fqdn(){ echo "${1#lab-gpu-}" | sed 's/$/.cs.ucl.ac.uk/'; }  # lab-gpu-scaup-l -> scaup-l.cs.ucl.ac.uk

# --- determine how many hosts we need ---
LLM_PROFILE="$(read_profile)"; LLM_PROFILE="${LLM_PROFILE:-api}"
NEED=1
case "$MODE" in
  split) NEED=2 ;;
  single) NEED=1 ;;
  auto) [ "$LLM_PROFILE" = "local" ] && NEED=2 || NEED=1 ;;
esac
info "LLM profile = $LLM_PROFILE -> need $NEED box(es) (mode=$MODE)"

# --- TEAR DOWN any previous deployment everywhere FIRST ---
# A clean slate before we pick a box: otherwise a stale app keeps running on the
# box we moved off of (e.g. the tunnel pointed at scaup while we'd redeployed on
# bufflehead). Running this before the free-box scan also means a box freed by
# teardown becomes a valid candidate again. Skipped on --dry-run.
if ! $DRY; then
  DOWN="$(dirname "${BASH_SOURCE[0]}")/ucl-down.sh"
  if [ -x "$DOWN" ]; then
    info "Tearing down any previous deployment (clean slate)..."
    bash "$DOWN" --quiet || warn "teardown reported an error (continuing)"
  else
    warn "ucl-down.sh not found next to ucl-up.sh — skipping teardown"
  fi
fi

# --- select hosts (pinned override, else auto-pick free) ---
APP=""; INFRA=""
if [ -n "$PIN_APP" ]; then
  APP="$PIN_APP"; INFRA="${PIN_INFRA:-}"
else
  info "Scanning UCL lab GPUs for free boxes..."
  FREE=()
  while IFS= read -r line; do [ -n "$line" ] && FREE+=("$line"); done < <(free_hosts)
  [ "${#FREE[@]}" -ge "$NEED" ] || die "need $NEED free box(es), found ${#FREE[@]}: ${FREE[*]:-none}"
  APP="${FREE[0]}"
  [ "$NEED" -eq 2 ] && INFRA="${FREE[1]}" || INFRA="$APP"
fi
# single-box: app box also runs the shim (INFRA==APP); split: distinct boxes
[ "$NEED" -eq 1 ] && INFRA="$APP"
ok "app+LLM -> $APP    experiments -> $INFRA"

if $DRY; then info "(dry-run) would start services + tunnels and write $HOSTS_ENV"; exit 0; fi

# --- write hosts config (read by tunnels) ---
cat > "$HOSTS_ENV" <<EOF
# UCL host selection — written by ucl-up.sh $(date -u +%Y-%m-%dT%H:%M:%SZ)
UCL_APP_HOST=$APP
UCL_APP_FQDN=$(fqdn "$APP")
UCL_INFRA_HOST=$INFRA
UCL_INFRA_FQDN=$(fqdn "$INFRA")
EOF
ok "wrote $HOSTS_ENV"

# --- experiment infra: ON-DEMAND GPU broker (no static shim) ---
# We no longer start an always-on static shim that holds a GPU for the
# deployment's whole life. Instead the app runs with GPU_BROKER=1: the engine
# claims a free GPU and stands up a per-experiment shim only WHEN an experiment
# runs (gpu_broker.claim, ucl-infra/claim-gpu.sh), releasing it after. So there
# is nothing to start here — the broker scripts already live on every box at
# $PROJ/ucl-infra. GPU_BROKER is exported into the app's start below.
info "Experiment infra: on-demand GPU broker (GPU_BROKER=1) — no static shim."

# --- start the Ollama wake-proxy (local LLM only) on the app box ---
# We start the lazy wake-on-request PROXY, not Ollama itself: it cold-starts
# Ollama on the first request and kills it after 15min idle to free the shared
# GPU. The local profile's base URL points at the proxy (:11435).
if [ "$LLM_PROFILE" = "local" ]; then
  info "Starting Ollama wake-proxy on $APP (lazy start, 15min idle-kill) ..."
  ssh "${SSH_OPTS[@]}" "$APP" "bash -lc 'bash $PROJ/ucl-infra/start-ollama-proxy.sh'" || warn "ollama wake-proxy start reported an error"
fi
# --- recompose .env from the profile fragments BEFORE starting the app ---
# .env is a build artifact, never a source of truth. start.sh copies whatever
# .env is on disk into the runtime, so a .env left over from an older switch.sh
# run (e.g. a base URL since corrected in env-profiles/*.env) would silently
# ship stale config — exactly the :11434-vs-:11435 wake-proxy regression. We
# always regenerate from the fragments so the running app matches the source.
# --compose-only writes .env + .onemancompany/.env without needing the backend.
INFRA_PROFILE=$(ssh "${SSH_OPTS[@]}" "$APP" "bash -lc 'grep -E ^INFRA= $REPO/env-profiles/current 2>/dev/null | cut -d= -f2'" 2>/dev/null | tr -d '[:space:]')
INFRA_PROFILE="${INFRA_PROFILE:-ucl}"
info "Recomposing .env on $APP (llm=$LLM_PROFILE infra=$INFRA_PROFILE) ..."
ssh "${SSH_OPTS[@]}" "$APP" "bash -lc 'cd $REPO; ./switch.sh --compose-only llm=$LLM_PROFILE infra=$INFRA_PROFILE >/dev/null'" \
  || warn "recompose reported an error — start.sh will use the existing .env"

# --- which port does THIS worktree's app bind? ---
# The two worktrees must run on DISTINCT ports so dev + serve can coexist (the
# Mac tunnel forwards both): serve -> 8000, dev -> 8001. We can't read PORT from
# .env because the recompose above regenerates .env from the shared profile
# fragments (base.env pins PORT=8000), which would force every worktree onto
# 8000. So derive the port from the worktree NAME and force it via start.sh's
# PORT env override (resolve_port honours $PORT above everything else). This
# also makes base.env's PORT irrelevant and survives any recompose.
case "$REPO" in
  *-dev|*-dev/) APP_PORT=8001 ;;
  *)            APP_PORT=8000 ;;
esac
info "App port for $REPO = $APP_PORT"

info "Starting app on $APP (GPU_BROKER=1, on-demand experiment GPUs) ..."
APP_OUT=$(ssh "${SSH_OPTS[@]}" "$APP" "bash -lc 'export PATH=\$HOME/.local/bin:\$PATH XDG_CACHE_HOME=$PROJ/.cache UV_CACHE_DIR=$PROJ/.uv-cache PORT=$APP_PORT GPU_BROKER=1 UCL_INFRA_DIR=$PROJ/ucl-infra; cd $REPO; bash start.sh start'" 2>&1) || true
if printf '%s' "$APP_OUT" | grep -qiE 'Backend ready|already in use|already running'; then
  ok "app up on $APP"
else
  printf '%s\n' "$APP_OUT" | tail -5
  die "app failed to start on $APP"
fi

# --- no static-shim wiring: the broker handles experiment infra per-run ---
# With GPU_BROKER=1 the app does NOT use a deployment-wide INFRA_SERVER_URL — the
# engine claims a GPU and gets a per-run shim URL/key from gpu_broker.env_for()
# at submit time. So there's no static :8770/:8771 shim to start, no app->infra
# tunnel to wire, and no INFRA_SERVER_URL to POST. (The broker opens its own
# short-lived tunnel per lease via claim-gpu.sh.)

# --- reload the Mac->app LaunchAgent so localhost:8000 points at the new box ---
PLIST="$HOME/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
if [ -f "$PLIST" ]; then
  info "Reloading Mac app tunnel (-> $APP) ..."
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST" 2>/dev/null || warn "launchctl load failed — run: launchctl load $PLIST"
fi

# --- verify app reachable, then point it at the shim (from the Mac via tunnel) ---
info "Verifying localhost:$APP_PORT ..."
REACHED=false
for _ in $(seq 1 20); do
  curl -fsS -m4 -o /dev/null "http://localhost:$APP_PORT/" 2>/dev/null && { REACHED=true; break; }
  sleep 2
done
if ! $REACHED; then
  warn "app not reachable yet via localhost:$APP_PORT — tunnel still settling; check launchctl + 'curl localhost:$APP_PORT'"
  exit 0
fi
ok "app reachable at http://localhost:$APP_PORT  (app=$APP, experiment GPUs on-demand via broker)"
