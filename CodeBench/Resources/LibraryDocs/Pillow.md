---
name: Pillow
import: PIL
version: 11.0.0
category: Images & Graphics
tags: image, png, jpeg, drawing, font
bundled: true
---

# Pillow (PIL)

**Friendly fork of the Python Imaging Library.** Full build for iOS arm64 — the five native `.so` extensions (`_imaging`, `_imagingft`, `_imagingmath`, `_imagingmorph`, `_imagingtk`) are cross-compiled and shipped in the app. JPEG and zlib come from the SDK; FreeType is bundled for text rendering.

## What works on iOS

| Feature | Status | Notes |
|---|---|---|
| PNG encode/decode | ✅ | via bundled zlib |
| JPEG encode/decode | ✅ | via bundled libjpeg-turbo |
| FreeType text  | ✅ | TTF/OTF rendering w/ `ImageFont.truetype` |
| Drawing (`ImageDraw`) | ✅ | all primitives |
| Filters (blur, sharpen, …) | ✅ | |
| TIFF / WebP / LCMS / JP2K | ❌ | not bundled to keep binary small |
| X11 screen grab (XCB) | ❌ | not meaningful on iOS |

## Quick start

```python
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# Create an image, draw on it
img = Image.new("RGB", (400, 200), "white")
d = ImageDraw.Draw(img)
d.rectangle((10, 10, 390, 190), outline="black", width=3)
d.text((20, 20), "Hello from Pillow!", fill="black")
img.save("/tmp/hello.png")

# Open + filter
src = Image.open("/tmp/hello.png")
blurred = src.filter(ImageFilter.GaussianBlur(3))
blurred.save("/tmp/blurred.png")

# Resize, crop, rotate — all lossless in-memory
thumb = src.resize((100, 50), Image.LANCZOS)
crop = src.crop((10, 10, 200, 100))
rot = src.rotate(15, expand=True)
```

## Reading images from the app sandbox

```python
import os
docs = os.path.expanduser("~/Documents")
img = Image.open(os.path.join(docs, "photo.jpg"))
print(img.size, img.mode)       # (W, H), "RGB"
img.thumbnail((200, 200))       # in-place resize, keeps aspect
img.save(os.path.join(docs, "photo_thumb.jpg"), "JPEG", quality=85)
```

## Common recipes

### Apply a filter chain
```python
from PIL import ImageFilter, ImageEnhance
img = Image.open("in.jpg")
img = img.filter(ImageFilter.UnsharpMask(radius=2, percent=150))
img = ImageEnhance.Contrast(img).enhance(1.3)
img = ImageEnhance.Color(img).enhance(1.2)
img.save("out.jpg", quality=92)
```

### Convert between modes
```python
rgba = Image.open("icon.png").convert("RGBA")
rgb = rgba.convert("RGB")          # drops alpha (useful for JPEG output)
gray = rgba.convert("L")           # 8-bit greyscale
```

### Draw a chart (combine with numpy)
```python
import numpy as np
from PIL import Image, ImageDraw
W, H = 400, 200
img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)
xs = np.linspace(0, 2*np.pi, W)
ys = (H/2) + 50 * np.sin(xs)
pts = list(zip(range(W), ys.astype(int)))
d.line(pts, fill="blue", width=2)
img.save("/tmp/sin.png")
```

## Useful modules

- **`PIL.Image`** — load / save / resize / rotate / crop / paste / composite
- **`PIL.ImageDraw`** — lines, rectangles, polygons, text, arcs
- **`PIL.ImageFilter`** — Gaussian blur, UnsharpMask, MedianFilter, edge detection
- **`PIL.ImageFont`** — load TTF/OTF fonts (include a .ttf in your Documents)
- **`PIL.ImageEnhance`** — brightness, contrast, sharpness, color
- **`PIL.ImageChops`** — arithmetic/logic between images
- **`PIL.ImageOps`** — autocontrast, invert, mirror, pad, fit

## Gotchas

- **JPEG with alpha** — JPEG has no alpha channel. Convert to RGB first or use PNG.
- **Memory** — huge images (>100 MP) can OOM the iOS process. Use `Image.thumbnail()` early.
- **Font file path** — `ImageFont.truetype("Helvetica.ttc", 24)` won't find system fonts on iOS. Bundle a TTF in your Workspace or extract one from `Frameworks/…`.
