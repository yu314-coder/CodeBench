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

## Recent improvements

- **Reliable inline preview for shell-launched python** — `python foo.py` from the integrated terminal now displays the resulting matplotlib/plotly chart in the preview pane the same way the Run button does. Previously flaky for several reasons, all fixed:
  - PTY scanner missed `[plot saved] /…` / `[manim rendered] /…` markers prefixed with ANSI escape codes (CSI clear-line, prompt redraws). The `hasPrefix` check is now preceded by `stripAnsiEscapes` and also handles the `[manim rendered]` marker.
  - `WKWebView.loadFileURL(allowingReadAccessTo:)` flaked on macOS Catalyst — the access grant to the sandboxed `WebContent` process raced the actual load (`WebProcessProxy::hasAssumedReadAccessToURL: no access`). The HTML branch of `showImageOutput` now reads the file (up to 20 MB) and uses `loadHTMLString(html, baseURL: parentDir)`, sidestepping the sandbox grant entirely.
  - A blank-HTML preload meant to drop a previous manim video DOM was causing back-to-back async loads for HTML→HTML transitions; the blank's cancellation (`NSURLErrorCancelled -999`) intermittently propagated into the chart load. Skipped when the next content is also HTML — the new HTML replaces the DOM atomically.
  - The dir-watcher's `DispatchSource.makeFileSystemObjectSource(.write)` fires on inode create (file size 0) but doesn't re-fire on subsequent content writes into an existing entry. Heavy plotly HTML can take 60–80 s to serialize on iOS Python. A new `pollForChartCompletion` polls every 0.5 s for up to 120 s once a too-small file is seen, then routes through `tryShowChart` when `size ≥ 4 KB`.
  - `flush=True` added to the embedded `_offlinai_*_show` print sites so the marker line definitely reaches the PTY.
  - Diagnostic `NSLog` lines added across the chain: filter Xcode console on `[chart-watch]` to trace dir-event → poll → load.

