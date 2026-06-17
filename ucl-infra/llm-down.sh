#!/usr/bin/env bash
# llm-down.sh <app-name> — release the LLM GPU claimed by llm-up.sh for an app
# (stops its wake-proxy + ollama, drops the lease). Run on app shutdown.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:?usage: llm-down.sh <app-name>}"
exec "$HERE/release-gpu.sh" "llm:$APP"
