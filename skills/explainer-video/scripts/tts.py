#!/usr/bin/env python3
"""
Narrate every block of <project>/script.json with Kokoro (local, free).

Writes  <project>/audio/<id>.wav   (24 kHz mono)
        <project>/timings.json     durations + word timestamps per block

Usage:  tts.py PROJECT_DIR [--blocks 01,03] [--voice af_heart] [--speed 1.0]
Re-running only regenerates the blocks you ask for (or whose narration changed).
"""
import sys as _s, os as _o; _s.path.insert(0, _o.path.dirname(_o.path.abspath(__file__))); import _bootstrap  # noqa: E402
import argparse, hashlib, json, os, re, sys, warnings
warnings.filterwarnings("ignore")
os.environ.setdefault("TORCH_CPP_LOG_LEVEL", "ERROR")
from pathlib import Path

import numpy as np
import soundfile as sf

SR = 24000
PAD_HEAD, PAD_TAIL = 0.25, 0.45   # silence around each take so words never clip at cuts


def norm_text(s: str) -> str:
    # Kokoro reads digits fine but spelled-out numbers sound more natural in narration.
    return re.sub(r"\s+", " ", s).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("project")
    ap.add_argument("--blocks", help="comma-separated block ids to (re)generate")
    ap.add_argument("--voice")
    ap.add_argument("--speed", type=float)
    ap.add_argument("--force", action="store_true", help="regenerate even if narration unchanged")
    a = ap.parse_args()

    proj = Path(a.project)
    script = json.loads((proj / "script.json").read_text())
    voice = a.voice or script.get("voice", "af_heart")
    speed = a.speed or float(script.get("speed", 1.0))
    lang = script.get("lang", "a")   # 'a' American, 'b' British English; see Kokoro docs for others
    (proj / "audio").mkdir(exist_ok=True)

    tpath = proj / "timings.json"
    old = {b["id"]: b for b in json.loads(tpath.read_text())["blocks"]} if tpath.exists() else {}
    want = set(a.blocks.split(",")) if a.blocks else None

    from kokoro import KPipeline
    pipe = KPipeline(lang_code=lang, repo_id="hexgrad/Kokoro-82M")

    out = []
    for b in script["blocks"]:
        bid, text = b["id"], norm_text(b["narration"])
        key = f"{voice}|{speed}|{text}" + (f"|{lang}" if lang != "a" else "")
        digest = hashlib.sha1(key.encode()).hexdigest()[:12]
        prev = old.get(bid)
        reuse = (prev and prev.get("hash") == digest and (proj / prev["audio"]).exists()
                 and not a.force and (want is None or bid not in want))
        if reuse:
            out.append(prev); continue
        if want is not None and bid not in want and prev:
            out.append(prev); continue

        chunks, words, offset = [], [], PAD_HEAD
        for r in pipe(text, voice=voice, speed=speed, split_pattern=r"\n+"):
            audio = r.audio.numpy() if hasattr(r.audio, "numpy") else np.asarray(r.audio)
            for tk in (r.tokens or []):
                if getattr(tk, "start_ts", None) is not None and tk.text.strip():
                    words.append({"w": tk.text, "s": round(offset + tk.start_ts, 3),
                                  "e": round(offset + tk.end_ts, 3)})
            chunks.append(audio)
            offset += len(audio) / SR
        audio = np.concatenate([np.zeros(int(PAD_HEAD * SR), dtype=np.float32), *chunks,
                                np.zeros(int(PAD_TAIL * SR), dtype=np.float32)])
        rel = f"audio/{bid}.wav"
        sf.write(proj / rel, audio, SR)
        dur = round(len(audio) / SR, 3)
        out.append({"id": bid, "audio": rel, "duration": dur, "words": words, "hash": digest})

    tpath.write_text(json.dumps({"voice": voice, "speed": speed, "blocks": out}, indent=1))

    total = 0.0
    print(f"{'block':<6}{'secs':>7}{'words':>7}{'w/s':>6}  note")
    for b in out:
        n = sum(1 for w in b["words"] if re.search(r"[A-Za-z0-9]", w["w"])); d = b["duration"]; total += d
        wps = n / max(0.1, d - PAD_HEAD - PAD_TAIL)
        note = ""
        if d > 60: note += "LONG (>60s) consider splitting; "
        if wps > 3.2: note += "fast (>3.2 w/s); set speed 0.9 or trim; "
        if not b["words"]: note += "NO WORD TIMINGS (non-English?) at() will estimate; "
        print(f"{b['id']:<6}{d:>7.1f}{n:>7}{wps:>6.2f}  {note}")
    print(f"total  {total:>7.1f}s  ({total/60:.1f} min)  -> {tpath}")


if __name__ == "__main__":
    main()
