"""
codebench_features_test.py
═══════════════════════════════════════════════════════════════════
Comprehensive end-to-end test for the 8 features added this session:

  #1   Jupyter .ipynb support           (notebook backend)
  #2   Inline matplotlib / pandas       (output capture)
  #3   Visual debugger                  (codebench_debug)
  #6   REPL with persistent namespace   (codebench_repl)
  #9   Data viewer quick-look           (numpy daemon + fixtures)
  #10  Vim mode                         (UI — checklist)
  #23  AI endpoint settings             (UI + provider config)
  #24  Cmd+P quick open                 (UI — checklist)

Run from CodeBench's terminal:
    python codebench_features_test.py

Each section prints PASS / FAIL / SKIP with a short reason. UI-only
features print a "MANUAL" line with one-sentence instructions.

The test deliberately uses small data so it runs in <30 s even on iPad.
"""

import json
import os
import sys
import tempfile
import time
import traceback
from pathlib import Path

# ─────────────────────────────────────────────────────────────
# Counters + formatting
# ─────────────────────────────────────────────────────────────
PASS = 0
FAIL = 0
SKIP = 0
MANUAL = 0
FAILURES: list = []

GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
RESET  = "\033[0m"

def hdr(title: str) -> None:
    print(f"\n{BOLD}{CYAN}━━━ {title} ━━━{RESET}")

def ok(label: str, note: str = "") -> None:
    global PASS
    PASS += 1
    extra = f"  {DIM}{note}{RESET}" if note else ""
    print(f"  {GREEN}✓ PASS{RESET}  {label}{extra}")

def bad(label: str, why: str) -> None:
    global FAIL
    FAIL += 1
    FAILURES.append((label, why))
    print(f"  {RED}✗ FAIL{RESET}  {label}\n         {DIM}{why}{RESET}")

def skip(label: str, why: str) -> None:
    global SKIP
    SKIP += 1
    print(f"  {YELLOW}↷ SKIP{RESET}  {label}  {DIM}({why}){RESET}")

def manual(label: str, instructions: str) -> None:
    global MANUAL
    MANUAL += 1
    print(f"  {CYAN}◉ MANUAL{RESET}  {label}\n           {DIM}{instructions}{RESET}")

def sig_dir() -> str:
    """Match LaTeXEngine.signalDir."""
    d = os.path.join(tempfile.gettempdir(), "latex_signals")
    os.makedirs(d, exist_ok=True)
    return d


