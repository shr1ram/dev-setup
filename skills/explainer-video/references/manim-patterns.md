# scenes.py patterns

A complete worked example (3 blocks, 3b1b style, renders cleanly): `example-scenes.py` with
`example-script.json`. Copy its structure rather than starting from a blank file.

```python
from explainer_lib import *          # Manim + ExplainerScene + THEMES

class Block01(ExplainerScene):
    def construct(self):
        t = self.theme
        title = self.headline("Compound interest")
        self.at("compound interest", Write(title))              # fires when spoken
        coins = VGroup(*[Circle(0.25, color=t.secondary, fill_opacity=1) for _ in range(10)]).arrange(RIGHT, buff=0.1)
        self.at("one hundred dollars", LaggedStart(*[GrowFromCenter(c) for c in coins], lag_ratio=0.1))
        g, tr = self.counter(100, 110, prefix="$")
        g.next_to(coins, DOWN)
        self.add(g)
        self.at("ten percent", tr.animate.set_value(110), run_time=1.5)
        self.finish()                                           # hold until narration ends
```

## The timing contract
- `tts.py` runs first, so every scene knows its narration length (`self.narration_duration`) and word times.
- `self.at("phrase", *anims)` waits until that phrase is spoken, then plays. Phrase matching ignores
  case and punctuation (commas and full stops between the words are fine); use `occurrence=2` for a
  repeated phrase, `lead=0.3` to start slightly before. A beat that can't fire on time (earlier
  animations ran long) prints `[explainer] WARNING ... fires Xs late` in render.py's output.
  A wrong phrase raises `KeyError` with the narration printed, so you can fix the string. Apostrophes are
  part of the token: `self.at("Bayes' rule")`, not `self.at("Bayes")`.
- `self.finish()` as the last line holds the final frame to the end of the audio. Without it the
  assembler clones the last frame anyway, but animations that outrun the audio get cut.
- Never let animation time exceed narration: if a block needs 40 s of animation but has 20 s of
  speech, the words are wrong, not the animation. Add narration or cut visuals.
- Read `self.now` for the current time if you need arithmetic (e.g. a `run_time` that ends on a word:
  `run_time=self.word_time("doubles") - self.now`).

## Scene types
- `ExplainerScene` (2D), `ExplainerMovingCameraScene` (zoom/pan with `self.camera.frame`),
  `ExplainerThreeDScene` (`self.set_camera_orientation(phi=70*DEGREES, theta=-45*DEGREES)`).
- Class name must start with `Block` and contain the block id digits: `Block01`, `Block07`.
- One class per block; each renders independently and in parallel, so keep them self-contained.
  To carry an object across blocks, rebuild it at the start of the next block (same position) and
  `self.add()` it before any animation.

## Helpers on the scene
- `self.text(s, size, color, weight)` themed `Text`; `self.headline(s)` top; `self.caption(s)` bottom.
- `self.highlight(sentence, key)` bold sentence with `key` in primary colour.
- `self.counter(start, end, prefix, suffix, decimals)` -> `(group, tracker)`.
- `self.bullets([...])` arranged list.
- `self.theme.primary/secondary/accent/good/bad/muted/text/grid/palette`.

## Reliable Manim recipes (v0.19+)
- Axes & plots: `ax = Axes(x_range=[0,10,2], y_range=[0,300,100], x_length=8, y_length=4.5, axis_config={"include_numbers": True})`;
  `curve = ax.plot(lambda x: 100*1.1**x, color=...)`; `label = ax.get_graph_label(curve, "y")`; `area = ax.get_area(curve, x_range=[0,10], opacity=0.3)`.
- Moving dot: `dot = Dot(ax.c2p(0, f(0)))`; `self.play(MoveAlongPath(dot, curve), run_time=3)`.
- Equations (needs LaTeX): `eq = MathTex("A", "=", "P", "(1+r)^n")`; colour with `eq[2].set_color(BLUE)`;
  step: `self.play(TransformMatchingTex(eq1, eq2))`. Without LaTeX: `Text("A = P(1+r)ⁿ")`.
- Braces: `b = Brace(mob, DOWN); lbl = b.get_text("principal")`.
- Bar chart: `BarChart(values=[..], bar_names=[..], y_range=[0,100,20], bar_colors=theme.palette)`; animate with `chart.animate.change_bar_values([...])`.
- Number line / pile of dots / grid: `NumberLine`, `VGroup(*[Dot() for _ in range(n)]).arrange_in_grid(rows=..)`.
- Stagger: `LaggedStart(*anims, lag_ratio=0.15)`; group reveal: `AnimationGroup`.
- Keep everything inside the frame: `config.frame_width` x `config.frame_height` (14.2 x 8 for 16:9, 4.5 x 8 for 9:16); `.to_edge()`, `.scale_to_fit_width()`.
- Vertical videos: stack vertically, font sizes ~0.6x, headlines shorter.
- Fonts: the themes use `Helvetica Neue` / `Avenir Next` (macOS). Elsewhere `scripts/fonts.py` swaps in
  the closest installed font (TeX Gyre Heros, Nunito Sans, ...) and prints a note. If you pass `font=`
  yourself, use `resolve_font("Futura")` etc. so it works on both. Weights: `NORMAL`, `BOLD`, `SEMIBOLD`, `LIGHT`.
- Images: `ImageMobject("path.png").scale_to_fit_height(3)` (use `Group`, not `VGroup`, with images). SVG: `SVGMobject("icon.svg")`.
- `-q l` previews are 854x480@15fps: text looks coarse there, judge layout not crispness.

## Pitfalls
- Numbers: in the `3b1b` theme `DecimalNumber`/axis ticks/`self.counter` render in LaTeX (Computer Modern,
  like the real channel). In every other theme they render as `Text` in the theme font automatically.
  Override per theme with `tex_numbers` in `THEMES`.
- `always_redraw(lambda: ...)` rebuilds the mobject every frame, so a `.move_to()` applied afterwards is
  lost; put positioning inside the lambda.
- Burned subtitles cover the bottom ~1.5 scene units (y < -2.3). With `"subtitles": true` in script.json,
  `self.caption()` moves up automatically and `self.safe_bottom` gives the lowest safe y; keep number
  lines, x-axes and bottom labels above it.
- Cross-type transforms (`Text` -> `MathTex`, or very different shapes) look like a garbled blob mid-way;
  use `FadeOut`/`FadeIn` (or `FadeTransform`) instead of `ReplacementTransform`.
- Don't name your own attributes `duration`, `animations`, `mobjects`, `time`: Manim's Scene overwrites them. The narration length is `self.narration_duration`.
- Keep ~0.6 scene units of margin on both sides for axis/brace labels: a label placed `RIGHT` of an object near the edge gets clipped. Check the sheet.
- `Text` with `font=""` errors; `self.text()` only passes `font` when the theme sets one.
- `MathTex`/`Tex` without LaTeX raise at render time; check `setup.sh` output first. `DecimalNumber`, axis tick numbers and `self.counter` are patched to use `Text` automatically when LaTeX is missing (`HAS_LATEX` in explainer_lib).
- `set_color_by_t2c` keys must be exact substrings of the text.
- `ThreeDScene` + `Text`: call `self.add_fixed_in_frame_mobjects(text)` so labels face the camera.
- Updaters keep running during `wait`; remove with `mob.clear_updaters()` when done.
- Long `Write` on big text looks slow: use `FadeIn(..., shift=UP*0.2, run_time=0.6)` for headlines in econ style.
