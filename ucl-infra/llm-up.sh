#!/usr/bin/env bash
# llm-up.sh <app-name> — claim a dedicated GPU for an app's local LLM and print
# the DEFAULT_API_BASE_URL to point that app at. Run BEFORE starting the app on
# the `local` profile so its Ollama gets its own GPU (Phase 3).
#
#   eval "$(ucl-infra/llm-up.sh serve)"   # exports DEFAULT_API_BASE_URL
#   # ...then start the app; switch.sh / .env should use that base URL.
#
# Idempotent per app-name. Pairs with llm-down.sh <app-name>.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:?usage: llm-up.sh <app-name>}"

out=$("$HERE/claim-llm-gpu.sh" "$APP") || {
  echo "# llm-up: claim failed (no free GPU?) — fall back to the static wake-proxy" >&2
  exit 3
}
url=$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["DEFAULT_API_BASE_URL"])')
box=$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["box"])')
echo "# llm-up: $APP -> dedicated LLM GPU on $box" >&2
printf 'export DEFAULT_API_BASE_URL=%q\n' "$url"