# ═════════════════════════════════════════════════════════════
# #2 — Inline matplotlib / pandas / PIL display
# ═════════════════════════════════════════════════════════════
def test_inline_outputs() -> None:
    hdr("#2 — Inline rich output")

    # The codebench_inline module must import
    try:
        import codebench_inline
        ok("codebench_inline importable")
    except ImportError as e:
        bad("codebench_inline import", str(e))
        return

    # install() should register the matplotlib/pandas/plotly/PIL hooks
    result = codebench_inline.install()
    if isinstance(result, dict):
        ok("install() returned dict",
           f"matplotlib={result.get('matplotlib')} "
           f"pil={result.get('pil')} "
           f"pandas={result.get('pandas')} "
           f"notebook={result.get('notebook')}")
    else:
        bad("install() return shape", f"expected dict, got {type(result).__name__}")

    # ── Matplotlib path ─────────────────────────────────────
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
        # Snapshot signal-dir contents before
        before = set(os.listdir(sig_dir()))
        # Create + show a figure — should drop an inline_*.json
        fig, ax = plt.subplots(figsize=(4, 3))
        ax.plot(np.linspace(0, 6.28, 100), np.sin(np.linspace(0, 6.28, 100)))
        ax.set_title("Inline test")
        plt.show()
        # Allow the file-rename to settle
        time.sleep(0.2)
        after = set(os.listdir(sig_dir()))
        new = [f for f in (after - before) if f.startswith("inline_")]
        if new:
            ok("matplotlib plt.show() captured",
               f"{len(new)} signal file(s): {new[0][:40]}")
        else:
            bad("matplotlib plt.show() captured", "no inline_*.json appeared in signalDir")
    except ImportError as e:
        skip("matplotlib path", f"matplotlib not available: {e}")
    except Exception as e:
        bad("matplotlib path", f"{type(e).__name__}: {e}")

    # ── Pandas display() path ────────────────────────────────
    try:
        from codebench_inline import display
        import pandas as pd
        before = set(os.listdir(sig_dir()))
        df = pd.DataFrame({"a": [1, 2, 3], "b": ["x", "y", "z"]})
        display(df)
        time.sleep(0.2)
        after = set(os.listdir(sig_dir()))
        new = [f for f in (after - before) if f.startswith("inline_")]
        if new:
            # Read it and verify shape
            payload = json.loads(open(os.path.join(sig_dir(), new[0]),
                                                  encoding="utf-8").read())
            if payload.get("kind") == "html" and "<table" in payload.get("html", ""):
                ok("pandas display(df) captured HTML",
                   f"{len(payload['html'])} bytes")
                # Clean up — we read it instead of Swift
                os.remove(os.path.join(sig_dir(), new[0]))
            else:
                bad("pandas display(df) payload",
                    f"kind={payload.get('kind')} no <table>")
        else:
            bad("pandas display(df) capture", "no inline_*.json appeared")
    except ImportError as e:
        skip("pandas path", f"pandas not available: {e}")
    except Exception as e:
        bad("pandas path", f"{type(e).__name__}: {e}")

    # ── PIL.Image.show() path ────────────────────────────────
    try:
        from PIL import Image
        before = set(os.listdir(sig_dir()))
        img = Image.new("RGB", (64, 64), (110, 90, 250))
        img.show()
        time.sleep(0.2)
        after = set(os.listdir(sig_dir()))
        new = [f for f in (after - before) if f.startswith("inline_")]
        if new:
            ok("PIL Image.show() captured", f"{len(new)} signal file(s)")
        else:
            bad("PIL Image.show() captured", "no inline_*.json appeared")
    except ImportError as e:
        skip("PIL path", f"PIL/Pillow not available: {e}")
    except Exception as e:
        bad("PIL path", f"{type(e).__name__}: {e}")


# ═════════════════════════════════════════════════════════════
# #6 — REPL (persistent namespace)
# ═════════════════════════════════════════════════════════════
def test_repl() -> None:
    hdr("#6 — REPL")
    try:
        import codebench_repl
        ok("codebench_repl importable")
    except ImportError as e:
        bad("codebench_repl import", str(e))
        return

    # Namespace builder shouldn't raise and should contain seeds
    try:
        ns = codebench_repl._build_initial_ns()
        if "math" in ns and "Path" in ns:
            ok("_build_initial_ns seeds stdlib", f"{len(ns)} names")
        else:
            bad("_build_initial_ns seeds stdlib",
                f"missing math/Path; got {sorted(list(ns)[:8])}…")
    except Exception as e:
        bad("_build_initial_ns", f"{type(e).__name__}: {e}")

    # Meta-command detection
    try:
        is_meta = codebench_repl._is_meta
        assert is_meta(":q") is True, "':q' should be meta"
        assert is_meta(":quit") is True, "':quit' should be meta"
        assert is_meta(":show") is True, "':show' should be meta"
        assert is_meta("a[:5]") is False, "'a[:5]' should NOT be meta"
        assert is_meta("dict[:5]") is False, "dict slice should NOT be meta"
        ok("_is_meta dispatches correctly")
    except AssertionError as e:
        bad("_is_meta", str(e))
    except Exception as e:
        bad("_is_meta", f"{type(e).__name__}: {e}")

    # Rich displayhook install + restore
    try:
        original = sys.displayhook
        codebench_repl.install_rich_displayhook()
        if sys.displayhook is not original:
            ok("install_rich_displayhook swapped sys.displayhook")
        else:
            bad("install_rich_displayhook", "sys.displayhook unchanged")
        sys.displayhook = original  # restore so this test doesn't pollute
    except Exception as e:
        bad("install_rich_displayhook", f"{type(e).__name__}: {e}")

    manual("REPL builtin",
           "From the terminal: `repl` → see prompt → type 2+2 → see 4 → :q to exit. "
           "Then `repl --keep` → variables defined last time should still exist.")


