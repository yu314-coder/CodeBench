# CodeBench

A self-contained developer / scientific / AI workstation for iPad and Mac. Python 3.14, C, C++, Fortran, pdflatex, and local LLMs — all running on-device, no internet required.

```
  iPad / iPadOS / Mac Catalyst
  ┌──────────────────────────────────────────────────────┐
  │                                                      │
  │   Monaco editor ──── IntelliSense + signature help   │
  │         │                                            │
  │         ▼                                            │
  │   Python / C / C++ / Fortran / pdflatex              │
  │         │                                            │
  │         ▼                                            │
  │   SwiftTerm terminal ◄──► PTY ◄──► CPython REPL      │
  │         │                                            │
  │         ▼                                            │
  │   Local LLM chat + RAG + image gen                   │
  │                                                      │
  └──────────────────────────────────────────────────────┘
```

Built on **[python-ios-lib](https://github.com/yu314-coder/python-ios-lib)** — the Python 3.14 runtime + 30+ native iOS Python libraries project. Every library listed below has its own reference documentation in that repo; links go directly to each library's main doc.

---

## What CodeBench adds

| Capability | How |
|---|---|
| **Monaco code editor** (real VS-Code editor) | WKWebView-hosted, Python IntelliSense, ~70-entry signature DB, hover docs, auto-resolve from Python daemon for numpy / scipy / sklearn / matplotlib / sympy |
| **Integrated terminal** | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) backed by a PTY master/slave pair piping into the embedded CPython REPL |
| **pdflatex on-device** | [busytex](https://github.com/busytex/busytex) WASM (pdftex 1.40.25 + xetex + luatex + bibtex8 + xdvipdfmx) running in a hidden WKWebView with TeX Live 2023 packages preloaded into MEMFS. A custom 23 MB overlay adds pgf / tikz / beamer / hyperref / mathtools / microtype / cleveref / fancyhdr / bbm / CJKutf8 / fontspec / ctex and ls-R index |
| **Local LLM chat** | [llama.cpp](https://github.com/ggerganov/llama.cpp) for GGUF models + ExecuTorch for Apple-Core-ML backends. Chat UI with streaming, conversation export |
| **RAG engine** | In-process vector store for RAG over user-imported docs |
| **Image generation** | Offline image models via ExecuTorch |
| **File browser + tabs** | iOS document browser with multiple concurrent workspaces |
| **Auto-save** | Debounced ~600 ms after keystroke, plus on run / tab-switch / view-disappear / app-backgrounding |
| **Tombstone system** | Files deleted via UI are recorded in `<Workspace>/.offlinai_deleted` so starter-script seeders don't resurrect them on next launch |

---

## Languages

| Language | Runtime | Main doc |
|---|---|---|
| **Python 3.14** | BeeWare-embedded CPython | [python-ios-lib README](https://github.com/yu314-coder/python-ios-lib#readme) |
| **C** | Pure-Swift tree-walking interpreter (3.4k LOC, 48 operators, structs, pointers, preprocessor) | [c-interpreter.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/c-interpreter.md) · [interpreters.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/interpreters.md) |
| **C++** | Pure-Swift tree-walking interpreter (4.2k LOC, classes, STL, templates, inheritance) | [cpp-interpreter.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/cpp-interpreter.md) · [interpreters.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/interpreters.md) |
| **Fortran** | Pure-Swift tree-walking interpreter (4.1k LOC, modules, allocatable arrays, intrinsics) | [fortran-interpreter.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/fortran-interpreter.md) · [fortran-runtime.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/fortran-runtime.md) |

All four languages share the same Monaco editor + IntelliSense pipeline and auto-save.

---

## Python libraries — direct links to each library's doc

Every library below is bundled natively on-device. Click the library name to jump to its reference doc in **python-ios-lib**.

### Scientific computing

| Library | Type | Doc |
|---|---|---|
| **NumPy 2.3.5** | Native iOS (arm64) | [docs/libs/numpy.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/numpy.md) · [docs/numpy.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/numpy.md) |
| **SciPy 1.15.0** | Pure Python shim | [docs/libs/scipy.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/scipy.md) · [docs/scipy-ios.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/scipy-ios.md) |
| **SymPy 1.14.0** | Pure Python | [docs/sympy.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/sympy.md) · [docs/libs/sympy.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/sympy.md) |
| **mpmath 1.4.1** | Pure Python | [docs/mpmath.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/mpmath.md) |

### Machine learning

| Library | Type | Doc |
|---|---|---|
| **PyTorch 2.1.0** (patched) | Native iOS (arm64) — full `import torch`, tensors, autograd, nn, optim, JIT, FFT, distributions. Accelerate-backed linalg | [docs/libs/pytorch.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/pytorch.md) |
| **transformers 4.41.2** | Pure Python — HuggingFace BERT / GPT-2 / T5 / BART, train + generate on-device | [docs/libs/transformers.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/transformers.md) |
| **tokenizers 0.19.1** | Native iOS (Rust) — first public iOS build, real BPE/WordPiece/Unigram trainers, PyO3 bindings | [docs/libs/tokenizers.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/tokenizers.md) |
| **scikit-learn** | Pure NumPy (12k+ LOC, 40 modules, 38 metrics) | [docs/sklearn.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/sklearn.md) · [docs/libs/sklearn.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/sklearn.md) |

### Visualization & media

| Library | Type | Doc |
|---|---|---|
| **matplotlib** | Native iOS | [docs/matplotlib.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/matplotlib.md) · [docs/libs/matplotlib.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/matplotlib.md) |
| **manim** | Pure Python | [docs/manim.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/manim.md) · [docs/libs/manim.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/manim.md) |
| **Pillow** | Native iOS (libjpeg-turbo + zlib) | [docs/pillow.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/pillow.md) |
| **PyAV / FFmpeg** | Native iOS (libavcodec, libavformat, libavfilter, …) | [docs/av-pyav.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/av-pyav.md) · [docs/libs/media.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/media.md) |
| **plotly** | Pure Python | [docs/plotly.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/plotly.md) |
| **svgelements** | Pure Python | [docs/svgelements.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/svgelements.md) |
| **pydub** | Pure Python (ffmpeg-backed) | [docs/pydub.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/pydub.md) |

### Utilities

| Library | Type | Doc |
|---|---|---|
| **networkx** | Pure Python | [docs/networkx.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/networkx.md) |
| **beautifulsoup4** | Pure Python | [docs/beautifulsoup.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/beautifulsoup.md) |
| **click** | Pure Python | [docs/click.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/click.md) |
| **jsonschema** | Pure Python | [docs/jsonschema.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/jsonschema.md) |
| **PyYAML** | Pure Python | [docs/pyyaml.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/pyyaml.md) |
| **pygments** | Pure Python | [docs/pygments.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/pygments.md) |
| **rich** | Pure Python | [docs/rich.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/rich.md) |
| **tqdm** | Pure Python | [docs/tqdm.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/tqdm.md) |
| **Minor libs** (requests, dateutil, psutil, watchdog, screeninfo, soupsieve, safetensors, regex, typing_extensions, …) | Mixed | [docs/minor-libs.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/minor-libs.md) |

Full top-level reference: **[python-ios-lib/docs/README.md](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/README.md)**.

---

## LaTeX (`pdflatex`)

CodeBench's `pdflatex` / `latex` / `tex` shell commands route to **[busytex](https://github.com/busytex/busytex)** WASM running in a hidden WKWebView. The TeX Live 2023 data packages (texlive-basic + ubuntu-texlive-{latex-base, latex-recommended, fonts-recommended, latex-extra, science}, ~230 MB compressed) preload into MEMFS on first run. A 23 MB overlay data package bundles extra packages pdflatex commonly needs:

- PGF / TikZ / beamer + themes + translator
- hyperref + dependencies (kvsetkeys, pdfescape, hycolor, …)
- mathtools, microtype, cleveref, fancyhdr, geometry, setspace, bbm (+ bbm-macros)
- CJK + CJKutf8 (CJK family)
- amscls / amsthm / mathrsfs / booktabs / float / enumitem
- A kpathsea `ls-R` index so lookups are O(1)

On top of the pipeline, the Swift-side `BusytexEngine` adds:
- **Sibling-file collection**: scans `\includegraphics`, `\includepdf`, `\input`, `\include`, `\bibliography` references, bundles real files + synthesizes 1×1 placeholder PNG/PDF for missing ones so compiles don't abort on a missing figure.
- **Unicode sanitizer**: replaces codepoints pdflatex can't render (CJK, symbols past U+0200) with `[?]` so stray Unicode doesn't fatal-error mid-compile.
- **Auto-lmodern injection**: when the doc uses `\usepackage[T1]{fontenc}` without a T1-capable font family, auto-adds `\usepackage{lmodern}` so pdftex doesn't try to spawn `mktexpk` (which needs `fork()`, unavailable in WASM).
- **Live progress streaming**: every pdftex stdout line streams to the terminal as it compiles, plus a Swift-side 3 s heartbeat so you know the engine is alive during long runs.

Full pdflatex doc: **[media.md#offlinai_latex--local-latex-engine](https://github.com/yu314-coder/python-ios-lib/blob/main/docs/libs/media.md#offlinai_latex--local-latex-engine)**.

---

## Local AI

- **GGUF models** via `llama.cpp` integrated as an XCFramework. Load any Llama / Mistral / Qwen / Phi model, chat with streaming tokens.
- **ExecuTorch** backends for Apple-Core-ML / XNNPACK / kernel-optimized inference of PyTorch models.
- **RAG**: in-process sentence-embedding + vector store over user-imported text / PDF / markdown.
- **Image generation** via ExecuTorch-runnable diffusion-family models.

All models live in the app sandbox; no tokens leave the device.

---

## Shell

The CodeBench shell IS a Python REPL — typing Python executes directly. On top of it there are builtins for POSIX-y operations iOS doesn't give you:

- File/system: `ls`, `cd`, `pwd`, `mkdir`, `rm`, `cp`, `mv`, `cat`, `head`, `tail`, `grep`, `find`, `file`, `touch`, `df`, `du`, `ncdu`, `top`
- Languages: `python` / `python3` (with `-V` / `-c` / `-m` / full flag handling), `cc` / `gcc` / `clang`, `c++` / `g++` / `clang++`, `gfortran` / `f77` / `f90` / `f95`
- LaTeX: `pdflatex`, `latex`, `tex`, `pdftex`, `latex-diagnose`
- VCS: `git clone` (via zipball fetch — real Git protocol isn't available sandboxed)
- Package mgmt: `pip` (install to the per-workspace site-packages dir)

`python --help`, `python -V`, `python -c "print(1+1)"`, `python -m pip install …` all behave like real CPython.

---

## Install / build

This repo contains the CodeBench-specific pieces (Swift source, Xcode project, resources, busytex data packages via LFS, build scripts). It expects **[python-ios-lib](https://github.com/yu314-coder/python-ios-lib)** to provide the runtime layer (Python.xcframework, llama.xcframework, ExecuTorch frameworks, app_packages, Monaco folder, SwiftTerm SPM). Both repos get laid out into a single workspace.

### 1. Clone python-ios-lib (the runtime)

```bash
git clone https://github.com/yu314-coder/python-ios-lib
cd python-ios-lib
```

This gives you `Frameworks/`, `app_packages/`, `Monaco/`, `Sources/`, `Package.swift`, `docs/`, and the iOS port build dirs (cairo, ffmpeg, harfbuzz, pango, numpy_ios, pillow_ios, …). Installed size: ~1.4 GB.

### 2. Clone CodeBench alongside it

```bash
# Clone into a sibling dir named CodeBench_clone, then move its
# contents into the python-ios-lib workspace root. The Xcode
# project expects Frameworks/, app_packages/, Monaco/, Sources/,
# Package.swift, CodeBench/, CodeBench.xcodeproj/, Info.plist all
# to live at the same level.
git clone https://github.com/yu314-coder/CodeBench CodeBench_clone
mv CodeBench_clone/CodeBench .
mv CodeBench_clone/CodeBench.xcodeproj .
mv CodeBench_clone/Info.plist .
mv CodeBench_clone/scripts/* scripts/ 2>/dev/null || mv CodeBench_clone/scripts .
rm -rf CodeBench_clone
```

Git LFS auto-pulls the busytex data packages (~244 MB) on clone via the configured filters. If your git client skipped them, run `git lfs pull` inside `CodeBench/Resources/Busytex/` before building.

### 3. Clone llama.cpp source (only if rebuilding `llama.xcframework`)

**Skip this step if you're just building the app** — `llama.xcframework` is already prebuilt in `python-ios-lib/Frameworks/`, so the app links against it directly. Only do this if you want to regenerate the xcframework from scratch (e.g. to pull new llama.cpp upstream changes or to bump target iOS version):

```bash
# ~7.6 GB checkout. Only needed to rebuild the xcframework.
mkdir -p third_party
git clone https://github.com/ggerganov/llama.cpp third_party/llama.cpp

# Build llama.xcframework (takes ~30 min on M-series Mac).
# See python-ios-lib/docs for the exact recipe — typically:
#   cd third_party/llama.cpp
#   cmake -B build-ios-arm64 -G Xcode \
#         -DCMAKE_SYSTEM_NAME=iOS \
#         -DCMAKE_OSX_ARCHITECTURES=arm64 \
#         -DLLAMA_METAL_EMBED_LIBRARY=ON \
#         -DLLAMA_BUILD_EXAMPLES=OFF
#   xcodebuild -project build-ios-arm64/llama.cpp.xcodeproj -scheme llama \
#              -configuration Release -sdk iphoneos -arch arm64
# Then xcodebuild -create-xcframework to assemble the device+simulator
# slices, and replace python-ios-lib/Frameworks/llama.xcframework.
```

### 4. Open and build

```bash
# Open the project in Xcode and build for iOS / iPadOS / Mac Catalyst.
open CodeBench.xcodeproj
```

Xcode target: **CodeBench**. Scheme: **CodeBench**. Run on a real device or Designed-for-iPad on macOS.

### Installed-bundle size

The finished `CodeBench.app` is ~1 GB:
- 791 MB `Frameworks/` (Python, llama, ExecuTorch xcframeworks — from python-ios-lib)
- 484 MB `app_packages/` (bundled Python site-packages — from python-ios-lib)
- 254 MB `CodeBench/` (Swift source + Resources, of which ~230 MB is the LaTeX data packages — this repo, via LFS)

### What's in this repo vs python-ios-lib vs upstream

| This repo (CodeBench) | python-ios-lib | Upstream only (re-clone if rebuilding) |
|---|---|---|
| `CodeBench/` — Swift source + Resources | `Frameworks/` — Python, llama, ExecuTorch, LaTeX xcframeworks | `third_party/llama.cpp/` → [`ggerganov/llama.cpp`](https://github.com/ggerganov/llama.cpp) (~7.6 GB) |
| `CodeBench.xcodeproj/` | `app_packages/` — 30+ iOS-ported Python packages |  |
| `Info.plist` | `Monaco/` — Monaco editor WebView bundle |  |
| `scripts/` — fetch/build helpers (busytex assets, ffmpeg path fixup, wheel unpack/test) | `Sources/` + `Package.swift` — SwiftTerm SPM integration |  |
|  | `docs/` — per-library docs linked from this README |  |
|  | iOS port build dirs: `cairo/`, `cpp/`, `ffmpeg/`, `fortran/`, `gcc/`, `harfbuzz/`, `numpy_ios/`, `pandas_ios/`, `pango/`, `pillow_ios/`, `psutil_ios/`, `skia-pathops/` |  |

---

## Acknowledgements

CodeBench stands on:

- **[python-ios-lib](https://github.com/yu314-coder/python-ios-lib)** — the CPython 3.14 runtime and 30+ iOS-ported Python libraries that make the app work
- **[BeeWare](https://beeware.org/)** — the `Python.xcframework` embedding technique
- **[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)** — xterm-compatible terminal emulator
- **[Monaco Editor](https://microsoft.github.io/monaco-editor/)** — VS Code's editor in WKWebView
- **[busytex](https://github.com/busytex/busytex)** — TeX Live 2023 compiled to WASM
- **[llama.cpp](https://github.com/ggerganov/llama.cpp)** / **[ExecuTorch](https://github.com/pytorch/executorch)** — local LLM inference
- **[SwiftMath](https://github.com/mgriebling/SwiftMath)** — native CoreText math rendering for `$…$` inline expressions

---

## License

See [LICENSE](LICENSE). Individual dependencies retain their original licenses — consult each project's repo (linked above).
