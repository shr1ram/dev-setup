#!/usr/bin/env python3
"""
Write <project>/result.json: the machine-readable outcome of an unattended run.

Usage: result.py PROJECT_DIR --status ok
       result.py PROJECT_DIR --status failed --reason "what went wrong"
With --status ok the final video must exist; otherwise the result is recorded as failed.
Deliberately standard-library only (no venv re-exec), so a failure can always be reported.
"""
import argparse, json, subprocess, time
from fractions import Fraction
from pathlib import Path

from ffbin import FFPROBE


def probe(path: Path) -> dict:
    p = subprocess.run([FFPROBE, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip()[-500:] or "ffprobe failed")
    j = json.loads(p.stdout)
    v = next((s for s in j["streams"] if s["codec_type"] == "video"), None)
    if v is None:
        raise RuntimeError("no video stream")
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
    if not isinstance(script, dict):
        script = {}
    blocks, sources = script.get("blocks"), script.get("sources")
    res = {"status": a.status, "reason": a.reason, "project": str(proj), "title": script.get("title") or "",
           "style": script.get("style") or "", "voice": script.get("voice") or "",
           "subtitles": bool(script.get("subtitles")),
           "blocks": len(blocks) if isinstance(blocks, list) else 0,
           "sources": sources if isinstance(sources, list) else [], "video": None,
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
