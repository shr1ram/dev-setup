#!/usr/bin/env bash
# Idempotent environment check/installer for the explainer-video skill (macOS, Homebrew + uv).
# Usage: source scripts/setup.sh      (exports PATH/VIRTUAL_ENV for this shell)
#        bash   scripts/setup.sh      (just checks/installs and reports)
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENV_DIR="$SKILL_DIR"
VENV="$SKILL_DIR/.venv"
export HF_HOME="$SKILL_DIR/models/huggingface"   # Kokoro weights land here (gitignored)
missing=()
for b in ffmpeg ffprobe uv brew; do command -v $b >/dev/null || missing+=($b); done
if [ ${#missing[@]} -gt 0 ]; then
  echo "missing: ${missing[*]}"
  echo "  brew install ffmpeg        # ffmpeg/ffprobe"
  echo "  curl -LsSf https://astral.sh/uv/install.sh | sh   # uv"
fi
for lib in cairo pango pkg-config espeak-ng; do
  brew list --versions $lib >/dev/null 2>&1 || { echo "installing $lib via brew"; brew install $lib; }
done
# The plain ffmpeg bottle has no libass (subtitle burn-in) or drawtext; ffmpeg-full (keg-only) does.
# assemble.py/sheet.py prefer /opt/homebrew/opt/ffmpeg-full/bin automatically when present.
[ -x /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ] || { echo "installing ffmpeg-full via brew (for burned subtitles; takes a few minutes)"; brew install ffmpeg-full; }
if [ ! -x "$VENV/bin/python" ]; then
  echo "creating $VENV (python 3.12) and installing manim + kokoro (first time: a few minutes)"
  mkdir -p "$ENV_DIR" && uv venv --python 3.12 "$VENV"
fi
export VIRTUAL_ENV="$VENV"
export PATH="$VENV/bin:$PATH"
"$VENV/bin/python" -c "import manim, kokoro, soundfile" 2>/dev/null || \
  uv pip install --python "$VENV/bin/python" manim kokoro soundfile pypdf "numpy<2.3" \
     "spacy==3.8.16" "murmurhash==1.0.10" "preshed==3.0.9" "cymem==2.0.8"
# spaCy's newest compiled helpers (preshed/cymem/murmurhash) crash on model load on macOS arm64
# ("OverflowError: Python int too large to convert to C ssize_t"); the pins above are the fix.
"$VENV/bin/python" -c "import spacy; spacy.load('en_core_web_sm')" 2>/dev/null || \
  uv pip install --python "$VENV/bin/python" \
    "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
LATEX=$(command -v latex || ls /Library/TeX/texbin/latex 2>/dev/null)
echo "python:  $VENV/bin/python"
echo "models:  $HF_HOME $([ -d "$HF_HOME/hub/models--hexgrad--Kokoro-82M" ] && echo '(Kokoro cached)' || echo '(Kokoro downloads on first tts.py run, ~330 MB)')"
echo "manim:   $("$VENV/bin/python" -c 'import manim;print(manim.__version__)' 2>/dev/null || echo MISSING)"
echo "kokoro:  $("$VENV/bin/python" -c 'import kokoro;print("ok")' 2>/dev/null || echo MISSING)"
echo "ffmpeg:  $(command -v ffmpeg || echo MISSING)   full build: $([ -x /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ] && echo yes || echo 'no -> subtitles become a soft track')"
echo "latex:   ${LATEX:-MISSING -> MathTex/Tex unavailable; use Text() for formulas, or ask the user to run: brew install --cask basictex (needs password), then: sudo tlmgr install standalone preview doublestroke dvisvgm}"
