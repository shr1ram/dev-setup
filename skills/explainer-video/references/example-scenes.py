from explainer_lib import *


class Block01(ExplainerScene):
    def construct(self):
        t = self.theme
        title = self.headline("A question")
        self.at("Here's a question", FadeIn(title, shift=UP * 0.3), run_time=0.8)

        money, tr = self.counter(100, 100, prefix="$", size=96, color=t.primary)
        money.move_to(ORIGIN)
        self.at("one hundred dollars", FadeIn(money, scale=0.8), run_time=0.6)

        rate = self.text("+10% per year", size=36, color=t.muted).next_to(money, DOWN, buff=0.5)
        self.at("ten percent", FadeIn(rate, shift=UP * 0.2), run_time=0.5)
        years = self.text("30 years", size=36, color=t.muted).next_to(rate, DOWN, buff=0.25)
        self.at("thirty years", FadeIn(years, shift=UP * 0.2), run_time=0.5)

        guess = self.text("$400 ?", size=48, color=t.muted).to_edge(LEFT, buff=1.2).shift(UP * 0.3)
        self.at("four hundred", Write(guess), run_time=0.8)

        self.at("seventeen hundred", tr.animate.set_value(1745), FadeOut(guess), run_time=2.0, rate_func=rush_into)
        self.play(Circumscribe(money, color=t.secondary, run_time=1.2))
        self.finish()


class Block02(ExplainerScene):
    def construct(self):
        t = self.theme
        title = self.headline("Interest earns interest")
        self.at("interest earns interest", FadeIn(title, shift=UP * 0.3), run_time=0.8)

        bal = [100 * 1.1 ** k for k in range(6)]          # balance at start of each year
        unit = 0.022                                         # scene units per dollar
        bars = VGroup()
        for k in range(6):
            base = Rectangle(width=0.9, height=bal[k] * unit, fill_color=t.primary, fill_opacity=1, stroke_width=0)
            cap = Rectangle(width=0.9, height=bal[k] * 0.1 * unit, fill_color=t.secondary, fill_opacity=1, stroke_width=0)
            cap.next_to(base, UP, buff=0)
            lbl = self.text(f"+${bal[k] * 0.1:.0f}", size=22, color=t.secondary).next_to(cap, UP, buff=0.12)
            yr = self.text(f"yr {k + 1}", size=22, color=t.muted).next_to(base, DOWN, buff=0.15)
            bars.add(VGroup(base, cap, lbl, yr))
        bars.arrange(RIGHT, buff=0.45, aligned_edge=DOWN).move_to(DOWN * 0.4)

        def grow(group):
            base, cap, lbl, yr = group
            return Succession(
                AnimationGroup(GrowFromEdge(base, DOWN), FadeIn(yr)),
                AnimationGroup(GrowFromEdge(cap, DOWN), FadeIn(lbl, shift=UP * 0.15)),
            )

        self.at("year one", grow(bars[0]), run_time=1.4)
        self.at("year two", grow(bars[1]), run_time=1.4)
        self.at("Each year", LaggedStart(*[grow(b) for b in bars[2:]], lag_ratio=0.35), run_time=3.0)
        self.at("stack", Indicate(VGroup(*[b[1] for b in bars]), color=t.secondary, scale_factor=1.05), run_time=1.0)
        self.finish()


class Block03(ExplainerScene):
    def construct(self):
        t = self.theme
        ax = Axes(x_range=[0, 30, 5], y_range=[0, 1800, 300], x_length=9.5, y_length=5.2,
                  axis_config={"color": t.muted, "include_numbers": True, "font_size": 20,
                               "decimal_number_config": {"num_decimal_places": 0}}).shift(DOWN * 0.2 + LEFT * 1.2)
        xl = self.text("years", size=22, color=t.muted).next_to(ax.x_axis, DOWN, buff=0.3)
        yl = self.text("$", size=22, color=t.muted).next_to(ax.y_axis, UP, buff=0.2)
        self.at("Plot it", Create(ax), FadeIn(xl), FadeIn(yl), run_time=1.5)

        simple = ax.plot(lambda x: 100 + 10 * x, x_range=[0, 30], color=t.primary, stroke_width=4)
        simple_lbl = self.text("simple", size=24, color=t.primary).next_to(ax.c2p(30, 400), RIGHT, buff=0.15)
        self.at("Simple interest", Create(simple), FadeIn(simple_lbl), run_time=1.5)

        compound = ax.plot(lambda x: 100 * 1.1 ** x, x_range=[0, 30], color=t.secondary, stroke_width=4)
        comp_lbl = self.text("compound", size=24, color=t.secondary).next_to(ax.c2p(30, 1745), RIGHT, buff=0.15)
        self.at("Compound interest", Create(compound, rate_func=linear),
                run_time=max(1.5, self.word_time("steeply", end=True) - self.word_time("Compound interest")))
        self.play(FadeIn(comp_lbl), run_time=0.4)

        gap = ax.get_area(compound, x_range=[0, 30], bounded_graph=simple, color=t.secondary, opacity=0.25)
        self.at("The gap", FadeIn(gap), run_time=1.0)

        brace = Brace(Line(ax.c2p(30, 400), ax.c2p(30, 1745)), RIGHT, color=t.text, buff=1.8)
        blbl = self.text("interest on\ninterest", size=20, color=t.text, line_spacing=0.9).next_to(brace, RIGHT, buff=0.15)
        self.at("most of the money", GrowFromCenter(brace), FadeIn(blbl), run_time=0.8)
        self.finish()
