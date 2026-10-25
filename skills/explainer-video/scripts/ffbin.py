"""Locate ffmpeg/ffprobe. Standard library only (result.py imports it outside the venv).

Prefers Homebrew's keg-only ffmpeg-full, which has libass (subtitle burn-in) and drawtext that the
plain `ffmpeg` bottle lacks, under whichever prefix brew uses (/opt/homebrew on Apple silicon,
/usr/local on Intel); otherwise whatever is on PATH.
"""
import os, shutil
from pathlib import Path


def _brew_prefixes():
    if os.environ.get("HOMEBREW_PREFIX"):
        yield Path(os.environ["HOMEBREW_PREFIX"])
    if brew := shutil.which("brew"):
        yield Path(brew).resolve().parent.parent
    yield from (Path("/opt/homebrew"), Path("/usr/local"))


def find(tool: str) -> str:
    for prefix in _brew_prefixes():
        p = prefix / "opt" / "ffmpeg-full" / "bin" / tool
        if p.exists():
            return str(p)
    return shutil.which(tool) or tool


FFMPEG, FFPROBE = find("ffmpeg"), find("ffprobe")