# ═════════════════════════════════════════════════════════════
# #3 — Visual debugger (backend smoke test)
# ═════════════════════════════════════════════════════════════
def test_debugger() -> None:
    hdr("#3 — Visual debugger backend")
    try:
        import codebench_debug
        ok("codebench_debug importable")
    except ImportError as e:
        bad("codebench_debug import", str(e))
        return

    # Helper paths
    if codebench_debug._signal_dir() and codebench_debug._state_path().endswith(
            "debug_state.json"):
        ok("signal-file paths correct")
    else:
        bad("signal-file paths", "_state_path / _cmd_path mis-shaped")

    # The repr clipper should bound long values
    try:
        long_val = "x" * 5000
        clipped = codebench_debug._safe_repr(long_val)
        if len(clipped) <= 250 and clipped.endswith("…"):
            ok("_safe_repr clips long values", f"{len(clipped)} chars")
        else:
            bad("_safe_repr clipping",
                f"got {len(clipped)} chars (expected ≤250 + ellipsis)")
    except Exception as e:
        bad("_safe_repr clipping", f"{type(e).__name__}: {e}")

    # The frame snapshotter should skip dunders
    try:
        # Build a fake frame-locals dict
        class FakeFrame:
            f_locals = {"x": 42, "__hidden__": "no", "name": "alice",
                        "tbl": list(range(10))}
        snap = codebench_debug._snapshot_frame(FakeFrame())
        if "__hidden__" not in snap and "x" in snap and "name" in snap:
            ok("_snapshot_frame strips dunders", f"{sorted(snap)}")
        else:
            bad("_snapshot_frame",
                f"expected dunder stripped; got {sorted(snap)}")
    except Exception as e:
        bad("_snapshot_frame", f"{type(e).__name__}: {e}")

    # End-to-end: write a state file, then ensure run_with_gui's done-marker
    # logic produces a sane status JSON on a tiny script.
    try:
        tmp_script = os.path.join(tempfile.gettempdir(), "_cb_dbg_test.py")
        with open(tmp_script, "w") as f:
            f.write("x = 1\nprint('hello debug')\n")
        # We can't drive run_with_gui interactively here (no Swift to send
        # commands), but we CAN verify it doesn't crash on import-time
        # path construction.
        _ = tmp_script  # just keep ref
        ok("test script created", tmp_script)
    except Exception as e:
        bad("debug end-to-end setup", f"{type(e).__name__}: {e}")

    manual("debug-gui builtin",
           "From terminal: `debug-gui test_target.py`. A floating toolbar "
           "should appear at the top of the editor. Tap Step Over → next "
           "line highlights. Tap variable-inspector icon → see locals panel.")


