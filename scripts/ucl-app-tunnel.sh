#!/usr/bin/env bash
# Foreground SSH tunnel: localhost:8000 (Mac) -> bufflehead-l.cs.ucl.ac.uk:8000
# (the Memento/AutoResearch app), via the knuckles jump host in ~/.ssh/config.
#
# Run in the FOREGROUND (no -f, no nohup): launchd owns the process lifecycle.
# When the tunnel drops (idle reap, sleep, network blip) ssh exits and launchd's
# KeepAlive relaunches it — so access auto-restores when the Mac wakes.
#
# Managed by dev-setup; installed as a LaunchAgent by install.sh.
set -euo pipefail

REMOTE_HOST="lab-gpu-bufflehead-l"          # ssh config alias (ProxyJump knuckles)
REMOTE_TARGET="bufflehead-l.cs.ucl.ac.uk:8000"
LOCAL_PORT=8000

exec ssh \
    -o ControlMaster=no -o ControlPath=none \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o TCPKeepAlive=yes \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -N -L "${LOCAL_PORT}:${REMOTE_TARGET}" "$REMOTE_HOST"
