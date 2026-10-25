# Visual styles

Pick one theme per video and keep it. All three reference channels share one rule:
**the narration carries the words, the screen carries the picture.** On-screen text is a
label, a number, or a headline, never a paragraph.

| theme   | feel | bg | type | signature moves |
|---------|------|----|------|-----------------|
| `3b1b`  | 3Blue1Brown | black | Helvetica Neue, LaTeX math | Write/Create reveals, Transform between equation steps, colour-coded quantities, dots on number lines, braces with labels, slow camera zooms |
| `welch` | Welch Labs | warm charcoal | Helvetica Neue, thin strokes | slow `Create()` like a pen drawing, 3D surfaces/axes rotating, orange vs sky-blue contrast, annotations with thin arrows, numbers ticking |
| `econ`  | Economics Explained | navy | Avenir Next Bold | big headline with one gold word, bars growing, counters with $ and %, flag/map cutouts, cards sliding in from the side, end-of-video scorecard |
| `paper` | whiteboard / notebook | cream | Helvetica Neue | same as welch but light; thicker strokes |

Colours come from `self.theme` (`primary`, `secondary`, `accent`, `good`, `bad`, `muted`, `text`,
`palette`). Use them instead of literal hex so a style swap is one word in script.json.

## 3b1b in practice
- One idea per animation. Reveal, pause for a breath, then change *one* thing.
- Assign each quantity a colour at first appearance and never change it (principal = BLUE, interest = YELLOW).
- Equations: `MathTex` (needs LaTeX; see setup output). Step from one equation to the next with
  `TransformMatchingTex` so the viewer sees what moved. If LaTeX is missing use `Text("P(1+r)^n")`.
- Emphasis: `Indicate(mob)`, `Flash(point)`, `Circumscribe(mob)`. Shift new things in with `FadeIn(m, shift=UP*0.3)`.
- Axes: `Axes(x_range, y_range, axis_config={"color": self.theme.muted})`, plot with `axes.plot(f, color=self.theme.primary)`, draw with `Create(graph, run_time=3)`.
- Motion is smooth and unhurried; `rate_func=smooth` (default). Zoom with `ExplainerMovingCameraScene` and `self.camera.frame.animate.scale(0.6).move_to(target)`.

## welch in practice
- Thin stroke widths (`stroke_width=2`), lots of empty space, one object drawn at a time.
- 3D: `ExplainerThreeDScene`, `ThreeDAxes`, `Surface`, `Sphere`, `Arrow3D`, `self.begin_ambient_camera_rotation(rate=0.1)`.
  Set the camera with `self.set_camera_orientation(phi=65*DEGREES, theta=-45*DEGREES, zoom=0.8)` and
  `axes.shift(IN*0.8)` so the surface stays clear of a fixed-in-frame headline. Headlines/captions in 3D:
  `self.add_fixed_in_frame_mobjects(title); self.remove(title)` first, then animate them in with `FadeIn`
  (otherwise they get projected into the 3D world).
- Annotations: `Arrow(stroke_width=2, max_tip_length_to_length_ratio=0.1)` plus small `self.text(..., size=24)`.
- Tick numbers with `self.counter(...)`; let `Create` run 2–4 s so lines feel hand-drawn.

## econ in practice
- Open each block with `self.highlight("Inflation hit nine percent", "nine percent")` top-centre.
- Bars: `BarChart(values, bar_names=..., bar_colors=self.theme.palette)` then `Create` or animate `chart.animate.change_bar_values(new)`.
- Money/percent: `g, tr = self.counter(0, 2_300_000, prefix="$")` then `self.play(tr.animate.set_value(...), run_time=2)`.
- Cards: `RoundedRectangle(corner_radius=0.2, fill_opacity=1, fill_color=self.theme.grid, stroke_width=0)` with text inside; enter with `FadeIn(card, shift=RIGHT)`; exit with `FadeOut(card, shift=LEFT)`.
- Pace is faster: 2–4 visual changes per 10 s, short `run_time` (0.5–1 s), hard cuts between beats are fine.
- Closing scorecard: a column of category rows with scores that `Write` one by one.

## Things that look amateur (avoid)
- Text wider than the frame: keep `font_size` <= 48 for sentences, and `.scale_to_fit_width(config.frame_width - 1)` for safety.
- Objects overlapping other objects: `FadeOut` or `.animate.shift` old ones before adding new ones; `VGroup(...).arrange()` for lists.
- Empty screen while narration continues: hold a relevant object; add a small change every ~8 s.
- Animations still playing after narration has moved on: tie them with `self.at(...)`.
- Rainbow palettes: 2–3 colours plus neutrals.
