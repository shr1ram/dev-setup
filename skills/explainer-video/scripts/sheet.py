#!/usr/bin/env python3
"""
Contact sheet of a video (or every block render) so you can *look* at the result.

Usage: sheet.py VIDEO.mp4 [--every 3] [--cols 4] [--out sheet.png]
       sheet.py PROJECT_DIR --blocks          # one sheet per block in renders/blocks -> renders/sheets/
Each tile is stamped with its timestamp. Open the PNG with the Read tool and check:
text cut off at edges, overlapping objects, empty stretches, wrong colours.
"""
import sys as _s, os as _o; _s.path.insert(0, _o.path.dirname(_o.path.abspath(__file__))); import _bootstrap  # noqa: E402
import argparse, math, os, shutil, subprocess, tempfile
from pathlib import Path

from PIL import Image, ImageDraw

# Prefer Homebrew's ffmpeg-full (keg-only) because the plain `ffmpeg` bottle lacks libass
# (subtitle burn-in) and drawtext.
_FULL = "/opt/homebrew/opt/ffmpeg-full/bin"
FFMPEG = f"{_FULL}/ffmpeg" if os.path.exists(f"{_FULL}/ffmpeg") else (shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg")
FFPROBE = f"{_FULL}/ffprobe" if os.path.exists(f"{_FULL}/ffprobe") else (shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe")


def dur(p):
    return float(subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(p)],
                                capture_output=True, text=True).stdout.strip() or 0)


def sheet(video, out, every, cols, width=480):
    d = dur(video)
    with tempfile.TemporaryDirectory() as td:
        # One accurate seek per tile (the fps filter samples 1-2 s late, which made beats look early).
        n = max(1, math.ceil(d / every)); frames = []
        for i in range(n):
            out_f = Path(td) / f"f{i:04d}.png"
            subprocess.run([FFMPEG, "-y", "-v", "error", "-ss", f"{i*every:.3f}", "-i", str(video),
                            "-frames:v", "1", "-vf", f"scale={width}:-2", str(out_f)], check=True)
            if out_f.exists(): frames.append(out_f)
        if not frames:
            print(f"no frames from {video}"); return
        ims = [Image.open(f).convert("RGB") for f in frames]
        w, h = ims[0].size
        rows = math.ceil(len(ims) / cols); pad = 6
        canvas = Image.new("RGB", (cols * (w + pad) + pad, rows * (h + pad) + pad), (40, 40, 40))
        for i, im in enumerate(ims):
            x = pad + (i % cols) * (w + pad); y = pad + (i // cols) * (h + pad)
            canvas.paste(im, (x, y))
            dr = ImageDraw.Draw(canvas)
            label = f"{int(i*every)//60:02d}:{int(i*every)%60:02d}"
            dr.rectangle([x, y, x + 58, y + 20], fill=(0, 0, 0))
            dr.text((x + 5, y + 4), label, fill=(255, 255, 255))
        canvas.save(out)
    print(f"{out}  ({len(frames)} frames, every {every}s of {d:.1f}s)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--every", type=float, default=3)
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--out")
    ap.add_argument("--blocks", action="store_true")
    a = ap.parse_args()
    t = Path(a.target)
    if a.blocks or t.is_dir():
        outd = t / "renders" / "sheets"; outd.mkdir(parents=True, exist_ok=True)
        for v in sorted((t / "renders" / "blocks").glob("*.mp4")):
            sheet(v, outd / f"{v.stem}.png", a.every, a.cols)
    else:
        sheet(t, Path(a.out) if a.out else t.with_suffix(".sheet.png"), a.every, a.cols)


if __name__ == "__main__":
    main()
