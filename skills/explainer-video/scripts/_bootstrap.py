"""Re-exec the calling script under the skill's venv python if it isn't already (so scripts work
from any shell without `source setup.sh`). Imported for its side effect."""
import os, sys
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
VENV = Path(os.environ.get("EXPLAINER_VENV", SKILL_DIR / ".venv"))
# Model weights (Kokoro via Hugging Face Hub) are cached inside the skill folder, not ~/.cache.
# An HF_HOME that is already set wins (e.g. a container with the weights baked in elsewhere);
# setup.sh applies the same rule, so both always agree on where the weights are.
os.environ.setdefault("HF_HOME", str(SKILL_DIR / "models" / "huggingface"))
PY = VENV / "bin" / "python"
# Compare prefixes, not interpreter binaries: a uv/venv python is often a symlink to the very
# python3 that launched us, so the resolved binaries match even though the venv is not active.
if (PY.exists() and Path(sys.prefix).resolve() != VENV.resolve()
        and os.environ.get("_EXPLAINER_REEXEC") != str(VENV)):   # guard: re-exec at most once
    os.environ["_EXPLAINER_REEXEC"] = str(VENV)
    os.environ["VIRTUAL_ENV"] = str(VENV)
    os.environ["PATH"] = f"{VENV/'bin'}{os.pathsep}{os.environ.get('PATH','')}"
    os.execv(str(PY), [str(PY), *sys.argv])
os.environ.pop("_EXPLAINER_REEXEC", None)   # only guards the one exec above, not our child processes
if not PY.exists():
    sys.exit(f"explainer-video venv not found at {VENV}; run: bash {Path(__file__).parent/'setup.sh'}")
os.environ.setdefault("VIRTUAL_ENV", str(VENV))
os.environ["PATH"] = f"{VENV/'bin'}{os.pathsep}{os.environ.get('PATH','')}"
# MacTeX/BasicTeX installs here; shells started before the install may not have it on PATH.
if os.path.isdir("/Library/TeX/texbin") and "/Library/TeX/texbin" not in os.environ["PATH"]:
    os.environ["PATH"] += os.pathsep + "/Library/TeX/texbin"
