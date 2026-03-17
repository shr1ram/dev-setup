#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Dev Environment Bootstrap
# This is a thin bootstrapper. It clones the repo and runs the real setup
# script from the local copy, so you always get the latest version.
#
# Usage: bash <(curl -sL https://raw.githubusercontent.com/shr1ram/dev-setup/main/setup.sh)
# =============================================================================

REPO_URL="https://github.com/shr1ram/dev-setup.git"
CLONE_DIR="$HOME/dev-setup"

# Clone or update the repo first
if [[ -d "$CLONE_DIR/.git" ]]; then
    git -C "$CLONE_DIR" pull --ff-only
else
    git clone "$REPO_URL" "$CLONE_DIR"
fi

# Hand off to the real setup script with all arguments
exec bash "$CLONE_DIR/scripts/install.sh" "$@"
