---
name: manim
import: manim
version: community 0.18+
category: Animation
tags: math, animation, video, mobject, scene
bundled: true
---

# manim (Community Edition)

**Mathematical animation engine.** Bundled with cairo, pycairo, manimpango, and h264_videotoolbox so scenes render straight to MP4 on-device.

## Anatomy of a scene

```python
from manim import *

class Hello(Scene):
    def construct(self):
        txt = Text("Hello, manim!", font_size=56)
        self.play(Write(txt))
        self.wait(1)
        self.play(FadeOut(txt))
```

Save this as `hello.py` in your Workspace. Tap the render button → you'll get `hello.mp4` right next to it.

## Mobjects (the "things" you animate)

```python
# 2D shapes
Circle(radius=1, color=BLUE, fill_opacity=0.5)
Square(side_length=2, color=RED)
Triangle()
RegularPolygon(n=6, color=GREEN)
Star(n=5, outer_radius=1)
Rectangle(width=3, height=1)
Ellipse(width=4, height=2)

# Lines & arrows
Line(LEFT, RIGHT)
Arrow(ORIGIN, UP*2, buff=0)
Vector([1, 2])
DoubleArrow(LEFT, RIGHT)

# Text
Text("hello", font_size=48)
MarkupText("<b>bold</b> and <i>italic</i>")
Tex(r"$E = mc^2$")           # LaTeX via bundled texlive
MathTex(r"\int_0^1 x^2 dx = \frac{1}{3}")
```

## Animations

```python
# Appearance
self.play(Create(obj))          # drawing stroke
self.play(Write(txt))           # handwriting effect (Text/Tex)
self.play(FadeIn(obj))
self.play(GrowFromCenter(obj))
self.play(DrawBorderThenFill(obj))

# Disappearance
self.play(FadeOut(obj))
self.play(Uncreate(obj))
self.play(ShrinkToCenter(obj))

# Transforms
self.play(Transform(a, b))             # morph a into b
self.play(ReplacementTransform(a, b))  # like Transform but replaces references
self.play(Rotate(obj, angle=PI))
self.play(obj.animate.shift(UP*2))
self.play(obj.animate.scale(2))
self.play(obj.animate.set_color(YELLOW))

# Running together / in sequence
self.play(FadeIn(a), FadeIn(b))                        # parallel
self.play(AnimationGroup(FadeIn(a), FadeIn(b), lag_ratio=0.2))
self.play(LaggedStart(*[Create(m) for m in group], lag_ratio=0.1))
```

## Colors

Hex literals work (`"#60a5fa"`) but there's a palette of named constants:

```python
RED    = "#FC6255"
BLUE   = "#58C4DD"
GREEN  = "#83C167"
YELLOW = "#FFFF00"
PURPLE = "#9A72AC"
WHITE  = "#FFFFFF"
BLACK  = "#000000"
# also: TEAL, GOLD, ORANGE, MAROON, GREY, BLUE_A..E etc
```

## 3D scenes

```python
class Cube3D(ThreeDScene):
    def construct(self):
        cube = Cube(color=BLUE, fill_opacity=0.5)
        self.set_camera_orientation(phi=70*DEGREES, theta=45*DEGREES)
        self.play(Create(cube))
        self.begin_ambient_camera_rotation(rate=0.3)
        self.wait(3)
```

## Graphs & plots

```python
class FunctionPlot(Scene):
    def construct(self):
        axes = Axes(x_range=[-3, 3], y_range=[-1, 9],
                    x_length=8, y_length=5,
                    axis_config={"color": GREY})
        graph = axes.plot(lambda x: x**2, color=BLUE)
        label = axes.get_graph_label(graph, label=r"x^2")
        self.play(Create(axes), Create(graph), Write(label))
```

## iOS notes

- Output MP4s land in your Workspace folder — tap the preview button to watch, Share button to save to Photos.
- Render speed depends on `-qm` quality flag (medium is the default). For iteration, use `-ql` (low).
- LaTeX equations (`Tex`, `MathTex`) go through the bundled `pdftex` / `kpathsea` framework — works entirely offline.
- Some rarely-used features require external tools (OpenGL rendering, LaTeX packages beyond amsmath); everything in the starter template renders cleanly.
