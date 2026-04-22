---
name: av (PyAV)
import: av
version: 11.x
category: Media
tags: video, audio, ffmpeg, codec, decode, encode
bundled: true
---

# PyAV

**Pythonic bindings for FFmpeg.** Decode, encode, transcode audio and video — manim uses this to write its MP4s, but you can use it directly for any AV processing.

## Open and probe a media file

```python
import av

ctr = av.open("/path/to/video.mp4")
print(ctr.duration / av.time_base, "seconds")
for s in ctr.streams:
    print(s.type, s.name, s.codec_context.framerate, s.width, s.height)

video = ctr.streams.video[0]
print(video.codec_context.pix_fmt, video.codec_context.bit_rate)
```

## Decode frames

```python
with av.open("/path/to/video.mp4") as ctr:
    for frame in ctr.decode(video=0):
        img = frame.to_image()    # PIL.Image
        if frame.index == 0:
            img.save("/tmp/first_frame.jpg")
```

## Extract audio to WAV

```python
import av, numpy as np, wave

src = "/path/to/clip.mov"
with av.open(src) as cin:
    a = cin.streams.audio[0]
    samples = []
    for frame in cin.decode(a):
        samples.append(frame.to_ndarray().astype(np.int16))

pcm = np.concatenate(samples, axis=1).T  # (n_samples, channels)
with wave.open("/tmp/clip.wav", "wb") as w:
    w.setnchannels(pcm.shape[1])
    w.setsampwidth(2)
    w.setframerate(a.codec_context.sample_rate)
    w.writeframes(pcm.tobytes())
```

## Write a video from PIL images

```python
import av
from PIL import Image, ImageDraw
import numpy as np

W, H = 320, 240
out = av.open("/tmp/gen.mp4", "w")
stream = out.add_stream("h264_videotoolbox", rate=30)   # Apple hardware encoder
stream.width, stream.height = W, H
stream.pix_fmt = "yuv420p"

for i in range(60):
    img = Image.new("RGB", (W, H), "black")
    d = ImageDraw.Draw(img)
    d.ellipse((i*4, i*3, i*4+60, i*3+60), fill="red")
    frame = av.VideoFrame.from_ndarray(np.array(img), format="rgb24")
    for packet in stream.encode(frame):
        out.mux(packet)

for packet in stream.encode():  # flush
    out.mux(packet)
out.close()
```

## Transcode in one pass

```python
import av

with av.open("in.mov") as cin, av.open("out.mp4", "w") as cout:
    istream = cin.streams.video[0]
    ostream = cout.add_stream("h264_videotoolbox", rate=istream.codec_context.framerate)
    ostream.width, ostream.height = istream.width, istream.height
    ostream.pix_fmt = "yuv420p"

    for frame in cin.decode(istream):
        for packet in ostream.encode(frame):
            cout.mux(packet)
    for packet in ostream.encode():
        cout.mux(packet)
```

## iOS codec notes

- **h264_videotoolbox** (hardware H.264 encoder) works beautifully — used for all manim output
- **hevc_videotoolbox** (HEVC/H.265) also available
- Software codecs (libx264, libx265, libaom-av1) are NOT bundled to keep the binary slim
- Audio: `aac`, `aac_at` (AudioToolbox), `pcm_s16le`, `opus` all work

## Relationship to FFmpeg

PyAV bundles pre-built FFmpeg dylibs. You don't get a shell `ffmpeg` command — use the PyAV Python API.
