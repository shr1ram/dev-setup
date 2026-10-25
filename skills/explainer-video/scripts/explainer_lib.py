"""
Shared helpers for explainer-video Manim scenes.

Import in scenes.py:   from explainer_lib import *
(render.py puts this directory on PYTHONPATH.)

Everything here exists so a scene can be written in terms of the narration:
    self.at("Here's a question", Write(title))   # fire when those words are spoken
    self.finish()                                # hold until the narration ends
Attributes: self.theme, self.narration, self.narration_duration, self.words, self.now
"""
from __future__ import annotations

import dataclasses
import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

from manim import *  # noqa: F401,F403  (re-exported for scenes.py)
from manim import Scene, ThreeDScene, MovingCameraScene, Text, VGroup, DecimalNumber, ValueTracker, config
from manim import UP, DOWN, LEFT, RIGHT, ORIGIN, UL, UR, DL, DR, WHITE, BLACK

from fonts import resolve_font

# --------------------------------------------------------------------------- themes

@dataclass
class Theme:
    name: str
    bg: str
    text: str
    muted: str
    primary: str
    secondary: str
    accent: str
    good: str
    bad: str
    font: str
    font_weight: str = "NORMAL"
    grid: str = "#2A2A2A"
    tex_numbers: bool = False   # True: DecimalNumber/axis ticks in LaTeX (Computer Modern); False: theme font
    notes: str = ""
    palette: list = field(default_factory=list)

    def __post_init__(self):
        if not self.palette:
            self.palette = [self.primary, self.secondary, self.accent, self.good, self.bad]


THEMES = {
    # Grant Sanderson's look: black, blue/yellow, LaTeX math, one idea at a time.
    "3b1b": Theme(
        name="3b1b", bg="#000000", text="#FFFFFF", muted="#888888",
        primary="#58C4DD", secondary="#FFFF00", accent="#83C167",
        good="#83C167", bad="#FC6255", font="Helvetica Neue",
        grid="#1F3B47", tex_numbers=True,
        notes="Dark, math-forward, equations via MathTex, consistent colour per quantity.",
    ),
    # Welch Labs-ish: warm charcoal, thin elegant lines, orange/sky-blue, sketchy reveals.
    "welch": Theme(
        name="welch", bg="#15161A", text="#F2EDE4", muted="#8A877F",
        primary="#F28C28", secondary="#59A5D8", accent="#E8D8A0",
        good="#7FB069", bad="#D64545", font="Helvetica Neue", grid="#2C2E35",
        notes="Physics-notebook feel; slow Create() reveals, thin strokes, 3D surfaces welcome.",
    ),
    # Economics Explained-ish: navy, gold, bold condensed headlines, flat icons, charts.
    "econ": Theme(
        name="econ", bg="#14213D", text="#F1F1F1", muted="#8D99AE",
        primary="#FCA311", secondary="#4CC9F0", accent="#FFFFFF",
        good="#06D6A0", bad="#EF233C", font="Avenir Next", font_weight="BOLD", grid="#243557",
        notes="Fast, punchy, bold typography with highlighted key words, bar charts, counters, scorecards.",
    ),
    # Light paper variant for a hand-drawn / whiteboard feel.
    "paper": Theme(
        name="paper", bg="#F4F1EA", text="#1F2A44", muted="#7A8290",
        primary="#D9480F", secondary="#1C7ED6", accent="#2B8A3E",
        good="#2B8A3E", bad="#C92A2A", font="Helvetica Neue", grid="#D8D3C7",
        notes="Light background; use darker strokes and slightly thicker lines.",
    ),
}


# --------------------------------------------------------------------------- number fonts
import shutil as _shutil
HAS_LATEX = bool(_shutil.which("latex") or os.path.exists("/Library/TeX/texbin/latex"))
# DecimalNumber (and so Axes/NumberLine tick labels, self.counter) default to MathTex digits.
# Without LaTeX that crashes; with LaTeX it renders Computer Modern serif, which only suits the
# 3b1b theme. ExplainerScene.setup sets EXPLAINER_TEX_NUMBERS from the theme; we swap in Text.
from manim import SingleStringMathTex as _SSMT, MathTex as _MT
_dn_init = DecimalNumber.__init__


