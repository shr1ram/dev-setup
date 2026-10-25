#!/usr/bin/env python3
"""
Render every Block* scene in <project>/scenes.py with Manim, in parallel.

Outputs <project>/renders/blocks/<id>.mp4 (one per block, silent video).

Usage: render.py PROJECT_DIR [-q l|m|h|k] [--blocks 01,03] [--jobs 4] [--fps 30] [--timeout SECS]
  -q l  854x480  @15fps   fast preview (check layout/timing)
  -q m  1280x720 @30fps
  -q h  1920x1080@30fps   final (use --fps 60 if wanted)
  -q k  3840x2160@60fps
Vertical (9:16) is taken from script.json "aspect".
--timeout is wall-clock seconds per block (default 600 at l/m, 1800 at h, 3600 at k). A block
that exceeds it is reported as failed; raise it for long blocks at high quality.
"""
import sys as _s, os as _o; _s.path.insert(0, _o.path.dirname(_o.path.abspath(__file__))); import _bootstrap  # noqa: E402
import argparse, json, os, re, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

HERE = Path(__file__).resolve().parent
QUAL = {"l": (854, 480, 15), "m": (1280, 720, 30), "h": (1920, 1080, 30), "k": (3840, 2160, 60)}
TIMEOUT = {"l": 600, "m": 600, "h": 1800, "k": 3600}


def positive_int(s):
    v = int(s)
    if v <= 0:
        raise argparse.ArgumentTypeError("must be > 0")
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("project")
    ap.add_argument("-q", "--quality", default="l", choices=QUAL)
    ap.add_argument("--blocks")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--fps", type=int)
    ap.add_argument("--timeout", type=positive_int, help="seconds per block (default depends on -q)")
    a = ap.parse_args()

    proj = Path(a.project).resolve()
    script = json.loads((proj / "script.json").read_text())
    src = (proj / "scenes.py").read_text()
    # Scene classes are Block + the block id digits (Block01, Block07); the id is that leading run of
    # digits, as in explainer_lib. Helper bases like BlockBase have no digits and are skipped.
    ids = dict(re.findall(r"^class\s+(Block(\d+)\w*)\s*\(", src, re.M))
    classes = list(ids)
    dupes = sorted({i for i in ids.values() if list(ids.values()).count(i) > 1})
    if dupes:  # they would render into the same file and overwrite each other
        sys.exit("more than one Block class for id(s) " + ", ".join(
            f"{d} ({', '.join(c for c in classes if ids[c] == d)})" for d in dupes))
    want = set(a.blocks.split(",")) if a.blocks else None
    if want and (unknown := sorted(want - set(ids.values()))):
        sys.exit(f"no Block class for id(s) {', '.join(unknown)} in {proj/'scenes.py'}")
    todo = [c for c in classes if want is None or ids[c] in want]
    if not todo:
        sys.exit(f"no Block* classes found in {proj/'scenes.py'}")
    timeout = a.timeout or TIMEOUT[a.quality]

    w, h, fps = QUAL[a.quality]
    if script.get("aspect", "16:9") == "9:16":
        w, h = h, w
    fps = a.fps or fps
    out_dir = proj / "renders" / "blocks"; out_dir.mkdir(parents=True, exist_ok=True)

    env = dict(os.environ, EXPLAINER_PROJECT=str(proj),
               PYTHONPATH=f"{HERE}{os.pathsep}{os.environ.get('PYTHONPATH','')}")
    manim = str(Path(sys.executable).parent / "manim")

    def run(cls):
        bid = ids[cls]
        # Each job gets its own media dir: parallel jobs sharing one renders/Tex cache race on
        # identical LaTeX strings (one deletes the .dvi the other is still converting).
        mdir = proj / "renders" / "jobs" / bid
        cmd = [manim, "render", "-r", f"{w},{h}", "--fps", str(fps), "--media_dir", str(mdir),
               "-o", f"{bid}.mp4", "--disable_caching", "-v", "WARNING", str(proj / "scenes.py"), cls]
        try:
            p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return cls, False, (f"still rendering after {timeout}s: either slow (long block at high quality: "
                                "raise --timeout) or stuck (a runaway updater or a very long wait)")
        except OSError as e:
            return cls, False, f"could not run manim: {e}"
        if p.returncode != 0:
            return cls, False, (p.stdout + p.stderr)[-3000:]
        notes = "\n".join(l for l in p.stdout.splitlines() if l.startswith("[explainer]"))
        produced = sorted((mdir / "videos").rglob(f"{bid}.mp4"), key=lambda f: f.stat().st_mtime)
        if not produced:
            return cls, False, "manim finished but no mp4 found"
        shutil.copy(produced[-1], out_dir / f"{bid}.mp4")
        return cls, True, notes

    print(f"rendering {len(todo)} block(s) at {w}x{h}@{fps} with {a.jobs} workers ...")
    ok = True
    with ThreadPoolExecutor(a.jobs) as ex:
        for fut in as_completed([ex.submit(run, c) for c in todo]):
            cls, good, err = fut.result()
            print(f"  {'ok  ' if good else 'FAIL'} {cls}")
            if err:  # failure output, or timing warnings from a successful render
                print("   " + err.replace("\n", "\n   "))
            ok = ok and good
    print(f"-> {out_dir}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
