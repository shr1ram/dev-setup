"""Theme fonts that exist on every platform the skill runs on.

The themes name macOS fonts (Helvetica Neue, Avenir Next). On Linux (e.g. a cloud container) those
are missing and Pango/libass would silently substitute something else, so each one maps to close
open-licence lookalikes; the first installed one wins and a note is printed.
"""
from __future__ import annotations

import functools
import shutil
import subprocess

FONT_FALLBACKS = {
    "Helvetica Neue": ["TeX Gyre Heros", "Inter", "Liberation Sans", "DejaVu Sans"],
    "Helvetica": ["TeX Gyre Heros", "Inter", "Liberation Sans", "DejaVu Sans"],
    "Avenir Next": ["Nunito Sans", "Montserrat", "Inter", "DejaVu Sans"],
    "Futura": ["Jost", "Montserrat", "DejaVu Sans"],
    "Georgia": ["Gelasio", "TeX Gyre Pagella", "DejaVu Serif"],
    "Menlo": ["DejaVu Sans Mono", "Liberation Mono"],
}


@functools.lru_cache(maxsize=None)
def installed_fonts() -> frozenset[str]:
    """Font family names Pango can see (empty if that can't be determined)."""
    try:
        import manimpango
        return frozenset(manimpango.list_fonts())
    except Exception:
        pass
    if shutil.which("fc-list"):  # fontconfig (Linux); used when manimpango isn't importable
        out = subprocess.run(["fc-list", ":", "family"], capture_output=True, text=True).stdout
        return frozenset(f.strip() for line in out.splitlines() for f in line.split(","))
    return frozenset()


@functools.lru_cache(maxsize=None)
def resolve_font(name: str) -> str:
    """`name` if it is installed, else the first installed fallback for it."""
    fonts = installed_fonts()
    if not name or not fonts or name in fonts:
        return name
    for alt in FONT_FALLBACKS.get(name, []):
        if alt in fonts:
            print(f"[explainer] font {name!r} not installed; using {alt!r}")
            return alt
    print(f"[explainer] WARNING: font {name!r} not installed and no fallback found; the renderer will substitute one")
    return name