- **Inherited from [python-ios-lib](https://github.com/yu314-coder/python-ios-lib)**: matplotlib shim no longer crashes user scripts on chained attribute access (`ax.xaxis.line.set_color(...)` etc.), and full plotly styling — titles, axis ranges, backgrounds — now applies correctly (was being silently aborted by a `__figure__` sentinel leak). See [python-ios-lib's recent changes](https://github.com/yu314-coder/python-ios-lib#recent-app-side-changes).

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
- **PyTorch → Metal GPU bridge** (`CodeBench/MetalMatmulBridge.swift`) — exposes one `@_cdecl` C entry point backed by `MPSMatrixMultiplication`. Python's `_torch_metal_bridge.py` (in [python-ios-lib](https://github.com/yu314-coder/python-ios-lib)) reaches it via `dlopen(NULL)` + `dlsym` and monkey-patches `torch.matmul` / `mm` / `bmm` / `addmm` / `F.linear` / `F.scaled_dot_product_attention` on every Python startup. Real on-device transformer training in fp32/fp16/bf16 with 2–10× speedup over CPU. Linker flags in `OTHER_LDFLAGS` (`-Wl,-exported_symbol,_cb_metal_*`) keep the symbol export-visible through Apple's archive / TestFlight strip pass.
- **LoRA fine-tuning** via llama.cpp's Metal backward kernels (separate path from the PyTorch bridge) — see `CodeBench/LlamaFinetuner.swift`. Trains a LoRA adapter on a GGUF base model in-place.
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

This repo contains the CodeBench-specific pieces (Swift source, Xcode project, resources, busytex data packages via LFS, build scripts). It depends on **[python-ios-lib](https://github.com/yu314-coder/python-ios-lib)** for the runtime layer (Python.xcframework, llama.xcframework, ExecuTorch frameworks, app_packages, Monaco folder, SwiftTerm SPM).

### Quickstart (recommended)

```bash
git clone https://github.com/yu314-coder/CodeBench
cd CodeBench
./scripts/setup.sh        # clones python-ios-lib + symlinks it in
open CodeBench.xcodeproj
```

`setup.sh` clones python-ios-lib into `_vendor/python-ios-lib/` and creates symlinks at the workspace root (`Frameworks/`, `app_packages/`, `Monaco/`, `Sources/`, `Package.swift`) pointing into the vendored runtime. Both repos keep independent `.git` histories — pulling updates on either side is just `git pull` in the corresponding directory. Re-run `./scripts/setup.sh --update` to also fast-forward the runtime.

Git LFS auto-pulls the busytex data packages (~244 MB) on clone via the configured filters. If your git client skipped them, run `git lfs pull` inside `CodeBench/Resources/Busytex/` before building.

### Manual layout (if you can't use symlinks)

Some setups (Windows-with-WSL, sandboxed CI) don't follow symlinks well. In that case, lay the two repos out side-by-side as one merged workspace:

```bash
git clone https://github.com/yu314-coder/python-ios-lib
cd python-ios-lib
git clone https://github.com/yu314-coder/CodeBench _codebench
cp -R _codebench/CodeBench _codebench/CodeBench.xcodeproj _codebench/Info.plist .
cp -R _codebench/scripts/* scripts/ 2>/dev/null || true
```

Either way, Xcode opens `CodeBench.xcodeproj` and finds `Frameworks/`, `app_packages/`, `Monaco/`, `Sources/`, and `Package.swift` at the workspace root.

### Build target

Xcode scheme: **CodeBench**. Run on a real device, on TestFlight, or via **My Mac (Designed for iPad)**. The first build takes a few minutes; subsequent builds are incremental.

### Rebuilding `llama.xcframework` (optional, advanced)

`llama.xcframework` is prebuilt and shipped in python-ios-lib/Frameworks/, so the app links against it directly. Only rebuild from llama.cpp source if you need a different upstream version or build flags:

```bash
mkdir -p third_party
git clone https://github.com/ggerganov/llama.cpp third_party/llama.cpp
# Then run python-ios-lib/build-xcframework.sh + finish-ios-only.sh
# and replace python-ios-lib/Frameworks/llama.xcframework with the result.
```

### Installed-bundle size

The finished `CodeBench.app` is ~1 GB:
- 791 MB `Frameworks/` (Python, llama, ExecuTorch xcframeworks — from python-ios-lib)
- 484 MB `app_packages/` (bundled Python site-packages — from python-ios-lib)
- 254 MB `CodeBench/` (Swift source + Resources, of which ~230 MB is the LaTeX data packages — this repo, via LFS)

### What's in this repo vs python-ios-lib vs upstream

Verified against `gh api /repos/yu314-coder/{repo}/contents/` as of this commit.

| This repo ([CodeBench](https://github.com/yu314-coder/CodeBench)) | [python-ios-lib](https://github.com/yu314-coder/python-ios-lib) | Upstream only — re-clone if rebuilding |
|---|---|---|
| `CodeBench/` — Swift source + Resources (busytex data via LFS) | `Frameworks/` — Python / llama / ExecuTorch / LaTeX xcframeworks | `third_party/llama.cpp/` → [`ggerganov/llama.cpp`](https://github.com/ggerganov/llama.cpp) (~7.6 GB, only needed if rebuilding `llama.xcframework`) |
| `CodeBench.xcodeproj/` | `app_packages/` — bundled Python site-packages |  |
| `Info.plist` | `Monaco/` — Monaco editor WebView bundle |  |
| `scripts/` — CodeBench-specific build helpers: | `Sources/` + `Package.swift` — SwiftTerm SPM integration |  |
| &nbsp;&nbsp;• `fetch_busytex_assets.sh` (LFS-fallback downloader) | `docs/` — per-library reference docs (linked from this README) |  |
| &nbsp;&nbsp;• `fetch_ios_wheels.py`, `unpack_wheels.sh`, `check_wheels.py` | `fix_ffmpeg_paths.sh` — install_name_tool rewrite for av.*.framework |  |
| &nbsp;&nbsp;• `fix_ffmpeg_paths.sh` (mirror) | C-lib build dirs: `cairo/`, `cpp/`, `ffmpeg/`, `fortran/`, `gcc/`, `harfbuzz/`, `pango/`, `skia-pathops/` |  |
| &nbsp;&nbsp;• `test_all_libs.py` (smoke test for all 30+ libs) | Python-pkg build dirs: `numpy_ios/`, `pandas_ios/`, `pillow_ios/`, `psutil_ios/`, `audioop/`, `av/`, `matplotlib/`, `scipy/`, `sklearn/`, `manimpango/`, `mapbox_earcut/` |  |

**Files / dirs not in either repo** (local-only build scratch, never checked in): `third_party/`, `DerivedData/`, `build/`, `.venv/`, `xcuserdata/`. Generated on-demand by the build scripts in python-ios-lib.

**Monaco editor**: lives in **python-ios-lib** (14 MB — `Monaco/` top-level folder reference). CodeBench's `CodeBench.xcodeproj` references it at the workspace root, so after you complete the step-2 clone recipe above, the Xcode project finds it.

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
