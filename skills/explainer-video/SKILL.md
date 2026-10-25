---
name: explainer-video
description: |
  Make a complete narrated explainer video, free and fully local, in the style of 3Blue1Brown,
  Welch Labs or Economics Explained: research the topic, write a block-by-block script, narrate it
  with Kokoro TTS, animate each block with Manim (timed to the spoken words), and assemble the final
  MP4 with ffmpeg, optional subtitles and music. Use this whenever the user asks for an explainer
  video, an animated explanation, a narrated video, a "3blue1brown-style" or "math animation" video,
  a video essay, a faceless YouTube video, or wants to "turn this topic/paper/doc into a video",
  even if they don't say "explainer". Not for editing existing footage, talking-head videos, or
  photoreal AI-generated clips.
argument-hint: "[topic or source files] [style: 3b1b|welch|econ|paper] [length] [aspect]"
allowed-tools: Bash, Read, Write, Edit, WebSearch, WebFetch
---

# Explainer video (local, free)

One project directory in, one `final.mp4` out. Put new projects in `$SKILL/videos/<name>/`
(gitignored; `$SKILL` is `~/.claude/skills/explainer-video`, a symlink to this repo's `skills/explainer-video`),
or in `$EXPLAINER_OUT/<name>/` when that is set. Narration is generated first, so every animation can
be timed to the exact word it illustrates; that is what makes the result feel like the reference
channels rather than a slideshow.

```
project/
  script.json      you write: style, voice, blocks (narration + visual beats)   -> references/script-format.md
  audio/ timings.json   scripts/tts.py      narration + word timestamps
  scenes.py        you write: one Manim class per block                          -> references/manim-patterns.md
  renders/blocks/  scripts/render.py   silent block videos
  final.mp4        scripts/assemble.py mux, concat, subtitles, music
```

## 0. Environment

```bash
SKILL=~/.claude/skills/explainer-video; bash $SKILL/scripts/setup.sh
```
Run this once at the start: it installs anything missing (on macOS Homebrew libs; on Linux it only
checks the system packages, which come from the image) plus a uv venv with Manim + Kokoro, and prints
what is available. If it ends with `setup failed: ...` (exit status 1), something required is missing:
fix that (or tell the user) before going on. Read its last lines: if `latex: MISSING`, use `Text()` instead
of `MathTex` or ask the user to install BasicTeX. The scripts below re-exec themselves inside that
venv, so call them with plain `python3` from any shell; `$SKILL` is just shorthand for the path.

## Unattended mode

When the prompt says the run is unattended (e.g. an automation making a video for a paper on a
reading list) or `EXPLAINER_UNATTENDED=1` is set, nobody is there to answer or watch:
- Ask nothing. Instead of step 1, pick the style from the topic (`3b1b` for maths/CS/ML theory,
  `welch` for physics and ML intuition, `econ` for economics/markets), 2–3 min, 16:9, voice `af_heart`,
  subtitles on, no music, unless the prompt says otherwise.
- Put the project where the prompt says, else `$EXPLAINER_OUT/<name>/` if set, else `$SKILL/videos/<name>/`.
  (Callers: pass the path in the prompt or set `EXPLAINER_OUT`; nothing sets it by default.)
- Bound the preview loop: at most 3 fix-and-re-render rounds per block, then keep the best version.
- Don't `open` anything. Always finish with exactly one of
  `python3 $SKILL/scripts/result.py project/ --status ok` or
  `python3 $SKILL/scripts/result.py project/ --status failed --reason "<one sentence>"`.
  `result.json` is what the caller reads; if you hit a problem you cannot fix, record the failure
  rather than stopping silently.

## 1. Settle the brief in one turn

Ask once, listing defaults, and proceed with the defaults if the user says "you choose":
style (`3b1b` math/CS, `econ` for money/markets/countries, `welch` for physics/ML intuition,
`paper` for a light whiteboard look),
length (default 2–3 min), aspect (16:9), voice (`af_heart`), subtitles (off), music (none unless
they give a file). If the request already settles these, don't ask. Read `references/styles.md`
for what each style means in practice.

## 2. Research

For a real topic, verify facts with web tools before scripting and keep a Sources list for the
delivery note; never script numbers or dates from memory. For a user's own document, read it and
use only what it says (for a PDF, if the Read tool can't render pages, extract text with pypdf
using the skill venv: `$SKILL/.venv/bin/python`). Decide the one-sentence thesis and the 5–9 beats that get a viewer there.

## 3. Write `script.json`

Format in `references/script-format.md`. Each block is one visual idea with 15–45 s of narration.
Write the narration as speech (spell out numbers that are spoken, short sentences, no "in this
video"). Write each block's `visual` as beats keyed to exact narration phrases, because the scene
code will trigger on those words. Hook in block 1, payoff in the last block.

Then narrate and check pacing:
```bash
python3 $SKILL/scripts/tts.py project/
```
It prints seconds, word count and words/second per block. Fix blocks flagged LONG or fast by
editing the narration and re-running (only changed blocks regenerate).

## 4. Write `scenes.py`

Read `references/manim-patterns.md` first (the timing contract and helpers), skim
`references/example-scenes.py`, and read the relevant section of `references/styles.md`. One `BlockNN(ExplainerScene)` class per block; use
`self.at("phrase", anims)` to sync and `self.finish()` to end. Use theme colours, not hex literals.
Keep every object inside the frame and remove old objects before adding new ones.

Preview fast, then look at the frames (you can't watch video; the contact sheet is your eyes):
```bash
python3 $SKILL/scripts/render.py project/ -q l
python3 $SKILL/scripts/sheet.py project/ --blocks        # -> renders/sheets/NN.png
```
Open each sheet with Read (tiles are exact timestamps). Check: text cut off, overlaps, long empty stretches, colours, and that
the beats land near the right timestamps. Fix and re-render only those blocks (`--blocks 03` or `--blocks 03,05`, comma-separated, one argument), then `sheet.py project/renders/blocks/03.mp4` for just that one.
If subtitles are on, set `"subtitles": true` in script.json so scenes keep the caption band clear.

## 5. Final render and assembly

```bash
python3 $SKILL/scripts/render.py project/ -q h            # 1080p (add --fps 60 if wanted)
python3 $SKILL/scripts/assemble.py project/ --subtitles   # --music path.mp3 --music-db -22
python3 $SKILL/scripts/sheet.py project/final.mp4 --every 5
```
`assemble.py` never stretches or speeds anything: a block is max(video, audio) long. Read its
summary and the final sheet once more. Then play it: `open project/final.mp4` for the user.

## Deliver

Give the path, duration, resolution, style, voice, subtitle/music status and the Sources list.
Mention how to change things cheaply: narration edits only re-run tts + that block's render.

## When things go wrong
- `KeyError: phrase ... not found`: the `at()` string doesn't match the narration; copy it from the error.
- `[explainer] WARNING ... fires Xs late` (printed by render.py): earlier animations in that block run
  too long, so this beat lands after its word; shorten their `run_time`s.
- `[explainer] WARNING ... visuals run Xs past the narration`: trim animations or add narration.
- Block video shorter than audio (assembler note): add `self.finish()` or more visuals.
- `FAIL BlockNN ... still rendering after Ns`: either the scene hangs (often an updater that never
  settles, or a huge `wait`; fix it) or it is a long block at high quality that just needs longer
  (`--timeout`; defaults are 600 s at `-q l`/`m`, 1800 s at `h`, 3600 s at `k`). Then re-render that block.
- `[explainer] font 'Helvetica Neue' not installed; using ...`: normal on Linux; the theme's macOS font
  was swapped for the closest installed one (see `scripts/fonts.py`).
- `explainer-video venv not found`: run `bash $SKILL/scripts/setup.sh`.
- MathTex errors: no LaTeX; switch to `Text()` or install BasicTeX.
- Kokoro pronounces a term oddly: respell it phonetically in narration (e.g. "Nvidia" -> "en-vidia"),
  or use `[Kokoro](/kˈOkəɹO/)` phoneme markup.
- Want AI-generated b-roll instead of Manim for a block? That needs a GPU model (Wan 2.2 / LTX-2); out
  of scope here, but a block's mp4 in `renders/blocks/` can come from anywhere as long as its
  resolution matches.
