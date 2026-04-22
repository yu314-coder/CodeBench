---
name: cairo (pycairo)
import: cairo
version: 1.26+
category: Images & Graphics
tags: vector, 2d, svg, pdf, drawing
bundled: true
---

# pycairo

**2D vector graphics.** The Cairo library you already know from GTK — surfaces, contexts, paths, gradients, text, PNG/SVG/PDF output. Bundled with a full freetype + harfbuzz stack.

## Hello, cairo

```python
import cairo

W, H = 400, 200
surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)
ctx = cairo.Context(surface)

# Background
ctx.set_source_rgb(1, 1, 1)
ctx.paint()

# Filled blue rectangle
ctx.set_source_rgb(0.35, 0.55, 1)
ctx.rectangle(20, 20, W-40, H-40)
ctx.fill()

# Black-outlined rectangle
ctx.set_source_rgb(0, 0, 0)
ctx.set_line_width(4)
ctx.rectangle(20, 20, W-40, H-40)
ctx.stroke()

# Text
ctx.set_source_rgb(1, 1, 1)
ctx.select_font_face("Helvetica", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
ctx.set_font_size(32)
ctx.move_to(60, 120)
ctx.show_text("Hello, pycairo!")

surface.write_to_png("/tmp/hello.png")
```

## SVG output

```python
surface = cairo.SVGSurface("/tmp/out.svg", W, H)
ctx = cairo.Context(surface)
# ... draw ...
surface.finish()
```

## PDF output

```python
surface = cairo.PDFSurface("/tmp/doc.pdf", W, H)
ctx = cairo.Context(surface)
# ... draw ...
surface.finish()
```

## Gradients

```python
g = cairo.LinearGradient(0, 0, W, 0)
g.add_color_stop_rgb(0, 1, 0, 0)
g.add_color_stop_rgb(1, 0, 0, 1)
ctx.set_source(g)
ctx.rectangle(0, 0, W, H); ctx.fill()

# Radial
g = cairo.RadialGradient(W/2, H/2, 10, W/2, H/2, W/2)
g.add_color_stop_rgba(0, 1, 1, 0.5, 1)
g.add_color_stop_rgba(1, 0.1, 0.1, 0.3, 1)
```

## Paths

```python
ctx.new_path()
ctx.move_to(50, 180)
ctx.curve_to(150, 20, 250, 20, 350, 180)
ctx.set_source_rgb(0.2, 0.7, 0.3)
ctx.set_line_width(6)
ctx.stroke()
```

## Convert to PIL Image

```python
from PIL import Image

# ARGB32 surface → PIL RGBA
buf = surface.get_data()
img = Image.frombuffer("RGBA", (W, H), bytes(buf), "raw", "BGRA", 0, 1)
img.save("/tmp/out_rgba.png")
```

## iOS notes

- All of pycairo's surfaces work (Image, SVG, PDF). Recording surfaces too.
- Fonts come from the bundled **FreeType** + **HarfBuzz** stack. `ctx.select_font_face("Helvetica")` finds built-in iOS fonts; bundled custom TTFs also work via `cairo.FontFace.create_from_file()`.
- Used by **manim** under the hood for rasterising 2D mobjects.