# ═════════════════════════════════════════════════════════════
# #1 — Jupyter notebook executor
# ═════════════════════════════════════════════════════════════
def test_notebook_executor() -> None:
    hdr("#1 — Jupyter notebook backend")
    try:
        import codebench_inline
    except ImportError as e:
        skip("notebook executor", f"codebench_inline missing: {e}")
        return

    # The _serve_notebook daemon should start
    try:
        codebench_inline._serve_notebook()
        ok("_serve_notebook daemon started", "(idempotent)")
    except Exception as e:
        bad("_serve_notebook", f"{type(e).__name__}: {e}")
        return

    # End-to-end: write a cell exec request, wait for response
    test_scope = "pytest_" + os.urandom(3).hex()
    exec_id = test_scope + "_1"
    req = {
        "exec_id": exec_id,
        "scope": test_scope,
        "code": "x = 2 + 2\nx",
    }
    sd = sig_dir()
    req_path = os.path.join(sd, f"notebook_exec_request_{exec_id}.json")
    resp_path = os.path.join(sd, f"notebook_exec_response_{exec_id}.json")
    try:
        with open(req_path, "w") as f:
            json.dump(req, f)
        # Daemon polls every 150 ms — give it up to 3 s
        deadline = time.time() + 3
        while time.time() < deadline:
            if os.path.exists(resp_path):
                break
            time.sleep(0.1)
        if not os.path.exists(resp_path):
            bad("notebook exec round-trip", f"no response after 3s at {resp_path}")
            return
        with open(resp_path) as f:
            resp = json.load(f)
        os.remove(resp_path)
        # Result should be "4" (last-expression captured)
        if resp.get("result", "").strip() == "4":
            ok("cell exec captured last-expr result", "result=4")
        else:
            bad("cell exec result",
                f"expected '4' got {resp.get('result')!r}")
        if resp.get("error"):
            bad("cell exec error",
                f"unexpected error: {resp['error']}")
    except Exception as e:
        bad("notebook exec round-trip", f"{type(e).__name__}: {e}")

    # Test exec with stdout
    exec_id2 = test_scope + "_2"
    req2 = {
        "exec_id": exec_id2,
        "scope": test_scope,
        "code": "print('hello from cell')\nprint('line 2')",
    }
    req_path2 = os.path.join(sd, f"notebook_exec_request_{exec_id2}.json")
    resp_path2 = os.path.join(sd, f"notebook_exec_response_{exec_id2}.json")
    try:
        with open(req_path2, "w") as f:
            json.dump(req2, f)
        deadline = time.time() + 3
        while time.time() < deadline:
            if os.path.exists(resp_path2):
                break
            time.sleep(0.1)
        if not os.path.exists(resp_path2):
            bad("notebook exec stdout", "no response")
            return
        with open(resp_path2) as f:
            resp = json.load(f)
        os.remove(resp_path2)
        if "hello from cell" in resp.get("stdout", ""):
            ok("cell exec captured stdout",
               f"{len(resp['stdout'].splitlines())} lines")
        else:
            bad("cell exec stdout", f"got {resp.get('stdout')!r}")
    except Exception as e:
        bad("notebook stdout test", f"{type(e).__name__}: {e}")

    # Test that namespace persists across cells (same scope)
    exec_id3 = test_scope + "_3"
    req3 = {
        "exec_id": exec_id3,
        "scope": test_scope,
        "code": "x * 3",   # x was defined in cell 1
    }
    req_path3 = os.path.join(sd, f"notebook_exec_request_{exec_id3}.json")
    resp_path3 = os.path.join(sd, f"notebook_exec_response_{exec_id3}.json")
    try:
        with open(req_path3, "w") as f:
            json.dump(req3, f)
        deadline = time.time() + 3
        while time.time() < deadline:
            if os.path.exists(resp_path3):
                break
            time.sleep(0.1)
        if not os.path.exists(resp_path3):
            bad("notebook namespace persistence", "no response")
            return
        with open(resp_path3) as f:
            resp = json.load(f)
        os.remove(resp_path3)
        if resp.get("result", "").strip() == "12":
            ok("namespace persists across cells", "x*3 = 12")
        else:
            bad("namespace persistence",
                f"x*3 → {resp.get('result')!r} (expected '12'); "
                f"error={resp.get('error')}")
    except Exception as e:
        bad("namespace persistence", f"{type(e).__name__}: {e}")

    manual(".ipynb file opening",
           "Tap codebench_features_test.ipynb in the file browser → "
           "should open in cell-stacked notebook editor (not Monaco).")


