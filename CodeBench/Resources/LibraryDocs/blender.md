---
name: bpy
import: bpy
version: 5.3.0
category: 3D
tags: blender, bpy, cycles, render, 3d, metal, gpu, denoise
bundled: true
---

# Blender (bpy)

**The full Blender module, `import bpy`, running natively on iOS arm64.** Build
scenes, run modifiers and physics, and **render with Cycles on the Apple GPU
(Metal) with OpenImageDenoise** — all on-device, no network. First public iOS
build of Blender's `bpy`.

## The headline: save a `.blend`, get a live 3D preview

In CodeBench you don't write any preview code. **Whenever your script saves a
`.blend`, an interactive WebGL 3D viewer opens in the preview pane** — drag to
orbit, pinch to zoom, two-finger drag to pan, and tap **Rendered** to flip to
the photoreal Cycles image.

```python
import bpy, math

# fresh scene  (headless: use bpy.data, not bpy.context.scene)
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
scene = bpy.data.scenes[0]

# a subdivided monkey + a torus, each with a colour
def mat(name, rgba):
    m = bpy.data.materials.new(name); m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgba
    return m

bpy.ops.mesh.primitive_monkey_add(location=(-1.5, 0, 0.6))
mon = bpy.context.active_object                  # NOT bpy.data.objects[-1]
mon.data.materials.append(mat("violet", (0.55, 0.32, 0.95, 1)))
mon.modifiers.new("s", "SUBSURF").levels = 2

bpy.ops.mesh.primitive_torus_add(location=(1.4, 0, 0.6))
bpy.context.active_object.data.materials.append(mat("orange", (0.96, 0.55, 0.18, 1)))

bpy.ops.wm.save_as_mainfile(filepath="scene.blend")   # ← preview opens here
```

## GPU render with OpenImageDenoise

```python
scene.render.engine = "CYCLES"

# turn on the Metal GPU
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "METAL"
(prefs.refresh_devices if hasattr(prefs, "refresh_devices") else prefs.get_devices)()
for d in prefs.devices: d.use = True
prefs.metalrt = "OFF"                     # iOS: skip the hardware-RT path
prefs.kernel_optimization_level = "OFF"   # iOS: skip the slow specialized kernel compile
scene.cycles.device = "GPU"

scene.cycles.samples = 24
scene.cycles.use_denoising = True
scene.cycles.denoiser = "OPENIMAGEDENOISE"        # AI denoise → clean at low samples
scene.render.resolution_x, scene.render.resolution_y = 480, 360
scene.render.filepath = "render.png"              # /tmp is read-only on iOS; use a relative path or ~/Documents
bpy.ops.render.render(write_still=True)
```

**First GPU render of a session compiles Metal kernels (~3 min, serial), then
caches — later renders run in ~2–3 s.** Keep `metalrt`/`kernel_optimization_level`
off as above. **CPU** (`scene.cycles.device = "CPU"`) skips the compile entirely
and is a good default for quick stills.

You don't have to write any preview code: saving a `.blend` **or** running a
render shows a **tqdm progress bar** and then opens the **interactive 3D viewer**
(drag to orbit · pinch to zoom · tap **Rendered** for the photoreal Cycles image)
automatically.

## What's available

Cycles (SVM, CPU + Metal GPU), OpenImageDenoise, Embree, OpenSubdiv, OpenVDB,
Alembic, Bullet physics, Mantaflow fluid, FFTW ocean, exact boolean
(manifold + GMP), Freestyle, OpenColorIO, OBJ / PLY / STL / glTF I/O, geometry
nodes, **FFmpeg video output** (H.264 / MPEG-4 / FFV1 — see below), and the full
modifier stack.

**Not available:** Cycles OSL (needs a JIT, forbidden on iOS) and USD. Check any
feature with `bpy.app.build_options.<name>` — e.g.
`bpy.app.build_options.cycles`. (OIDN is the exception: use
`import _cycles; _cycles.with_openimagedenoise`.)

## Render to video (FFmpeg)

Animate, then render straight to a movie file. **Set `media_type = 'VIDEO'` before
`file_format = 'FFMPEG'`** — only then does the format enum expose movie codecs.

```python
scene.render.image_settings.media_type = "VIDEO"   # ← must come first
scene.render.image_settings.file_format = "FFMPEG"
scene.render.ffmpeg.format = "MPEG4"                # .mp4 container
scene.render.ffmpeg.codec  = "H264"                 # H264 · MPEG4 · FFV1 (lossless, use MKV)
scene.render.filepath = "anim"                      # ~/Documents, NOT /tmp
scene.frame_start, scene.frame_end = 1, 48
bpy.ops.render.render(animation=True)               # → anim0001-0048.mp4
```

H.264/H.265 use Apple's hardware **VideoToolbox** encoder; `FFV1` is lossless;
encoding runs single-threaded on iOS for stability; audio isn't muxed yet
(video-only). The `.mp4` opens in the preview pane / Files.

## Gotchas on iOS

- **`bpy.context.scene` / `.active_object` can be `None`** here (and always
  inside handlers). Use `bpy.data.scenes[0]` and `bpy.data.objects`.
- **After a primitive-add op, grab the new object with `bpy.context.active_object`**,
  never `bpy.data.objects[-1]` — that list is ordered by *name*, so it returns
  the wrong object once the scene fills up.
- **glTF:** export with `export_draco_mesh_compression_enable=False` (draco is
  statically linked, not a separate library on iOS).

## Sanity check

Run this — if it prints the Metal device, bpy + the GPU are live:

```python
import bpy, _cycles
print("Blender", bpy.app.version_string)
print("OIDN:", _cycles.with_openimagedenoise)
print("Metal devices:", [d[0] for d in _cycles.available_devices("METAL") if d[1] == "METAL"])
```
