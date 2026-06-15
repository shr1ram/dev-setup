#!/usr/bin/env bash
# Foreground SSH tunnel: localhost:8000 (Mac) -> <app host>:8000 (the
# Memento/AutoResearch app), via the knuckles jump host in ~/.ssh/config.
#
# The target host is read from ~/dev-setup/ucl-hosts.env (UCL_APP_HOST /
# UCL_APP_FQDN), which scripts/ucl-up.sh writes when it picks a free GPU. So
# moving the app to a different box is a config change, not an edit here.
#
# Run in the FOREGROUND (no -f, no nohup): launchd owns the lifecycle and
# relaunches on drop/sleep/wake, picking up any host change in the config.
#
# Managed by dev-setup; installed as a LaunchAgent by install.sh.
set -euo pipefail

HOSTS_ENV="$HOME/dev-setup/ucl-hosts.env"
# Defaults if the config is missing (first run before ucl-up.sh).
REMOTE_HOST="lab-gpu-bufflehead-l"
REMOTE_FQDN="bufflehead-l.cs.ucl.ac.uk"
if [ -f "$HOSTS_ENV" ]; then
    # shellcheck disable=SC1090
    . "$HOSTS_ENV"
    REMOTE_HOST="${UCL_APP_HOST:-$REMOTE_HOST}"
    REMOTE_FQDN="${UCL_APP_FQDN:-$REMOTE_FQDN}"
fi
LOCAL_PORT=8000

exec ssh \
    -o ControlMaster=no -o ControlPath=none \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o TCPKeepAlive=yes \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -N -L "${LOCAL_PORT}:${REMOTE_FQDN}:${LOCAL_PORT}" "$REMOTE_HOST"