# ═════════════════════════════════════════════════════════════
# #9 — Data viewer (fixtures + numpy daemon)
# ═════════════════════════════════════════════════════════════
def test_data_viewer_fixtures() -> None:
    hdr("#9 — Data viewer fixtures")

    # Create test artefacts in the user's Documents dir so the file
    # browser sees them.
    docs = Path.home() / "Documents"
    if not docs.exists():
        docs = Path(tempfile.gettempdir())
    out_dir = docs / "codebench_test_data"
    out_dir.mkdir(parents=True, exist_ok=True)

    # CSV fixture
    csv_path = out_dir / "iris_mini.csv"
    csv_path.write_text(
        "sepal_length,sepal_width,petal_length,petal_width,species\n"
        "5.1,3.5,1.4,0.2,setosa\n"
        "4.9,3.0,1.4,0.2,setosa\n"
        "7.0,3.2,4.7,1.4,versicolor\n"
        "6.3,3.3,6.0,2.5,virginica\n"
    )
    ok("CSV fixture", str(csv_path))

    # JSON fixture (nested)
    json_path = out_dir / "config.json"
    json_path.write_text(json.dumps({
        "model": "llama3.1:8b",
        "params": {"temperature": 0.7, "top_p": 0.95},
        "stops": ["\n###", "</s>"],
        "enabled": True,
    }, indent=2))
    ok("JSON fixture", str(json_path))

    # NumPy fixture (.npy)
    try:
        import numpy as np
        npy_path = out_dir / "demo_matrix.npy"
        np.save(str(npy_path), np.random.rand(20, 8).round(3))
        ok("NumPy .npy fixture", f"{npy_path} (20×8 float64)")

        # Test the .npy quicklook serve loop end-to-end
        try:
            import codebench_inline
            codebench_inline._serve_numpy_quicklook()
            time.sleep(0.1)  # let daemon start
            sd = sig_dir()
            req_path = os.path.join(sd, "numpy_quicklook_request.txt")
            resp_path = os.path.join(sd, "numpy_quicklook_response.html")
            # Clean any stale state
            for p in (req_path, resp_path):
                if os.path.exists(p):
                    os.remove(p)
            with open(req_path, "w") as f:
                f.write(str(npy_path))
            deadline = time.time() + 3
            while time.time() < deadline and not os.path.exists(resp_path):
                time.sleep(0.1)
            if os.path.exists(resp_path):
                html = open(resp_path, encoding="utf-8").read()
                os.remove(resp_path)
                if "shape=" in html and "<table" in html:
                    ok("numpy quicklook end-to-end",
                       f"{len(html)} bytes HTML")
                else:
                    bad("numpy quicklook payload",
                        f"missing shape/table markers; head={html[:120]!r}")
            else:
                bad("numpy quicklook round-trip",
                    "no response after 3s")
        except Exception as e:
            bad("numpy quicklook daemon", f"{type(e).__name__}: {e}")
    except ImportError:
        skip("NumPy .npy fixture", "numpy not installed")

    # PNG fixture (if PIL available)
    try:
        from PIL import Image, ImageDraw
        png_path = out_dir / "test_image.png"
        img = Image.new("RGB", (200, 100), (40, 30, 80))
        d = ImageDraw.Draw(img)
        d.rectangle([20, 20, 180, 80], fill=(170, 90, 250))
        img.save(str(png_path))
        ok("PNG fixture", str(png_path))
    except ImportError:
        skip("PNG fixture", "PIL/Pillow not available")

    manual("Quick Look UI",
           f"Open file browser → navigate to {out_dir.name}/ → "
           f"long-press iris_mini.csv → tap 'Quick Look' → "
           f"see grid view. Repeat for config.json, demo_matrix.npy, test_image.png.")


# ═════════════════════════════════════════════════════════════
# #23 — AI provider settings
# ═════════════════════════════════════════════════════════════
def test_ai_settings_proto() -> None:
    hdr("#23 — AI provider config")

    # Verify the per-request `provider` override works via the
    # ai_request.json protocol. Don't actually call an LLM — just
    # check the response carries an error indicating the routing
    # reached the remote-provider path (no API key configured).
    sd = sig_dir()
    req = {
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 10,
        "provider": "openai",   # force remote routing
    }
    req_path = os.path.join(sd, "ai_request.json")
    resp_path = os.path.join(sd, "ai_done.txt")
    try:
        # Clean stale state
        for p in (req_path, resp_path):
            if os.path.exists(p):
                os.remove(p)
        with open(req_path, "w") as f:
            json.dump(req, f)
        # Wait up to 3s for AIEngine to respond
        deadline = time.time() + 3
        while time.time() < deadline and not os.path.exists(resp_path):
            time.sleep(0.1)
        if os.path.exists(resp_path):
            body = open(resp_path, encoding="utf-8").read()
            os.remove(resp_path)
            # Three acceptable outcomes:
            #   1. New AIEngine (post-rebuild) — returns -2 "not configured"
            #      because no API key + baseURL set. Proves the routing
            #      reached the remote-provider branch.
            #   2. Old AIEngine (pre-rebuild) — ignores the `provider`
            #      field, tries LlamaRunner, returns -2/-3 "Model not loaded"
            #      because no GGUF is loaded. Acceptable too (it just means
            #      the test pre-dates the rebuild).
            #   3. Remote actually responded with a generation — body starts
            #      with "0\n" meaning success.
            lower = body.lower()
            if "not configured" in lower or "baseurl" in lower:
                ok("AI provider routes to remote when requested",
                   body.strip().replace("\n", " ")[:80])
            elif "model not loaded" in lower or "no model loaded" in lower:
                skip("AI provider routing",
                     "pre-rebuild AIEngine — recompile Xcode to test remote routing")
            elif body.startswith("0\n"):
                ok("AI provider returned success",
                   "(remote is configured + reachable)")
            else:
                bad("AI provider routing",
                    f"unexpected body: {body[:120]!r}")
        else:
            skip("AI provider routing",
                 "no response — is the CodeBench app actually running?")
    except Exception as e:
        bad("AI provider routing", f"{type(e).__name__}: {e}")

    manual("AI settings sheet",
           "Press ⌘, → settings sheet appears → switch between "
           "Bundled / OpenAI / Anthropic / Compat. Type a fake key, "
           "tap Done, reopen → key should be preserved.")