class _NumText(Text):
    """Text digits in the active theme's font (set by ExplainerScene.setup via env)."""
    def __init__(self, s, **kw):
        f = os.environ.get("EXPLAINER_FONT")
        if f:
            kw.setdefault("font", f)
        super().__init__(s, **kw)


def _dn_init_patched(self, *a, **kw):
    want_tex = HAS_LATEX and os.environ.get("EXPLAINER_TEX_NUMBERS", "1") == "1"
    mc = kw.get("mob_class", _MT)
    if not want_tex and isinstance(mc, type) and issubclass(mc, _SSMT):
        kw["mob_class"] = _NumText
    _dn_init(self, *a, **kw)


DecimalNumber.__init__ = _dn_init_patched


def _strip(w: str) -> str:
    return re.sub(r"[^\w']", "", w.lower())


def _find(names: list[str], target: list[str], occurrence: int) -> int | None:
    """Index where `target` starts for the `occurrence`-th time in `names`, or None."""
    seen = 0
    for k in range(len(names) - len(target) + 1):
        if names[k:k + len(target)] == target:
            seen += 1
            if seen == occurrence:
                return k
    return None


# --------------------------------------------------------------------------- base scene

class _ExplainerMixin:
    """Loads this block's narration timings and theme. Mixed into Scene variants below."""

    block: str | None = None      # e.g. "01". Defaults to the digits after "Block" in the class name.
    theme_name: str | None = None  # override the script's style for one scene

    # ---- lifecycle
    def setup(self):
        project = Path(os.environ.get("EXPLAINER_PROJECT", "."))
        self.project = project
        self.script = json.loads((project / "script.json").read_text())
        theme = THEMES[self.theme_name or self.script.get("style", "3b1b")]
        # macOS theme fonts are swapped for installed lookalikes elsewhere (see fonts.py).
        self.theme: Theme = dataclasses.replace(theme, font=resolve_font(theme.font))
        self.camera.background_color = self.theme.bg
        os.environ["EXPLAINER_FONT"] = self.theme.font
        os.environ["EXPLAINER_TEX_NUMBERS"] = "1" if self.theme.tex_numbers else "0"

        timings = {}
        tpath = project / "timings.json"
        if tpath.exists():
            timings = {b["id"]: b for b in json.loads(tpath.read_text())["blocks"]}
        m = re.match(r"Block(\d+)", type(self).__name__)   # same rule as render.py
        bid = self.block or (m.group(1) if m else "")
        self.block_id = bid
        info = timings.get(bid)
        if info is None:
            print(f"[explainer] WARNING: no timings for block {bid}; using 10s placeholder")
            info = {"duration": 10.0, "words": []}
        # NB: Manim's Scene overwrites `self.duration` on every play(); keep our own name.
        self.narration_duration: float = float(info["duration"])
        self.words: list[dict] = info.get("words", [])
        self.narration: str = next(
            (b["narration"] for b in self.script["blocks"] if b["id"] == bid), "")

    # ---- time helpers
    @property
    def now(self) -> float:
        """Seconds of video rendered so far."""
        return float(getattr(self.renderer, "time", 0.0))

    def wait_until(self, t: float):
        d = t - self.now
        if d > 1.0 / config.frame_rate:
            self.wait(d)

    def word_time(self, phrase: str, occurrence: int = 1, end: bool = False) -> float:
        """Time (s) when `phrase` starts (or ends) in the narration. Falls back to a
        proportional estimate if word timings are missing, so scenes still render. A phrase
        that is not in the narration raises KeyError either way."""
        target = [_strip(w) for w in phrase.split() if _strip(w)]
        if not target:
            raise ValueError(f"phrase {phrase!r} has no words to match")
        n = len(target)
        if not self.words:
            # No word timestamps (non-English voice, or tts.py not run yet): match on the narration
            # text the same way and estimate the time from the word's position.
            names = [t for w in self.narration.split() if (t := _strip(w))]
            k = _find(names, target, occurrence)
            if k is not None:
                return (k + (n if end else 0)) / max(1, len(names)) * self.narration_duration
            # Languages written without spaces (Chinese, Japanese): plain substring position.
            idx = self.narration.lower().find(phrase.lower())
            if idx >= 0:
                return (idx + (len(phrase) if end else 0)) / max(1, len(self.narration)) * self.narration_duration
        else:
            # Kokoro emits punctuation as tokens of its own; match on words only, keeping each word's
            # index into self.words for its timestamps.
            toks = [(t, i) for i, w in enumerate(self.words) if (t := _strip(w["w"]))]
            k = _find([t for t, _ in toks], target, occurrence)
            if k is not None:
                first, last = toks[k][1], toks[k + n - 1][1]
                return float(self.words[last]["e"] if end else self.words[first]["s"])
        raise KeyError(f"phrase {phrase!r} not found in block {self.block_id} narration: {self.narration!r}")

    def at(self, phrase: str, *anims, occurrence: int = 1, lead: float = 0.0, **kw):
        """Wait until `phrase` is spoken (minus `lead` seconds), then play anims."""
        t = self.word_time(phrase, occurrence) - lead
        late = self.now - t
        if late > 0.5:
            print(f"[explainer] WARNING: block {self.block_id}: {phrase!r} fires {late:.1f}s late "
                  f"(spoken at {t:.1f}s, scene already at {self.now:.1f}s); shorten the run_time of earlier animations")
        self.wait_until(t)
        if anims:
            self.play(*anims, **kw)

    def finish(self, tail: float = 0.6):
        """Hold the last frame until the narration has ended (+tail). Call last."""
        over = self.now - self.narration_duration
        if over > tail + 0.5:
            print(f"[explainer] WARNING: block {self.block_id}: visuals run {over:.1f}s past the narration "
                  f"({self.now:.1f}s vs {self.narration_duration:.1f}s of speech); trim animations or add narration")
        self.wait_until(self.narration_duration + tail)

    # ---- text helpers in the theme
    def text(self, s: str, size: float = 36, color=None, weight=None, **kw) -> Text:
        t = self.theme
        kwargs = dict(font_size=size, color=color or t.text, **kw)
        if t.font:
            kwargs["font"] = t.font
        kwargs["weight"] = weight or t.font_weight
        return Text(s, **kwargs)

    def headline(self, s: str, size: float = 54, color=None) -> Text:
        return self.text(s, size=size, color=color or self.theme.text, weight="BOLD").to_edge(UP, buff=0.6)

    @property
    def safe_bottom(self) -> float:
        """Lowest y you should place content at: burned subtitles cover everything below y = -2.3."""
        return -2.3 if self.script.get("subtitles") else -3.6

    def caption(self, s: str, size: float = 28) -> Text:
        buff = 1.7 if self.script.get("subtitles") else 0.5
        return self.text(s, size=size, color=self.theme.muted).to_edge(DOWN, buff=buff)

    def highlight(self, sentence: str, key: str, size: float = 48) -> Text:
        """Sentence with `key` words in the primary colour (Economics-Explained style)."""
        return self.text(sentence, size=size, weight="BOLD", t2c={key: self.theme.primary})

    def counter(self, start: float, end: float, prefix: str = "", suffix: str = "",
                decimals: int = 0, size: float = 64, color=None):
        """Returns (group, tracker), with `group.end` = `end`.
        Animate with tr.animate.set_value(group.end) (or any other value)."""
        tr = ValueTracker(start)
        num = DecimalNumber(start, num_decimal_places=decimals, font_size=size,
                            color=color or self.theme.primary, group_with_commas=True)
        num.add_updater(lambda m: m.set_value(tr.get_value()))
        parts = []
        if prefix:
            parts.append(self.text(prefix, size=size, color=color or self.theme.primary))
        parts.append(num)
        if suffix:
            parts.append(self.text(suffix, size=size * 0.6, color=color or self.theme.primary))
        g = VGroup(*parts).arrange(RIGHT, buff=0.08, aligned_edge=DOWN)
        g.tracker = tr
        g.number = num
        g.end = end
        return g, tr

    def bullets(self, items: list[str], size: float = 34, buff: float = 0.35) -> VGroup:
        rows = VGroup(*[self.text("•  " + s, size=size) for s in items])
        return rows.arrange(DOWN, aligned_edge=LEFT, buff=buff)


class ExplainerScene(_ExplainerMixin, Scene):
    pass


class ExplainerMovingCameraScene(_ExplainerMixin, MovingCameraScene):
    pass


class ExplainerThreeDScene(_ExplainerMixin, ThreeDScene):
    pass


__all__ = [n for n in dir() if not n.startswith("_")] + ["ExplainerScene", "ExplainerMovingCameraScene", "ExplainerThreeDScene", "THEMES", "Theme"]
