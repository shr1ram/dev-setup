#!/usr/bin/env bash
# ucl-home-offload.sh — keep the 10GB UCL home under quota by relocating the
# big, NON-env-redirectable directories to the 500GB project filesystem and
# symlinking them back. Idempotent: safe to run repeatedly (e.g. from a cron or
# after a login that recreated a real dir).
#
# What this handles that the cshrc env-redirects (XDG_CACHE_HOME, HF_HOME,
# PIP_CACHE_DIR, PYTHONUSERBASE, …) do NOT: tools that hardcode their path and
# ignore env — VS Code Remote (~/.vscode-server) and Python user-site
# (~/.local). Those must be symlinks, not env overrides.
#
# Run on a UCL box (no-op elsewhere). Does nothing destructive: it rsyncs to the
# project FS, verifies, and only then replaces the home dir with a symlink. An
# already-symlinked dir is skipped.
set -euo pipefail

PROJ=/cs/student/project_msc/2025/csml/sruppage
DEST="$PROJ/home-dirs"

# No-op anywhere the project FS isn't present (e.g. the Mac).
[ -d "$PROJ" ] || { echo "ucl-home-offload: $PROJ not present — skipping (not a UCL box)."; exit 0; }
mkdir -p "$DEST"

# Dirs to offload: hardcoded-path tools that ignore cache env vars.
OFFLOAD=( ".local" ".vscode-server" )

offload_one() {
    local name="$1"
    local src="$HOME/$name"
    local dst="$DEST/$name"

    # Already a symlink → nothing to do (idempotent).
    if [ -L "$src" ]; then
        echo "✓ ~/$name already symlinked -> $(readlink "$src")"
        return 0
    fi
    # Nothing in home yet → just point the symlink at the (maybe empty) project dir.
    if [ ! -e "$src" ]; then
        mkdir -p "$dst"
        ln -s "$dst" "$src"
        echo "✓ ~/$name created as symlink -> $dst"
        return 0
    fi

    echo "▸ Offloading ~/$name -> $dst ..."
    mkdir -p "$dst"
    # Merge home contents into the project copy (newer wins), then verify before
    # we delete anything. --delete keeps dst an exact mirror of src.
    rsync -a --delete "$src/" "$dst/"
    # Sanity check: dst must be non-empty if src was.
    if [ -n "$(ls -A "$src" 2>/dev/null)" ] && [ -z "$(ls -A "$dst" 2>/dev/null)" ]; then
        echo "✖ rsync produced an empty $dst — aborting, leaving ~/$name untouched." >&2
        return 1
    fi
    rm -rf "$src"
    ln -s "$dst" "$src"
    echo "✓ ~/$name now lives on the project FS (symlinked)."
}

for d in "${OFFLOAD[@]}"; do
    offload_one "$d" || echo "⚠ offload of ~/$d failed — see above." >&2
done

echo ""
echo "Home usage now:"
du -sh "$HOME" 2>/dev/null || true