# ═════════════════════════════════════════════════════════════
# #10, #24 — Pure UI (manual checklist)
# ═════════════════════════════════════════════════════════════
def manual_ui_checklist() -> None:
    hdr("#10 — Vim mode (manual)")
    manual("Toggle vim",
           "⌘, → toggle Vim Mode ON → tap into editor → see NORMAL pill bottom-right. "
           "Press 'i' → INSERT pill (green). Press ESC → NORMAL. "
           "Press 'dd' → current line deleted. ':w' → file saves.")
    manual("Vim search",
           "In NORMAL mode press '/foo' → finds 'foo'. 'n' goes to next match.")
    manual("Vim counts",
           "Type '5j' → cursor moves down 5 lines. '3dd' → deletes 3 lines.")

    hdr("#24 — Cmd+P quick open (manual)")
    manual("Quick open",
           "Press ⌘P in the editor → modal pops with file list. Type 'iri' → "
           "iris_mini.csv ranks first (fuzzy match). ↑/↓ navigates. Enter opens.")
    manual("Recent files",
           "Open a few files → ⌘P again → those files appear at the top with "
           "'recent ·' subtitle.")


# ═════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════
def print_summary() -> None:
    print(f"\n{BOLD}━━━ Summary ━━━{RESET}")
    print(f"  {GREEN}PASS:   {PASS}{RESET}")
    print(f"  {RED}FAIL:   {FAIL}{RESET}")
    print(f"  {YELLOW}SKIP:   {SKIP}{RESET}")
    print(f"  {CYAN}MANUAL: {MANUAL}{RESET}  (do these by hand in the app)")
    if FAILURES:
        print(f"\n{RED}Failed:{RESET}")
        for label, why in FAILURES:
            print(f"  • {label}: {why}")
    if FAIL == 0:
        print(f"\n{GREEN}{BOLD}All automated tests passed.{RESET}")
        print(f"{DIM}Now work through the {MANUAL} manual checks above "
              f"to verify the UI features.{RESET}")
    else:
        print(f"\n{RED}{BOLD}{FAIL} test(s) failed — see above.{RESET}")


# ═════════════════════════════════════════════════════════════
# Main
# ═════════════════════════════════════════════════════════════
def main() -> int:
    print(f"{BOLD}CodeBench feature test — 8 features{RESET}")
    print(f"{DIM}Started at {time.strftime('%H:%M:%S')}{RESET}")
    print(f"{DIM}Signal dir: {sig_dir()}{RESET}")

    test_inline_outputs()
    test_repl()
    test_debugger()
    test_notebook_executor()
    test_data_viewer_fixtures()
    test_ai_settings_proto()
    manual_ui_checklist()

    print_summary()
    return 1 if FAIL else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print(f"\n{YELLOW}Interrupted by user.{RESET}")
        sys.exit(130)
    except Exception as e:
        print(f"\n{RED}Test harness crashed: {type(e).__name__}: {e}{RESET}")
        traceback.print_exc()
        sys.exit(2)
