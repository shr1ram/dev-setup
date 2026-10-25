#!/usr/bin/env python3
"""
Write <project>/result.json: the machine-readable outcome of an unattended run.

Usage: result.py PROJECT_DIR --status ok
       result.py PROJECT_DIR --status failed --reason "what went wrong"
With --status ok the final video must exist; otherwise the result is recorded as failed.
Deliberately standard-library only (no venv re-exec), so a failure can always be reported.
"""
import argparse, json, shutil, subprocess, time
from fractions import Fraction
from pathlib import Path

_FULL = "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe"
FFPROBE = _FULL if Path(_FULL).exists() else (shutil.which("ffprobe") or "ffprobe")


def probe(path: Path) -> dict:
    p = subprocess.run([FFPROBE, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip()[-500:] or "ffprobe failed")
    j = json.loads(p.stdout)
    v = next((s for s in j["streams"] if s["codec_type"] == "video"), {})
    return {"duration_s": round(float(j["format"]["duration"]), 2),
            "resolution": f"{v.get('width')}x{v.get('height')}",
            "fps": float(Fraction(v.get("r_frame_rate", "0/1")))}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("project")
    ap.add_argument("--status", required=True, choices=["ok", "failed"])
    ap.add_argument("--reason", default="")
    ap.add_argument("--video", default="final.mp4")
    a = ap.parse_args()

    proj = Path(a.project).resolve()
    proj.mkdir(parents=True, exist_ok=True)
    script = {}
    try:
        script = json.loads((proj / "script.json").read_text())
    except Exception:
        pass
    res = {"status": a.status, "reason": a.reason, "title": script.get("title", ""),
           "style": script.get("style", ""), "voice": script.get("voice", ""),
           "subtitles": bool(script.get("subtitles", False)), "blocks": len(script.get("blocks", [])),
           "sources": script.get("sources", []), "video": None,
           "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    video = proj / a.video
    if a.status == "ok":
        if not video.exists():
            res.update(status="failed", reason=f"{a.video} not found")
        else:
            try:
                res.update(video=a.video, **probe(video))
            except Exception as e:
                res.update(status="failed", reason=f"{a.video} unreadable: {e}")
    (proj / "result.json").write_text(json.dumps(res, indent=1))
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
