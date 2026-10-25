#!/usr/bin/env python3
"""
Mux each block's video with its narration, concatenate, optionally burn subtitles
and add background music. Writes <project>/final.mp4 and prints an ffprobe summary.

Usage: assemble.py PROJECT_DIR [--out final.mp4] [--subtitles] [--music track.mp3]
                   [--music-db -22] [--blocks 01,02]
Rules: each block is as long as max(video, audio). Short video holds its last frame;
short audio is padded with silence. Nothing is ever sped up or stretched.
"""
import sys as _s, os as _o; _s.path.insert(0, _o.path.dirname(_o.path.abspath(__file__))); import _bootstrap  # noqa: E402
import argparse, json, os, re, shutil, subprocess, sys
from fractions import Fraction
from pathlib import Path

from fonts import resolve_font

# Prefer Homebrew's ffmpeg-full (keg-only) because the plain `ffmpeg` bottle lacks libass
# (subtitle burn-in) and drawtext.
_FULL = "/opt/homebrew/opt/ffmpeg-full/bin"
FFMPEG = f"{_FULL}/ffmpeg" if os.path.exists(f"{_FULL}/ffmpeg") else (shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg")
FFPROBE = f"{_FULL}/ffprobe" if os.path.exists(f"{_FULL}/ffprobe") else (shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe")


def sh(cmd, cwd=None):
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if p.returncode != 0:
        sys.exit(f"command failed:\n  {' '.join(map(str, cmd))}\n{p.stderr[-2500:]}")
    return p.stdout


def probe(path):
    j = json.loads(sh([FFPROBE, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))
    v = next((s for s in j["streams"] if s["codec_type"] == "video"), {})
    return {"duration": float(j["format"]["duration"]), "w": v.get("width"), "h": v.get("height"),
            "fps": float(Fraction(v.get("r_frame_rate", "0/1")))}


def srt_time(t):
    ms = int(round(t * 1000)); h, ms = divmod(ms, 3600000); m, ms = divmod(ms, 60000); s, ms = divmod(ms, 1000)
    return f"{h:02}:{m:02}:{s:02},{ms:03}"


def build_srt(blocks, offsets, path, max_words=7):
    """Group word timestamps into short cues (<= max_words, breaking at punctuation).
    A cue ends 0.15 s after its last word, but never after the next cue starts."""
    cues = []  # (start, end, text)
    for b, off in zip(blocks, offsets):
        # Kokoro emits "." and "," as their own tokens; glue them to the previous word so a cue
        # never starts with punctuation.
        words = []
        for w in b.get("words", []):
            if words and not re.search(r"[A-Za-z0-9]", w["w"]):
                words[-1] = {"w": words[-1]["w"] + w["w"], "s": words[-1]["s"], "e": w["e"]}
            else:
                words.append(dict(w))
        chunk = []
        def flush():
            if chunk:
                text = re.sub(r"\s+([,.;:!?])", r"\1", " ".join(w["w"] for w in chunk))
                cues.append([off + chunk[0]["s"], off + chunk[-1]["e"] + 0.15, text])
        for w in words:
            chunk.append(w)
            punct = w["w"].rstrip().endswith((".", "?", "!", ";", ":", ","))
            if len(chunk) >= max_words or (punct and len(chunk) >= 3):
                flush(); chunk = []
        flush()
    for i in range(len(cues) - 1):
        cues[i][1] = min(cues[i][1], cues[i + 1][0] - 0.01)
    Path(path).write_text("\n".join(f"{i+1}\n{srt_time(s)} --> {srt_time(e)}\n{t}\n" for i, (s, e, t) in enumerate(cues)))


def has_filter(name):
    out = subprocess.run([FFMPEG, "-hide_banner", "-filters"], capture_output=True, text=True).stdout
    return re.search(rf"\s{name}\s", out) is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("project")
    ap.add_argument("--out", default="final.mp4")
    ap.add_argument("--subtitles", action="store_true")
    ap.add_argument("--music")
    ap.add_argument("--music-db", type=float, default=-22.0)
    ap.add_argument("--blocks", help="subset, e.g. 01,02 (for quick checks)")
    a = ap.parse_args()

    proj = Path(a.project).resolve()
    script = json.loads((proj / "script.json").read_text())
    a.subtitles = a.subtitles or bool(script.get("subtitles", False))
    timings = json.loads((proj / "timings.json").read_text())
    blocks = timings["blocks"]
    if a.blocks:
        keep = set(a.blocks.split(",")); blocks = [b for b in blocks if b["id"] in keep]
    work = proj / "renders" / "muxed"; work.mkdir(parents=True, exist_ok=True)

    muxed, offsets, t = [], [], 0.0
    first = None
    for b in blocks:
        v = proj / "renders" / "blocks" / f"{b['id']}.mp4"
        au = proj / b["audio"]
        if not v.exists(): sys.exit(f"missing render for block {b['id']}: {v} (run render.py)")
        pv = probe(v); first = first or pv
        vd, ad = pv["duration"], b["duration"]
        if abs(pv["w"] - first["w"]) or abs(pv["h"] - first["h"]):
            sys.exit(f"block {b['id']} is {pv['w']}x{pv['h']} but block {blocks[0]['id']} is {first['w']}x{first['h']}; re-render at one quality")
        length = max(vd, ad)
        if vd + 0.05 < ad:
            print(f"  note: block {b['id']} video {vd:.2f}s < audio {ad:.2f}s; holding last frame "
                  f"(add self.finish() at the end of the scene to avoid this)")
        out = work / f"{b['id']}.mp4"
        vf = f"tpad=stop_mode=clone:stop_duration={max(0, length - vd) + 0.05}"
        sh([FFMPEG, "-y", "-v", "error", "-i", str(v), "-i", str(au),
            "-filter_complex", f"[0:v]{vf},trim=duration={length}[v];[1:a]apad,atrim=duration={length}[a]",
            "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-preset", "medium", "-crf", "18",
            "-pix_fmt", "yuv420p", "-r", str(first["fps"]), "-c:a", "aac", "-b:a", "192k", "-ar", "48000", str(out)])
        muxed.append(out); offsets.append(t); t += probe(out)["duration"]

    lst = work / "concat.txt"
    lst.write_text("".join(f"file '{m}'\n" for m in muxed))
    joined = work / "joined.mp4"
    sh([FFMPEG, "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy", str(joined)])

    final = proj / a.out
    vf, inputs, fc, maps = [], ["-i", str(joined)], [], []
    soft_srt = None
    if a.subtitles and not has_filter("subtitles"):
        soft_srt = proj / "subtitles.srt"; build_srt(blocks, offsets, soft_srt)
        print("  note: this ffmpeg has no libass; embedding subtitles as a soft track instead of burning them "
              "(brew install ffmpeg-full to burn)")
        a.subtitles = False
    if a.subtitles:
        srt = proj / "subtitles.srt"; build_srt(blocks, offsets, srt)
        style = f"FontName={resolve_font('Helvetica Neue')},FontSize=18,Bold=1,Italic=0,PrimaryColour=&H00FFFFFF,OutlineColour=&H80000000,Outline=1.5,Shadow=0,MarginV=36"
        # relative filename + cwd=proj: ffmpeg's filter parser chokes on spaces/quotes in absolute paths
        vf.append(f"subtitles=filename=subtitles.srt:force_style='{style}'")
    if a.music:
        inputs += ["-stream_loop", "-1", "-i", str(Path(a.music).resolve())]
        fc.append(f"[1:a]volume={a.music_db}dB,afade=t=out:st={max(0,t-3)}:d=3[m];[0:a][m]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]")
        maps = ["-map", "0:v", "-map", "[a]"]
    cmd = [FFMPEG, "-y", "-v", "error", *inputs]
    if vf: cmd += ["-vf", ",".join(vf)]
    if fc: cmd += ["-filter_complex", ";".join(fc), *maps]
    if vf or fc:
        cmd += ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", str(final)]
        sh(cmd, cwd=proj)
    else:
        sh([FFMPEG, "-y", "-v", "error", "-i", str(joined), "-c", "copy", "-movflags", "+faststart", str(final)])
    if soft_srt:
        tmp = proj / "renders" / "muxed" / "with_subs.mp4"
        sh([FFMPEG, "-y", "-v", "error", "-i", str(final), "-i", str(soft_srt), "-c", "copy", "-c:s", "mov_text",
            "-metadata:s:s:0", "language=eng", "-movflags", "+faststart", str(tmp)])
        shutil.move(str(tmp), str(final))

    p = probe(final)
    print(f"final: {final}\n  {p['w']}x{p['h']} @ {p['fps']:.3g} fps, {p['duration']:.1f}s ({p['duration']/60:.2f} min), "
          f"{len(blocks)} blocks, subtitles={'burned' if a.subtitles else ('soft track' if soft_srt else 'off')}, music={'on' if a.music else 'off'}")
    print("  block offsets: " + ", ".join(f"{b['id']}@{o:.1f}s" for b, o in zip(blocks, offsets)))


if __name__ == "__main__":
    main()
