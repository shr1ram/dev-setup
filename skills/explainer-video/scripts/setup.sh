#!/usr/bin/env bash
# Idempotent environment check/installer for the explainer-video skill.
#   macOS: installs missing system tools/libs with Homebrew, then the Python venv.
#   Linux (e.g. a container): system packages come from the image; this checks them, stops if a
#          required one is missing, and builds the Python venv if it is missing.
# Exits non-zero (after "setup failed: ...") when something required is missing or fails to install.
# Usage: source scripts/setup.sh      (exports PATH/VIRTUAL_ENV for this shell)
#        bash   scripts/setup.sh      (just checks/installs and reports)
_explainer_setup() {
  _explainer_fail() { echo "setup failed: $*" >&2; return 1; }
  SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  VENV="${EXPLAINER_VENV:-$SKILL_DIR/.venv}"
  export HF_HOME="${HF_HOME:-$SKILL_DIR/models/huggingface}"   # Kokoro weights land here (gitignored)
  local OS b lib FF BREW missing=()
  OS="$(uname -s)"
  if [ "$OS" = "Darwin" ]; then
    command -v brew >/dev/null || { _explainer_fail "Homebrew is required: https://brew.sh"; return 1; }
    BREW="$(brew --prefix)"   # /opt/homebrew on Apple silicon, /usr/local on Intel
    if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
      echo "installing ffmpeg via brew"; brew install ffmpeg || { _explainer_fail "brew install ffmpeg"; return 1; }
    fi
    command -v uv >/dev/null || { echo "installing uv via brew"; brew install uv || { _explainer_fail "brew install uv"; return 1; }; }
    for lib in cairo pango pkg-config espeak-ng; do
      brew list --versions $lib >/dev/null 2>&1 && continue
      echo "installing $lib via brew"; brew install $lib || { _explainer_fail "brew install $lib"; return 1; }
    done
    # The plain ffmpeg bottle has no libass (subtitle burn-in) or drawtext; ffmpeg-full (keg-only) does.
    # assemble.py/sheet.py prefer <brew prefix>/opt/ffmpeg-full/bin automatically when present.
    FF="$BREW/opt/ffmpeg-full/bin/ffmpeg"
    if [ ! -x "$FF" ]; then
      echo "installing ffmpeg-full via brew (for burned subtitles; takes a few minutes)"
      brew install ffmpeg-full || { _explainer_fail "brew install ffmpeg-full"; return 1; }
    fi
  else
    for b in ffmpeg ffprobe uv espeak-ng pkg-config fc-list; do command -v $b >/dev/null || missing+=($b); done
    pkg-config --exists cairo pangocairo 2>/dev/null || missing+=("cairo/pango dev headers")
    if [ ${#missing[@]} -gt 0 ]; then
      _explainer_fail "missing: ${missing[*]}
  apt-get install ffmpeg espeak-ng pkg-config libcairo2-dev libpango1.0-dev fontconfig
  curl -LsSf https://astral.sh/uv/install.sh | sh   # uv"
      return 1
    fi
    FF="$(command -v ffmpeg)"
  fi
  if [ ! -x "$VENV/bin/python" ]; then
    echo "creating $VENV (python 3.12) and installing manim + kokoro (first time: a few minutes)"
    mkdir -p "$(dirname "$VENV")" && uv venv --python 3.12 "$VENV" || { _explainer_fail "could not create $VENV"; return 1; }
  fi
  export VIRTUAL_ENV="$VENV"
  export PATH="$VENV/bin:$PATH"
  # spaCy's newest compiled helpers (preshed/cymem/murmurhash) crash on model load on macOS arm64
  # ("OverflowError: Python int too large to convert to C ssize_t"); these pins are the fix. Check the
  # installed versions, not just the imports, so a venv made before the pins gets repaired too.
  local PINS=("spacy==3.8.16" "murmurhash==1.0.10" "preshed==3.0.9" "cymem==2.0.8")
  if ! "$VENV/bin/python" - "${PINS[@]}" 2>/dev/null <<'PY'
import sys, importlib.metadata as md
import manim, kokoro, soundfile, pypdf  # noqa: F401
sys.exit(any(md.version(n) != v for n, v in (p.split("==") for p in sys.argv[1:])))
PY
  then
    uv pip install --python "$VENV/bin/python" manim kokoro soundfile pypdf "numpy<2.3" "${PINS[@]}" \
      || { _explainer_fail "package install into $VENV"; return 1; }
  fi
  if ! "$VENV/bin/python" -c "import spacy; spacy.load('en_core_web_sm')" 2>/dev/null; then
    uv pip install --python "$VENV/bin/python" \
      "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl" \
      && "$VENV/bin/python" -c "import spacy; spacy.load('en_core_web_sm')" \
      || { _explainer_fail "spaCy model en_core_web_sm does not load (Kokoro needs it)"; return 1; }
  fi

  local LATEX SUBS FONTS
  LATEX=$(command -v latex || ls /Library/TeX/texbin/latex 2>/dev/null)
  SUBS=$( "$FF" -hide_banner -filters 2>/dev/null | grep -qE '\ssubtitles\s' && echo yes || echo 'no -> subtitles become a soft track' )
  FONTS=$(PYTHONPATH="$SKILL_DIR/scripts" "$VENV/bin/python" - <<'PY' 2>/dev/null
from fonts import installed_fonts, FONT_FALLBACKS
have = installed_fonts()
out = []
for name in ("Helvetica Neue", "Avenir Next"):
    use = name if name in have else next((f for f in FONT_FALLBACKS[name] if f in have), None)
    out.append(f"{name} -> {use or 'MISSING (renderer will substitute)'}")
print("; ".join(out))
PY
)
  echo "python:  $VENV/bin/python"
  echo "models:  $HF_HOME $([ -d "$HF_HOME/hub/models--hexgrad--Kokoro-82M" ] && echo '(Kokoro cached)' || echo '(Kokoro downloads on first tts.py run, ~330 MB)')"
  echo "manim:   $("$VENV/bin/python" -c 'import manim;print(manim.__version__)' 2>/dev/null || echo MISSING)"
  echo "kokoro:  $("$VENV/bin/python" -c 'import kokoro;print("ok")' 2>/dev/null || echo MISSING)"
  echo "ffmpeg:  $FF   burned subtitles: $SUBS"
  echo "fonts:   ${FONTS:-unknown}"
  if [ "$OS" = "Darwin" ]; then
    echo "latex:   ${LATEX:-MISSING -> MathTex/Tex unavailable; use Text() for formulas, or ask the user to run: brew install --cask basictex (needs password), then: sudo tlmgr install standalone preview doublestroke dvisvgm}"
  else
    echo "latex:   ${LATEX:-MISSING -> MathTex/Tex unavailable; use Text() for formulas (apt-get install texlive-latex-extra texlive-fonts-extra dvisvgm)}"
  fi
}
# `&& ... ||` keeps a caller's `set -e` from exiting on our failure (bash 3.2 does otherwise).
_explainer_setup && _explainer_rc=0 || _explainer_rc=$?
unset -f _explainer_setup _explainer_fail
return $_explainer_rc 2>/dev/null || exit $_explainer_rc
