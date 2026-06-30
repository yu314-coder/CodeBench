import Foundation

private typealias PyObjectPointer = OpaquePointer
private typealias PyGILStateState = Int32
private typealias PySsizeT = Int

@_silgen_name("Py_IsInitialized") private func Py_IsInitialized() -> Int32
@_silgen_name("Py_Initialize") private func Py_Initialize()
@_silgen_name("PyGILState_Ensure") private func PyGILState_Ensure() -> PyGILStateState
@_silgen_name("PyGILState_Release") private func PyGILState_Release(_ state: PyGILStateState)
@_silgen_name("PyImport_AddModule") private func PyImport_AddModule(_ name: UnsafePointer<CChar>) -> PyObjectPointer?
@_silgen_name("PyModule_GetDict") private func PyModule_GetDict(_ module: PyObjectPointer?) -> PyObjectPointer?
@_silgen_name("Py_CompileString") private func Py_CompileString(_ code: UnsafePointer<CChar>, _ filename: UnsafePointer<CChar>, _ mode: Int32) -> PyObjectPointer?
@_silgen_name("PyEval_EvalCode") private func PyEval_EvalCode(_ code: PyObjectPointer?, _ globals: PyObjectPointer?, _ locals: PyObjectPointer?) -> PyObjectPointer?
@_silgen_name("Py_DecRef") private func Py_DecRef(_ object: PyObjectPointer?)
@_silgen_name("PyUnicode_FromString") private func PyUnicode_FromString(_ value: UnsafePointer<CChar>) -> PyObjectPointer?
@_silgen_name("PyDict_SetItemString") private func PyDict_SetItemString(_ dict: PyObjectPointer?, _ key: UnsafePointer<CChar>, _ item: PyObjectPointer?) -> Int32
@_silgen_name("PyDict_GetItemString") private func PyDict_GetItemString(_ dict: PyObjectPointer?, _ key: UnsafePointer<CChar>) -> PyObjectPointer?
@_silgen_name("PyUnicode_AsUTF8AndSize") private func PyUnicode_AsUTF8AndSize(_ object: PyObjectPointer?, _ size: UnsafeMutablePointer<PySsizeT>?) -> UnsafePointer<CChar>?
@_silgen_name("PyObject_Str") private func PyObject_Str(_ object: PyObjectPointer?) -> PyObjectPointer?
@_silgen_name("PyErr_Occurred") private func PyErr_Occurred() -> PyObjectPointer?
@_silgen_name("PyErr_Fetch") private func PyErr_Fetch(_ type: UnsafeMutablePointer<PyObjectPointer?>?, _ value: UnsafeMutablePointer<PyObjectPointer?>?, _ traceback: UnsafeMutablePointer<PyObjectPointer?>?)
@_silgen_name("PyErr_NormalizeException") private func PyErr_NormalizeException(_ type: UnsafeMutablePointer<PyObjectPointer?>?, _ value: UnsafeMutablePointer<PyObjectPointer?>?, _ traceback: UnsafeMutablePointer<PyObjectPointer?>?)
@_silgen_name("PyEval_SaveThread") private func PyEval_SaveThread() -> OpaquePointer?
@_silgen_name("PyRun_SimpleString") private func PyRun_SimpleString(_ code: UnsafePointer<CChar>) -> Int32
@_silgen_name("PyErr_SetInterrupt") private func PyErr_SetInterrupt()
@_silgen_name("PyGILState_Check") private func PyGILState_Check() -> Int32

// Direct-call C API (used by the JS-API fast path: cached function
// pointer + PyObject_CallObject per request, no PyRun_SimpleString).
@_silgen_name("PyImport_ImportModule") private func PyImport_ImportModule(_ name: UnsafePointer<CChar>) -> PyObjectPointer?
@_silgen_name("PyObject_GetAttrString") private func PyObject_GetAttrString(_ obj: PyObjectPointer?, _ name: UnsafePointer<CChar>) -> PyObjectPointer?
@_silgen_name("PyObject_CallObject") private func PyObject_CallObject(_ callable: PyObjectPointer?, _ args: PyObjectPointer?) -> PyObjectPointer?
@_silgen_name("PyTuple_New") private func PyTuple_New(_ size: PySsizeT) -> PyObjectPointer?
@_silgen_name("PyTuple_SetItem") private func PyTuple_SetItem(_ tuple: PyObjectPointer?, _ pos: PySsizeT, _ item: PyObjectPointer?) -> Int32
@_silgen_name("Py_IncRef") private func Py_IncRef(_ obj: PyObjectPointer?)
@_silgen_name("PyErr_Print") private func PyErr_Print()
@_silgen_name("PyErr_Clear") private func PyErr_Clear()

final class PythonRuntime {
    static let shared = PythonRuntime()

    struct ExecutionResult {
        let output: String
        let imagePath: String?
    }

    struct LibraryProbe: Equatable {
        enum State: String {
            case installed
            case shim
            case missing
            case error
        }

        let name: String
        let state: State
        let detail: String?
    }

    /// Rich metadata for one installed Python distribution. Returned in
    /// bulk by `enumerateInstalledLibraries()` and consumed by
    /// LibraryDocsViewController to render the "Installed packages"
    /// section that refreshes on every tab visit (so newly pip-installed
    /// libs show up without a restart).
    struct InstalledLibraryInfo: Equatable {
        let name: String
        let version: String
        let summary: String
        let homepage: String
        let location: String
        let isUserInstalled: Bool   // ~/Documents/site-packages vs bundled
        let sizeBytes: Int64
        let consoleScripts: [String]
        let requires: [String]
    }

    private enum RuntimeError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let value):
                return value
            }
        }
    }

    private let queue = DispatchQueue(label: "codebench.python.runtime")
    private let queueKey = DispatchSpecificKey<Void>()
    private var pathsConfigured = false
    private var toolOutputDirectoryURL: URL?
    private var environmentConfigured = false
    private let fileInputMode: Int32 = 257 // Py_file_input
    private var gilReleasedForThreads = false
    /// Class-picker selection for the next `executeSync` run. "" = all
    /// scenes (legacy default), "*" = all scenes (explicit), otherwise
    /// the bare class name to render. Reset to "" by every executeSync
    /// invocation after it's been pushed into the wrapper's globals.
    private var targetSceneForNextRun: String = ""

    /// Absolute path of the .py launched by the editor's Run button. Lets the
    /// wrapper set __file__ / sys.argv[0] / sys.path[0] so a Run behaves
    /// exactly like `python <file>` in the terminal — scripts that use
    /// os.path.abspath(__file__) or import sibling modules then work. Empty
    /// when running an anonymous buffer / non-file snippet.
    private var scriptPathForNextRun: String = ""

    private init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    /// Single-shot Python execution with no streaming and no scene
    /// targeting (renders all detected manim Scene subclasses).
    func execute(code: String) -> ExecutionResult {
        return execute(code: code, targetScene: nil, onOutput: nil)
    }

    /// Streaming Python execution. `targetScene` is the result of a
    /// class-picker dialog: pass nil or "" for the legacy "render all
    /// detected Scene subclasses" behaviour, "*" for "render all"
    /// (explicit), or the bare class name (e.g. "Lesson03_BuildPrism")
    /// to render only that class. The wrapper script reads it from
    /// `__codebench_target_scene` and filters its scene-class list
    /// accordingly.
    func execute(code: String, targetScene: String?, scriptPath: String? = nil, onOutput: ((String) -> Void)?) -> ExecutionResult {
        // Stash the picker selection in a property so executeSync (which
        // doesn't take parameters) can read it from setGlobalString just
        // before runStatements fires.
        targetSceneForNextRun = targetScene ?? ""
        scriptPathForNextRun = scriptPath ?? ""
        return execute(code: code, onOutput: onOutput)
    }

    func execute(code: String, onOutput: ((String) -> Void)?) -> ExecutionResult {
        if let onOutput = onOutput {
            // Streaming mode: run Python on its queue, poll output file from caller thread
            let semaphore = DispatchSemaphore(value: 0)
            var result = ExecutionResult(output: "", imagePath: nil)

            // Pre-compute stream file path on calling thread
            let toolDir: String
            do {
                toolDir = try ensureToolOutputDirectory().path
            } catch {
                toolDir = NSTemporaryDirectory()
            }
            let streamFile = (toolDir as NSString).appendingPathComponent("_stream_stdout.txt")
            let stderrFile = (toolDir as NSString).appendingPathComponent("_stream_stderr.txt")

            // Delete stale stream files from previous run
            try? FileManager.default.removeItem(atPath: streamFile)
            try? FileManager.default.removeItem(atPath: stderrFile)

            queue.async {
                result = self.executeSync(code: code)
                semaphore.signal()
            }

            // Poll both stdout and stderr stream files while Python runs
            // tqdm writes to stderr by default — we must capture both
            var stdoutOffset: UInt64 = 0
            var stderrOffset: UInt64 = 0

            while semaphore.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                let newStdout = self.readNewStreamBytes(from: streamFile, offset: &stdoutOffset)
                if !newStdout.isEmpty {
                    onOutput(newStdout)
                }
                let newStderr = self.readNewStreamBytes(from: stderrFile, offset: &stderrOffset)
                if !newStderr.isEmpty {
                    onOutput(newStderr)
                }
            }

            // Final flush — read any remaining content from both streams
            let remainOut = self.readNewStreamBytes(from: streamFile, offset: &stdoutOffset)
            if !remainOut.isEmpty {
                onOutput(remainOut)
            }
            let remainErr = self.readNewStreamBytes(from: stderrFile, offset: &stderrOffset)
            if !remainErr.isEmpty {
                onOutput(remainErr)
            }

            return result
        }

        // Non-streaming mode (original behavior)
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return executeSync(code: code)
        }
        return queue.sync {
            executeSync(code: code)
        }
    }

    /// Read new bytes from a stream file starting at the given offset. Fully defensive — never throws.
    private func readNewStreamBytes(from path: String, offset: inout UInt64) -> String {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else {
            return ""
        }
        let total = UInt64(data.count)
        guard total > offset else { return "" }
        let newData = data.subdata(in: Int(offset)..<Int(total))
        offset = total
        return String(data: newData, encoding: .utf8) ?? ""
    }

    private static var replStarted = false
    private static let replLock = NSLock()

    /// Raise KeyboardInterrupt in the Python main thread. Safe to
    /// call from any thread (Swift's Ctrl-C handler, usually); the
    /// interrupt is set asynchronously and takes effect at the next
    /// Python bytecode boundary. This is how a user interrupts a
    /// long-running computation (`while True: ...` etc.).
    ///
    /// Only meaningful once Python is initialized; before that we
    /// just swallow the request.
    func interruptPythonMainThread() {
        guard Py_IsInitialized() != 0 else { return }
        // PyErr_SetInterrupt is one of the few Python C-API calls
        // that's safe to invoke without holding the GIL.
        PyErr_SetInterrupt()
    }

    /// Dispatch a JS API call to Python's `webview` module IN-PROCESS,
    /// bypassing the file-IPC + dispatcher-poll path entirely.
    ///
    /// Returns (resultJSON, errorMessage). Exactly one is non-nil.
    /// `resultJSON` is a JSON-encoded string (callers JSON.parse it
    /// JS-side). `errorMessage` is a plain string suitable to reject
    /// the JS Promise with.
    ///
    /// Runs synchronously: acquires the GIL, executes the Python
    /// snippet, reads back the result. Caller MUST be on a background
    /// queue — if Python is busy running user code, the GIL acquire
    /// blocks until it's released. Typical latency when Python is
    /// idle: ~1 ms. When user code is running tight loops (no GIL
    /// release): up to one bytecode-tick (~10ms by default).
    ///
    /// Eliminates ALL file-IPC + polling for the hot JS-API path.
    /// Was: ~13 ms per call (Swift poll 10ms / 2 + Python poll 10ms / 2
    /// + IPC overhead). Now: ~1-2 ms when Python is idle.
    /// Cached `webview._dispatch_inline` PyObject. Resolved on first
    /// call (after Py_Initialize and `import webview`), reused on
    /// every subsequent dispatch. `PyObject_CallObject(_dispatchFn,
    /// argsTuple)` is the entire hot path — no PyRun_SimpleString,
    /// no module/global lookups. Roughly 10-50× faster per call than
    /// the previous string-based dispatch (matches upstream pywebview
    /// which does direct `function(*args)` invocation in util.py).
    private var _dispatchInlineFn: PyObjectPointer?
    private let _dispatchLock = NSLock()

    func dispatchJsApiInline(method: String,
                              argsJson: String) -> (String?, String?) {
        guard Py_IsInitialized() != 0 else {
            return (nil, "Python not initialized")
        }
        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }

        // Lazy-resolve the cached `webview._dispatch_inline` callable.
        // Imported once, ref'd forever — Python keeps it alive for
        // the process lifetime.
        if _dispatchInlineFn == nil {
            _dispatchLock.lock()
            defer { _dispatchLock.unlock() }
            if _dispatchInlineFn == nil {
                guard let mod = "webview".withCString({ PyImport_ImportModule($0) }) else {
                    PyErr_Clear()
                    return (nil, "cannot import webview")
                }
                guard let fn = "_dispatch_inline".withCString({
                    PyObject_GetAttrString(mod, $0)
                }) else {
                    Py_DecRef(mod)
                    PyErr_Clear()
                    return (nil, "webview._dispatch_inline not found")
                }
                Py_DecRef(mod)        // we don't need the module ref
                _dispatchInlineFn = fn // keeps the function alive
            }
        }

        // Build the args tuple: (method_name, args_json). PyTuple_SetItem
        // STEALS the reference, which is why we use PyUnicode_FromString
        // freshly here and don't decref afterwards.
        guard let argsTuple = PyTuple_New(2) else {
            return (nil, "PyTuple_New failed")
        }
        defer { Py_DecRef(argsTuple) }

        let pyMethod = method.withCString { PyUnicode_FromString($0) }
        guard pyMethod != nil else {
            return (nil, "PyUnicode_FromString(method) failed")
        }
        if PyTuple_SetItem(argsTuple, 0, pyMethod) != 0 {
            // SetItem stole pyMethod's ref even on failure; don't decref.
            return (nil, "PyTuple_SetItem(0) failed")
        }

        let pyArgs = argsJson.withCString { PyUnicode_FromString($0) }
        guard pyArgs != nil else {
            return (nil, "PyUnicode_FromString(args) failed")
        }
        if PyTuple_SetItem(argsTuple, 1, pyArgs) != 0 {
            return (nil, "PyTuple_SetItem(1) failed")
        }

        // The actual call — single PyObject_CallObject. This is what
        // makes the bridge feel native: no source parsing, no global
        // dict walk, just a direct C-level call into the cached
        // Python function.
        guard let result = PyObject_CallObject(_dispatchInlineFn, argsTuple) else {
            // Python raised. Pull the exception, format, return.
            let err = pyExceptionString() ?? "Python call raised (no message)"
            return (nil, err)
        }
        defer { Py_DecRef(result) }

        // _dispatch_inline returns a JSON string; convert to Swift.
        guard let json = pyObjectToString(result) else {
            return (nil, "result not stringifiable")
        }
        return (json, nil)
    }

    /// Pull the current Python exception (if any) into a Swift
    /// string and clear it. Returns nil if no exception is set.
    private func pyExceptionString() -> String? {
        var pType: PyObjectPointer? = nil
        var pValue: PyObjectPointer? = nil
        var pTraceback: PyObjectPointer? = nil
        PyErr_Fetch(&pType, &pValue, &pTraceback)
        defer {
            if pType != nil { Py_DecRef(pType) }
            if pValue != nil { Py_DecRef(pValue) }
            if pTraceback != nil { Py_DecRef(pTraceback) }
        }
        guard let value = pValue else { return nil }
        PyErr_NormalizeException(&pType, &pValue, &pTraceback)
        return pyObjectToString(value)
    }

    /// Convert a Python object to its UTF-8 string representation.
    /// Returns nil if the object can't be converted (rare).
    private func pyObjectToString(_ obj: PyObjectPointer) -> String? {
        // PyObject_Str gives us a Python str (calls __str__).
        guard let strObj = PyObject_Str(obj) else { return nil }
        defer { Py_DecRef(strObj) }
        var size: PySsizeT = 0
        guard let cStr = PyUnicode_AsUTF8AndSize(strObj, &size) else { return nil }
        return String(cString: cStr)
    }

    /// Hard stop the running task — what the user expects when they
    /// hit Stop or Ctrl+C in the terminal.
    ///
    /// Two paths, each covers a state the REPL can be in:
    ///   1. PyErr_SetInterrupt() — sets the bytecode-loop flag.
    ///      Catches `while True:` and any tight Python loop. Also
    ///      makes time.sleep() return immediately with KeyboardInterrupt.
    ///   2. Inject 0x03 into the PTY pipe — caller does this via
    ///      LineBuffer/PTYBridge (Stop button & keyboard Ctrl+C both
    ///      route through here). The byte arrives in stdin; blocked
    ///      input() / os.read() in the REPL or sub-REPL (js/node)
    ///      sees it. Our patched builtins.input recognizes 0x03 as
    ///      KeyboardInterrupt; the REPL's own read loop already does.
    ///
    /// Note: pthread_kill of an arbitrary thread doesn't reliably
    /// interrupt blocking syscalls on Darwin — the kernel routes the
    /// signal back to the main thread regardless of the requested
    /// target. The byte-injection path in (2) is what actually unblocks
    /// the JS REPL / pywebview poll / shell.run_line in practice.
    /// SOFT interrupt — what Ctrl+C should always be. Sets the
    /// bytecode-loop signal flag so tight Python loops bail with
    /// KeyboardInterrupt; the 0x03 byte injection (wired in callers)
    /// unblocks read()/input(). Does NOT touch modules or thread
    /// state — the REPL keeps running, the user can keep typing.
    func hardStopRunningTask() {
        if Py_IsInitialized() != 0 {
            PyErr_SetInterrupt()
        }
        // Path 2 (byte injection) is wired in the callers:
        //   • LineBuffer.handle case 0x03 ─── keyboard ^C
        //   • CodeEditorViewController.terminalInterrupt ─── Stop button
    }

    /// HARD kill — for when a soft interrupt didn't take (stuck in
    /// a long C call holding the GIL, hardware encoder thread,
    /// etc.). Writes the kill-signal file that the offlinai_shell
    /// daemon polls; the daemon then injects SystemExit into every
    /// non-main thread, force-closes PyAV / encoder / IOSurface
    /// state, drops manim modules, and forces a malloc page release.
    ///
    /// This DOES tear down running tasks aggressively and can leave
    /// the REPL in a degraded state until the next interpreter
    /// cycle. Only call when the soft interrupt has already had a
    /// chance to land — e.g. long-press on the Stop button after
    /// a regular tap didn't work.
    func forceKillRunningTask() {
        // Still set the interrupt flag so Python's main thread
        // bails the moment it returns from C land.
        if Py_IsInitialized() != 0 {
            PyErr_SetInterrupt()
        }
        let tmp = NSTemporaryDirectory()
        let signalPath = (tmp as NSString)
            .appendingPathComponent("codebench_kill.signal")
        try? Data().write(to: URL(fileURLWithPath: signalPath))
    }

    /// Eagerly boot Python (Py_Initialize + stdio redirect) and start
    /// the REPL thread. Call this from CodeEditorViewController when
    /// the terminal view appears, so the user can type commands
    /// immediately instead of having to hit Run first.
    ///
    /// Idempotent — subsequent calls are no-ops.
    func ensureRuntimeReady() {
        queue.async {
            if Py_IsInitialized() == 0 {
                do {
                    try self.configureEnvironmentBeforeInitialize()
                    PTYBridge.exportTTYEnv(cols: 80, rows: 24)
                    PTYBridge.shared.setupIfNeeded()
                    NSLog("[python] ensureRuntimeReady: calling Py_Initialize()")
                    Py_Initialize()
                    guard Py_IsInitialized() != 0 else {
                        NSLog("[python] ensureRuntimeReady: Py_Initialize failed")
                        return
                    }
                    NSLog("[python] ensureRuntimeReady: Py_Initialize done")

                    // Redirect sys.stdout / sys.stderr to the pipe at
                    // the Python level (same snippet as runTool uses).
                    let pipeFD = PTYBridge.shared.stdoutPipeWriteFD
                    let redirectSrc = """
                    import sys, os, io
                    try:
                        _fd = \(pipeFD)
                        if _fd >= 0:
                            _w = os.fdopen(_fd, 'w', buffering=1,
                                           encoding='utf-8', errors='replace',
                                           closefd=False)
                            sys.stdout = _w
                            sys.stderr = _w
                    except Exception as _e:
                        pass

                    # Pre-warm platform.uname() on this single thread BEFORE
                    # the REPL thread or any user code can race on it. The
                    # iOS implementation (Lib/_ios_support.py) reads the
                    # device's name/version/model via ctypes → libobjc's
                    # objc_msgSend, and it mutates `objc.objc_msgSend.restype`
                    # (c_void_p, then c_char_p for UTF8String) on a SHARED
                    # function-pointer attribute. Two threads concurrently
                    # calling platform.uname() race on that restype — one
                    # thread's objc_msgSend returns an object pointer that
                    # the other thread's still-c_char_p reader dereferences
                    # via z_get → strlen, hitting a PAC failure on a
                    # signed/object pointer that isn't a real C string.
                    # Surfaces as intermittent EXC_BAD_ACCESS during launch
                    # (faulting thread "codebench-repl", stack ends in
                    # _ctypes.z_get +28 → strlen → PAC).
                    # Once `_uname_cache` is populated, subsequent calls hit
                    # it and skip the racy ctypes path entirely.
                    try:
                        import platform
                        platform.uname()
                    except Exception as _e:
                        sys.__stderr__.write(f"[bootstrap] uname pre-warm failed: {_e}\\n")
                    """
                    _ = redirectSrc.withCString { PyRun_SimpleString($0) }

                    // Release the initial GIL so the REPL thread can
                    // acquire it.
                    let _ = PyEval_SaveThread()
                } catch {
                    NSLog("[python] ensureRuntimeReady: env setup failed: \(error)")
                    return
                }
            }
            PythonRuntime.startInteractiveShellIfNeeded()
        }
    }

    /// Start the interactive shell REPL on a background thread. Idempotent
    /// — subsequent calls are no-ops. Reads forever from sys.stdin (which
    /// is dup2'd onto the PTY slave by PTYBridge), so everything the user
    /// types into the SwiftTerm view becomes a dispatch call into
    /// offlinai_shell.
    static func startInteractiveShellIfNeeded() {
        replLock.lock()
        let alreadyStarted = replStarted
        replStarted = true
        replLock.unlock()
        guard !alreadyStarted else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let gil = PyGILState_Ensure()
            defer { PyGILState_Release(gil) }
            let ok = PyRun_SimpleString("""
            import threading, traceback, sys, faulthandler
            # Enable faulthandler at the bootstrap level so any C-level
            # crash during `import offlinai_shell` (or its transitive
            # imports — manimpango, torch, av, …) prints a Python stack
            # trace to stderr instead of surfacing as a bare
            # EXC_BAD_ACCESS in the codebench-repl thread with no clue
            # where it came from. The shell's repl() re-enables it
            # later with all_threads=True; this earlier call covers
            # the import window.
            try:
                faulthandler.enable(file=sys.stderr, all_threads=True)
            except Exception as _fh_err:
                sys.stderr.write(f"[shell-bootstrap] faulthandler init failed: {_fh_err}\\n")
            def _codebench_start_repl():
                # Retry loop because the FIRST import attempt can race with
                # a Run-button wrapper that was scheduled at the same time:
                # the wrapper holds the GIL during its 4-5 s busytex prep,
                # then if the user hits Stop a stray PyErr_SetInterrupt flag
                # may still be pending when the bootstrap thread next gets
                # the GIL. That fires KeyboardInterrupt during our `import
                # offlinai_shell`, which used to silently kill this thread
                # because we only caught `Exception` (not BaseException).
                # Result: REPL thread dead, terminal totally unresponsive,
                # zero diagnostic output. Now we catch BaseException, log
                # to BOTH __stderr__ (Xcode console) AND a breadcrumb file
                # (so we can confirm survival from outside Python), and
                # retry up to 3 times for KeyboardInterrupt — anything
                # else is a real bug we want surfaced once.
                import os as _os, time as _time
                # ~/Documents is visible in the Files app on iOS so the
                # user can pull this off-device for diagnosis. TMPDIR
                # is sandboxed and unreachable.
                _bc_path = _os.path.expanduser("~/Documents/shell_bootstrap.txt")
                try:
                    _os.makedirs(_os.path.dirname(_bc_path), exist_ok=True)
                except Exception: pass
                def _bc(msg):
                    try:
                        sys.__stderr__.write(f"[shell-bootstrap] {msg}\\n")
                        sys.__stderr__.flush()
                    except Exception: pass
                    try:
                        with open(_bc_path, "a") as _f:
                            _f.write(f"{_time.time():.3f} {msg}\\n")
                    except Exception: pass

                _bc("entering forever-loop")
                # Infinite outer loop: if repl() ever RETURNS or
                # raises any exception other than KeyboardInterrupt,
                # we restart it. User-reported symptom: "terminal
                # stops responding, Run button kicks it back to life"
                # — root cause was an unhandled exception in a deep
                # builtin escaping the REPL's per-line handlers,
                # ending the thread. Without this outer loop the
                # whole shell goes silent and nothing short of
                # invoking Python via the Run button (which uses a
                # different code path) revives it.
                while True:
                    try:
                        import offlinai_shell
                        offlinai_shell.repl()
                        _bc("repl() returned — restarting in 200 ms")
                        _time.sleep(0.2)
                    except KeyboardInterrupt:
                        _bc("REPL KeyboardInterrupt — restarting")
                        _time.sleep(0.2)
                    except BaseException as _be:
                        _bc(f"REPL died with {type(_be).__name__}: {_be}; restarting in 500 ms")
                        try:
                            traceback.print_exc(file=sys.__stderr__)
                            sys.__stderr__.flush()
                        except Exception: pass
                        try:
                            with open(_bc_path, "a") as _f:
                                _f.write(traceback.format_exc())
                        except Exception: pass
                        _time.sleep(0.5)
            _t = threading.Thread(target=_codebench_start_repl, name='codebench-repl', daemon=True)
            _t.start()
            # (the REPL thread will print its own banner to the user;
            #  Swift-side status goes to NSLog via [shell] message below)
            """)
            if ok != 0 {
                NSLog("[shell] PyRun_SimpleString failed with code \(ok)")
            } else {
                NSLog("[shell] offlinai_shell.repl() thread started")
            }
        }
    }

    /// Call after first Py_Initialize to release the GIL for other threads
    private func releaseMainGILIfNeeded() {
        guard !gilReleasedForThreads else { return }
        gilReleasedForThreads = true
        // After Py_Initialize(), the calling thread holds the GIL.
        // We must release it so that PyGILState_Ensure can work from other threads.
        print("[python] Releasing initial GIL for thread safety")
    }

    func probeLibraries(_ libraries: [String]) -> [LibraryProbe] {
        let filtered = libraries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !filtered.isEmpty else { return [] }

        let script = """
import importlib, json
_codebench_lib_status = []
for _name in \(pythonArrayLiteral(filtered)):
    try:
        _mod = importlib.import_module(_name)
        _file = getattr(_mod, "__file__", "")
        _shim = not bool(_file)
        _codebench_lib_status.append({
            "name": _name,
            "state": "shim" if _shim else "installed",
            "detail": _file if _file else "built-in compatibility layer"
        })
    except Exception as _exc:
        _codebench_lib_status.append({
            "name": _name,
            "state": "missing",
            "detail": f"{type(_exc).__name__}: {_exc}"
        })
print("__CODEBENCH_LIB_STATUS__=" + json.dumps(_codebench_lib_status))
"""

        let result = execute(code: script)
        let output = result.output
        guard let markerRange = output.range(of: "__CODEBENCH_LIB_STATUS__=") else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return filtered.map {
                LibraryProbe(name: $0, state: .error, detail: detail.isEmpty ? "Probe failed." : detail)
            }
        }

        let jsonText = output[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return filtered.map {
                LibraryProbe(name: $0, state: .error, detail: "Probe response parsing failed.")
            }
        }

        return object.map { entry in
            let name = (entry["name"] as? String) ?? "unknown"
            let rawState = (entry["state"] as? String) ?? "error"
            let state = LibraryProbe.State(rawValue: rawState) ?? .error
            let detail = entry["detail"] as? String
            return LibraryProbe(name: name, state: state, detail: detail)
        }
    }

    /// Enumerate every installed Python distribution via importlib.metadata
    /// and return rich per-package info: name, version, summary, location
    /// (bundled vs ~/Documents/site-packages user install), on-disk size,
    /// homepage URL, console-scripts entry points, and direct deps.
    ///
    /// Refreshable: each call re-walks importlib.metadata so freshly
    /// pip-installed packages appear without restarting the interpreter.
    /// Used by LibraryDocsViewController.viewWillAppear to keep the
    /// libraries tab in sync with `pip install` / `pip uninstall`.
    func enumerateInstalledLibraries() -> [InstalledLibraryInfo] {
        let script = """
import importlib.metadata as _md
import json, os, sys

def _du(path):
    if not path or not os.path.isdir(path):
        return 0
    total = 0
    try:
        for root, _dirs, files in os.walk(path):
            if "__pycache__" in root:
                continue
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
    except OSError:
        pass
    return total

USER_SITE = os.path.expanduser("~/Documents/site-packages")
_codebench_pkgs = []
for dist in _md.distributions():
    try:
        meta = dist.metadata
        name = meta["Name"] or "?"
        version = dist.version
        summary = meta.get("Summary", "") or ""
        homepage = meta.get("Home-page", "") or ""
        try:
            loc = str(dist.locate_file("") or "")
        except Exception:
            loc = ""
        # Walk to the package's installed root for du.
        pkg_dir = ""
        try:
            files = list(dist.files or [])
            if files:
                pkg_dir = str(dist.locate_file(files[0])).rsplit("/", 1)[0]
        except Exception:
            pass
        if not pkg_dir:
            pkg_dir = loc
        size = _du(pkg_dir)
        is_user = bool(loc) and (USER_SITE in loc or "/Documents/site-packages" in loc)
        eps = []
        try:
            for ep in dist.entry_points:
                if ep.group == "console_scripts":
                    eps.append(ep.name)
        except Exception:
            pass
        try:
            requires = list(meta.get_all("Requires-Dist") or [])
        except Exception:
            requires = []
        _codebench_pkgs.append({
            "name": name,
            "version": version,
            "summary": summary[:200],
            "homepage": homepage,
            "location": loc,
            "is_user_installed": is_user,
            "size_bytes": size,
            "console_scripts": eps,
            "requires": requires[:20],
        })
    except Exception:
        continue
print("__CODEBENCH_INSTALLED__=" + json.dumps(_codebench_pkgs))
"""
        let result = execute(code: script)
        let output = result.output
        guard let markerRange = output.range(of: "__CODEBENCH_INSTALLED__=") else {
            return []
        }
        let jsonText = output[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry -> InstalledLibraryInfo? in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            return InstalledLibraryInfo(
                name: name,
                version: (entry["version"] as? String) ?? "?",
                summary: (entry["summary"] as? String) ?? "",
                homepage: (entry["homepage"] as? String) ?? "",
                location: (entry["location"] as? String) ?? "",
                isUserInstalled: (entry["is_user_installed"] as? Bool) ?? false,
                sizeBytes: (entry["size_bytes"] as? Int64) ?? 0,
                consoleScripts: (entry["console_scripts"] as? [String]) ?? [],
                requires: (entry["requires"] as? [String]) ?? []
            )
        }.sorted { lhs, rhs in
            // User-installed first (newest changes), then alphabetical.
            if lhs.isUserInstalled != rhs.isUserInstalled {
                return lhs.isUserInstalled && !rhs.isUserInstalled
            }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
    }

    private func executeSync(code: String) -> ExecutionResult {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ExecutionResult(output: "Python tool error: empty code.", imagePath: nil)
        }

        let execStart = Date()
        func elapsed() -> String { String(format: "%.2fs", Date().timeIntervalSince(execStart)) }

        do {
            if Py_IsInitialized() == 0 {
                print("[python] [\(elapsed())] Py not initialized, configuring environment...")
                try configureEnvironmentBeforeInitialize()

                // Set up a pseudo-terminal and dup2 it onto stdin/stdout/
                // stderr before Python opens its own file objects. This is
                // what makes pip, rich, tqdm, click, pytest etc. produce
                // proper output: `os.isatty(1)` returns True.
                PTYBridge.exportTTYEnv(cols: 80, rows: 24)
                PTYBridge.shared.setupIfNeeded()

                print("[python] [\(elapsed())] Calling Py_Initialize()...")
                Py_Initialize()
                guard Py_IsInitialized() != 0 else {
                    throw RuntimeError.message("Embedded Python failed to initialize. Check bundled runtime files.")
                }
                print("[python] [\(elapsed())] Py_Initialize() done, releasing GIL for thread safety...")

                // Redirect Python's sys.stdout and sys.stderr at the
                // PYTHON level — NOT at the C level via dup2.
                //
                // Why: iOS shares fd 1 and fd 2 across the whole process.
                //   • fd 1 — Swift print() writes here. If we dup2'd,
                //     every "[app] Returning to foreground" print from
                //     Swift would bleed into the user's terminal.
                //   • fd 2 — iOS os_log / WebKit write diagnostic msgs.
                //     If we dup2'd, OSLOG spam floods the terminal.
                //
                // Instead PTYBridge keeps the pipe write fd in
                // `stdoutPipeWriteFD` and we wrap it with os.fdopen at
                // the Python level. Swift print() stays on Xcode console;
                // only Python's sys.stdout / sys.stderr writes go to the
                // terminal.
                let pipeFD = PTYBridge.shared.stdoutPipeWriteFD
                let redirectStdioSource = """
                import sys, os, io
                try:
                    _fd = \(pipeFD)
                    if _fd >= 0:
                        _w = os.fdopen(_fd, 'w', buffering=1,
                                       encoding='utf-8', errors='replace',
                                       closefd=False)
                        sys.stdout = _w
                        sys.stderr = _w
                except Exception as _e:
                    import sys as _sys
                    _sys.__stderr__.write(f"[stdio redirect failed: {_e}]\\n")

                # Pre-warm platform.uname() — see ensureRuntimeReady for
                # the full explanation. Short version: iOS Python's
                # _ios_support.get_platform_ios() races on the shared
                # `objc.objc_msgSend.restype` attribute (c_void_p vs
                # c_char_p) when called concurrently from multiple
                # threads, intermittently crashing in _ctypes.z_get with
                # PAC failure. Forcing the call here on the bootstrap
                # thread populates platform._uname_cache so all later
                # callers hit the cache instead of re-entering ctypes.
                try:
                    import platform
                    platform.uname()
                except Exception as _e:
                    import sys as _sys
                    _sys.__stderr__.write(f"[bootstrap] uname pre-warm failed: {_e}\\n")
                """
                _ = redirectStdioSource.withCString { PyRun_SimpleString($0) }

                // After Py_Initialize the calling thread holds the GIL.
                // Release it so PyGILState_Ensure works correctly from any thread.
                let _ = PyEval_SaveThread()
                print("[python] [\(elapsed())] GIL released (SaveThread)")
            } else {
                print("[python] [\(elapsed())] Python already initialized")
            }

            // Start the interactive shell REPL on a background thread (idempotent).
            // Reads forever from sys.stdin (= PTY slave) so the user can
            // type into SwiftTerm and have their commands dispatched.
            PythonRuntime.startInteractiveShellIfNeeded()

            print("[python] [\(elapsed())] Acquiring GIL...")
            let gil = PyGILState_Ensure()
            defer {
                print("[python] [\(elapsed())] Releasing GIL")
                PyGILState_Release(gil)
            }
            print("[python] [\(elapsed())] GIL acquired")

            let globals = try mainGlobals()
            print("[python] [\(elapsed())] Configuring paths...")
            try configurePythonPathsIfNeeded(globals: globals)
            print("[python] [\(elapsed())] Paths configured")

            let toolDir = try ensureToolOutputDirectory()
            let encoded = Data(trimmed.utf8).base64EncodedString()
            try setGlobalString(encoded, key: "__codebench_code_b64", globals: globals)
            try setGlobalString(toolDir.path, key: "__codebench_tool_dir", globals: globals)

            // Pass manim quality settings
            let manimQuality = UserDefaults.standard.integer(forKey: "manim_quality") // 0=low, 1=med, 2=high
            let manimFPS = UserDefaults.standard.integer(forKey: "manim_fps")
            try setGlobalString(String(manimQuality), key: "__codebench_manim_quality", globals: globals)
            // Default matches Settings.manimFPS (15) so the FPS shown in the UI
            // is the FPS the render uses; the chosen value is honored downstream.
            try setGlobalString(String(manimFPS > 0 ? manimFPS : 15), key: "__codebench_manim_fps", globals: globals)
            // Experimental GPU (Metal) manim backend toggle (Settings). When on,
            // the manim setup swaps in the CairoMetal shim; any failure falls
            // back to CPU cairo, so this never breaks the default render path.
            let manimGPU = UserDefaults.standard.bool(forKey: "manim_gpu")
            try setGlobalString(manimGPU ? "1" : "0", key: "__codebench_manim_gpu", globals: globals)

            // Class-picker selection (set by execute(targetScene:)). "" /
            // "*" = render all detected Scene subclasses (legacy); a
            // bare class name = render only that one. We BAKE the value
            // directly into the wrapper source as a Python literal
            // rather than going through PyDict_SetItemString — the
            // dict-set + globals().get() chain has been observed to
            // return empty on the wrapper side under conditions that
            // never reproduce in isolation (race between the Swift
            // property store on the main thread, the queue dispatch,
            // and the wrapper read). Source-substitution sidesteps that
            // entirely: the value is part of the compiled bytecode.
            let pickedTarget = targetSceneForNextRun
            targetSceneForNextRun = ""
            let pickedScriptPath = scriptPathForNextRun
            scriptPathForNextRun = ""
            // Also push it into globals as a defensive backup so any
            // legacy code path that still reads the global keeps working.
            try setGlobalString(pickedTarget, key: "__codebench_target_scene", globals: globals)
            try setGlobalString(pickedScriptPath, key: "__codebench_script_path", globals: globals)
            let wrapperSource = Self.executionWrapperScript.replacingOccurrences(
                of: "__CODEBENCH_TARGET_SCENE_LITERAL__",
                with: pythonQuoted(pickedTarget))
                .replacingOccurrences(
                of: "__CODEBENCH_SCRIPT_PATH_LITERAL__",
                with: pythonQuoted(pickedScriptPath))

            print("[python] [\(elapsed())] Running wrapper script (code: \(trimmed.count) chars, picker=\(pickedTarget.isEmpty ? "<all>" : pickedTarget))...")
            try runStatements(wrapperSource, filename: "<offlinai-python-tool>")
            print("[python] [\(elapsed())] Wrapper script completed")

            print("[python] [\(elapsed())] Reading stdout...")
            let stdoutRaw = getGlobalString("__codebench_stdout", globals: globals)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = sanitizeToolStdout(stdoutRaw)
            let stderr = getGlobalString("__codebench_stderr", globals: globals)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var imagePath = getGlobalString("__codebench_plot_path", globals: globals)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("[python] [\(elapsed())] stdout=\(stdout.prefix(100)), stderr=\(stderr.prefix(200)), image=\(imagePath.prefix(80))")

            // Fallback path discovery — three layers, each independent of
            // Python globals. The wrapper's late assignment to
            // __codebench_plot_path doesn't survive to here for reasons we
            // haven't fully isolated (it's empty even though `[manim
            // rendered] /…` lines fire right after each set). Same goes
            // for __codebench_stdout sometimes. So we go straight to the
            // sources of truth.
            //
            // Layer 1: scan the captured stdout (cheapest, in-memory).
            // Layer 2: read the on-disk stream file directly (survives
            //          when __codebench_stdout is empty too).
            // Layer 3: walk the tool output directory and pick the most
            //          recently-modified video/image file (fully decoupled
            //          from Python — works even if both Python globals
            //          and the stream file are missing).
            // Track which fallback hit so we can surface it to the user
            // terminal (NSLog goes to Xcode console only — invisible in
            // log.txt). The string ends up in the diagnostic suffix on
            // result.output so the user sees `[fallback] ...` in the
            // terminal next to "$ Execution completed".
            var fallbackHitNote = ""
            // Diagnostic trail surfaced to the terminal so we can SEE
            // what every layer of the fallback chain found. Without this
            // a silent failure of all 3 layers manifests as just
            // "[output] No image path" with no clue why.
            var diagTrail: [String] = []

            let pathLooksUsable: (String) -> Bool = { p in
                !p.isEmpty && FileManager.default.fileExists(atPath: p)
            }
            diagTrail.append("[diag] global=\(imagePath.isEmpty ? "<empty>" : URL(fileURLWithPath: imagePath).lastPathComponent) usable=\(pathLooksUsable(imagePath))")

            // Treat an `imagePath` whose file is missing as "no path" so
            // the fallback dance still runs. This matters for manim,
            // which sometimes leaves __codebench_plot_path pointing at a
            // partial-frame .mp4 that gets unlinked when combine
            // produces the final combined_scenes.mp4.
            if !imagePath.isEmpty && !pathLooksUsable(imagePath) {
                imagePath = ""
            }

            if !pathLooksUsable(imagePath) {
                let scanned = Self.scanForLatestRenderedPath(in: stdoutRaw)
                diagTrail.append("[diag] stdoutRaw len=\(stdoutRaw.count), stdout-scan=\(scanned.isEmpty ? "<none>" : URL(fileURLWithPath: scanned).lastPathComponent)")
                if !scanned.isEmpty {
                    imagePath = scanned
                    fallbackHitNote = "[fallback] stdout-scan → \(URL(fileURLWithPath: scanned).lastPathComponent)"
                }
            }
            if !pathLooksUsable(imagePath) {
                let toolDir = (try? ensureToolOutputDirectory().path) ?? NSTemporaryDirectory()
                let streamFile = (toolDir as NSString).appendingPathComponent("_stream_stdout.txt")
                let streamExists = FileManager.default.fileExists(atPath: streamFile)
                if let streamData = FileManager.default.contents(atPath: streamFile),
                   let streamText = String(data: streamData, encoding: .utf8) {
                    let scanned = Self.scanForLatestRenderedPath(in: streamText)
                    diagTrail.append("[diag] streamFile exists=\(streamExists) len=\(streamText.count) scan=\(scanned.isEmpty ? "<none>" : URL(fileURLWithPath: scanned).lastPathComponent)")
                    if !scanned.isEmpty {
                        imagePath = scanned
                        fallbackHitNote = "[fallback] stream-file → \(URL(fileURLWithPath: scanned).lastPathComponent)"
                    }
                } else {
                    diagTrail.append("[diag] streamFile exists=\(streamExists) (no readable content)")
                }
            }
            if !pathLooksUsable(imagePath) {
                let toolDir = (try? ensureToolOutputDirectory().path) ?? NSTemporaryDirectory()
                // Constrain the dir-scan to media produced DURING this run
                // — otherwise a script that doesn't render anything (e.g.
                // a pywebview / requests / data-only run) used to surface
                // the previous manim video as if it were the new output.
                if let recent = Self.mostRecentMediaFile(
                    under: toolDir, modifiedSince: execStart) {
                    imagePath = recent
                    fallbackHitNote = "[fallback] dir-scan → \(URL(fileURLWithPath: recent).lastPathComponent)"
                    diagTrail.append("[diag] dir-scan(\(toolDir)) → \(URL(fileURLWithPath: recent).lastPathComponent)")
                } else {
                    diagTrail.append("[diag] dir-scan(\(toolDir)) → <none after \(execStart))")
                }
            }

            NSLog("[python] read-back __codebench_plot_path = %@", imagePath)

            var finalImagePath: String?
            if !imagePath.isEmpty, FileManager.default.fileExists(atPath: imagePath) {
                finalImagePath = imagePath
            } else if !imagePath.isEmpty {
                NSLog("[python] __codebench_plot_path set to %@ but FileManager.fileExists returned false", imagePath)
            }

            let plotOnlyStdout = Self.isPlotOnlyOutput(stdout, imagePath: finalImagePath)
            var sections: [String] = []
            if !stdout.isEmpty && !plotOnlyStdout {
                sections.append(stdout)
            }
            // Surface fallback-path-discovery hits to the user terminal
            // so log.txt makes it obvious which layer recovered the
            // preview path. Empty when no fallback was needed.
            if !fallbackHitNote.isEmpty {
                sections.append(fallbackHitNote)
            }
            // Surface the diagnostic trail when no preview path could be
            // recovered — gives the user a chance to figure out why
            // their render isn't surfacing in the preview panel.
            if finalImagePath == nil {
                sections.append(diagTrail.joined(separator: "\n"))
            }
            // Filter stderr: only include actual errors, not warnings
            if !stderr.isEmpty {
                let isWarningOnly = stderr.allSatisfy(\.isWhitespace)
                    || (stderr.contains("Warning") && !stderr.contains("Error") && !stderr.contains("Traceback"))
                let isActualError = stderr.contains("Traceback") || stderr.contains("Error") || stderr.contains("Exception")
                if isActualError {
                    sections.append("stderr:\n\(stderr)")
                } else if !isWarningOnly {
                    sections.append("stderr:\n\(stderr)")
                }
                // Print warnings to Xcode console but don't pollute tool output
                if !isActualError {
                    print("[python] warning (hidden from user): \(stderr.prefix(200))")
                }
            }

            if sections.isEmpty && finalImagePath == nil {
                sections.append("Python executed successfully (no output).")
            }
            return ExecutionResult(output: sections.joined(separator: "\n\n"), imagePath: finalImagePath)
        } catch {
            print("[python] [\(elapsed())] ERROR: \(error.localizedDescription)")
            return ExecutionResult(output: "Python tool error: \(error.localizedDescription)", imagePath: nil)
        }
    }

    /// Scan a blob of text for the LAST `[manim rendered] /…` marker and
    /// return the path it carries (if the file exists on disk). Returns
    /// "" when no usable marker is found. Used as a Swift-side fallback
    /// when the Python wrapper's `__codebench_plot_path` global doesn't
    /// reach us through `getGlobalString`.
    private static func scanForLatestRenderedPath(in text: String) -> String {
        let markers = ["[manim rendered] ", "[plot saved] "]
        let lines = text.components(separatedBy: "\n")
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for marker in markers {
                guard trimmed.hasPrefix(marker) else { continue }
                let candidate = String(trimmed.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces)
                guard candidate.hasPrefix("/"),
                      FileManager.default.fileExists(atPath: candidate) else { continue }
                return candidate
            }
        }
        return ""
    }

    /// Walk `dir` recursively and return the absolute path of the most
    /// recently-modified video/image file. Used as a last-resort fallback
    /// when neither the Python global nor the streamed stdout has yielded
    /// a render path. Bounded to typical render outputs (mp4 / gif / png /
    /// pdf) to avoid picking up source files or unrelated artifacts.
    private static func mostRecentMediaFile(under dir: String,
                                            modifiedSince: Date) -> String? {
        let extensions: Set<String> = ["mp4", "mov", "webm", "m4v", "gif", "png", "jpg", "jpeg", "pdf", "html"]
        let dirURL = URL(fileURLWithPath: dir)
        guard let enumerator = FileManager.default.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        // Reject anything older than `modifiedSince` MINUS a small grace
        // window. Without this, a Python script that produces no media
        // (e.g. a pywebview / requests / data-only run) silently surfaced
        // the LAST run's manim video because the dir-scan picked it up.
        // The grace window absorbs filesystem-mtime granularity (HFS+
        // tracks 1 s; APFS is finer but still not always sub-frame) and
        // any small clock skew between when execStart was captured and
        // when the script's first write actually completed.
        let cutoff = modifiedSince.addingTimeInterval(-1.0)
        var best: (String, Date)?
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  extensions.contains(url.pathExtension.lowercased()),
                  let modDate = values?.contentModificationDate,
                  modDate >= cutoff else { continue }
            // Prefer combined_scenes.mp4 / non-partial files over per-frame
            // partials. Skip anything inside a `partial_movie_files/` subdir
            // — those are fragments, not the final output.
            if url.path.contains("/partial_movie_files/") { continue }
            if let (_, prev) = best, prev >= modDate { continue }
            best = (url.path, modDate)
        }
        return best?.0
    }

    private static func isPlotOnlyOutput(_ stdout: String, imagePath: String?) -> Bool {
        guard imagePath != nil else { return false }
        let lines = stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return true }
        return lines.allSatisfy { line in
            line == "plt.show()"
                || line.hasPrefix("[plot saved]")
                || line.hasPrefix("[manim rendered]")
                || line == "None"
                || line == "Using built-in numpy compatibility layer."
                || line == "Using built-in matplotlib compatibility layer."
        }
    }

    private func sanitizeToolStdout(_ stdout: String) -> String {
        if stdout.isEmpty {
            return stdout
        }
        let lines = stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line == "plt.show()" { return false }
                if line.hasPrefix("[plot saved]") { return false }
                if line == "Using built-in numpy compatibility layer." { return false }
                if line == "Using built-in matplotlib compatibility layer." { return false }
                return true
            }
        return lines.joined(separator: "\n")
    }

    private func configurePythonPathsIfNeeded(globals: PyObjectPointer) throws {
        guard !pathsConfigured else { return }

        let bundleURL = Bundle.main.bundleURL
        let pythonLibRoot = bundleURL.appendingPathComponent("python/lib", isDirectory: true)
        guard let versionPath = firstPythonVersionPath(in: pythonLibRoot) else {
            throw RuntimeError.message("Python runtime not found in app bundle.")
        }

        let dynloadPath = URL(fileURLWithPath: versionPath).appendingPathComponent("lib-dynload", isDirectory: true).path
        let sitePackagesPath = bundleURL.appendingPathComponent("app_packages/site-packages", isDirectory: true).path
        let toolDir = try ensureToolOutputDirectory().path

        // User-installable site-packages — the App Group dir that equals
        // ~/Documents/site-packages once HOME is repointed, i.e. exactly where
        // pip injects its `--target`. Keeping it on sys.path here makes
        // pip-installed wheels importable. Ensure it exists.
        let userSitePath = AppPaths.userSitePackagesURL.path
        try? FileManager.default.createDirectory(atPath: userSitePath, withIntermediateDirectories: true)

        // Same pandas-on-path logic as in configureEnvironmentBeforeInitialize —
        // necessary on the runtime-init path too because Py_Initialize
        // may have already happened before the env var was read.
        let pandasDir = bundleURL.appendingPathComponent("pandas_ios/pandas-2.2.3", isDirectory: true).path
        let script = """
import os, sys
for _p in [\(pythonQuoted(versionPath)), \(pythonQuoted(dynloadPath)), \(pythonQuoted(sitePackagesPath)), \(pythonQuoted(pandasDir)), \(pythonQuoted(userSitePath))]:
    if _p and _p not in sys.path:
        sys.path.insert(0, _p)
os.environ.setdefault("MPLCONFIGDIR", \(pythonQuoted(toolDir)))
"""
        _ = globals
        try runStatements(script, filename: "<offlinai-python-paths>")
        pathsConfigured = true
    }

    private func configureEnvironmentBeforeInitialize() throws {
        guard !environmentConfigured else { return }

        let fileManager = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let pythonRoot = bundleURL.appendingPathComponent("python", isDirectory: true).path
        guard fileManager.fileExists(atPath: pythonRoot) else {
            throw RuntimeError.message("Bundled Python root is missing at \(pythonRoot).")
        }
        let pythonLibRoot = bundleURL.appendingPathComponent("python/lib", isDirectory: true)
        guard let versionPath = firstPythonVersionPath(in: pythonLibRoot) else {
            throw RuntimeError.message("Python runtime not found in app bundle.")
        }
        let encodingsDir = URL(fileURLWithPath: versionPath).appendingPathComponent("encodings", isDirectory: true).path
        let osModule = URL(fileURLWithPath: versionPath).appendingPathComponent("os.py").path
        guard fileManager.fileExists(atPath: encodingsDir), fileManager.fileExists(atPath: osModule) else {
            throw RuntimeError.message("Bundled Python stdlib is incomplete. Missing encodings/os.py under \(versionPath).")
        }

        let dynloadPath = URL(fileURLWithPath: versionPath).appendingPathComponent("lib-dynload", isDirectory: true).path
        let sitePackagesPath = bundleURL.appendingPathComponent("app_packages/site-packages", isDirectory: true).path
        // pandas is bundled separately under pandas_ios/pandas-X.Y.Z/
        // because the wheel has a hyphenated version dir name that
        // isn't importable. Add the parent dir of `pandas/` to
        // sys.path so `import pandas` works. The pandas dir lives
        // INSIDE `pandas_ios/pandas-2.2.3/` → that's the path on PATH.
        let pandasDir = bundleURL
            .appendingPathComponent("pandas_ios/pandas-2.2.3", isDirectory: true).path
        // User-installable site-packages — App Group dir == ~/Documents/site-packages
        // (HOME is repointed below), matching pip's injected --target so installs
        // resolve on sys.path.
        let userSitePath = AppPaths.userSitePackagesURL.path
        try? FileManager.default.createDirectory(atPath: userSitePath, withIntermediateDirectories: true)
        let pythonPath = [versionPath, dynloadPath, sitePackagesPath, pandasDir, userSitePath]
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        let toolDir = try ensureToolOutputDirectory().path

        // Point HOME at the shared App Group container (when provisioned) so
        // ~/Documents/Workspace resolves into it — keeping the Python side in
        // sync with the Files-app Location. No-op without the App Group.
        AppPaths.exportHomeEnvironment()
        setenv("PYTHONHOME", pythonRoot, 1)
        setenv("PYTHONPATH", pythonPath, 1)
        setenv("PYTHONNOUSERSITE", "1", 1)
        // Force UTF-8 mode. In Python 3.14 the default open()/stdio encoding
        // follows the C locale, which on iOS is ASCII — so user code doing
        // open(file) on a UTF-8 file dies with "'ascii' codec can't decode
        // byte 0xe2…". PYTHONUTF8=1 makes UTF-8 the default everywhere.
        setenv("PYTHONUTF8", "1", 1)
        setenv("PYTHONIOENCODING", "utf-8", 1)
        setenv("LANG", "en_US.UTF-8", 1)
        setenv("LC_CTYPE", "en_US.UTF-8", 1)
        // PYTHONDONTWRITEBYTECODE=0 + PYTHONPYCACHEPREFIX=<writable dir>
        // lets Python compile .py → .pyc and cache the result in
        // ~/Documents/.pycache/ (PEP 3147). The bundle's site-packages
        // is read-only so writing __pycache__ next to source files
        // fails silently; redirecting via PYTHONPYCACHEPREFIX moves
        // every cache entry to a single writable tree. Big win:
        // second-launch `import manim` drops from ~3 s to ~800 ms.
        setenv("PYTHONDONTWRITEBYTECODE", "0", 1)
        // Bytecode cache → a **Caches** dir, NOT Documents. Putting it in
        // Documents dropped a ~37 MB `.pycache` into the user-visible,
        // File-Provider-synced folder (and `ncdu` hid it as a dotdir, so it
        // looked like "missing" disk space). Caches is non-synced & purgeable.
        let pycBase = AppPaths.appGroupContainer
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let pycBase = pycBase {
            let pycPrefix = pycBase.appendingPathComponent("Library/Caches/pycache",
                                                           isDirectory: true).path
            try? FileManager.default.createDirectory(atPath: pycPrefix,
                                                     withIntermediateDirectories: true)
            setenv("PYTHONPYCACHEPREFIX", pycPrefix, 1)
        }
        // Sweep away any stale `.pycache` left in the old (Documents) spots so it
        // stops bloating the synced area.
        try? FileManager.default.removeItem(at: AppPaths.documentsURL
            .appendingPathComponent(".pycache", isDirectory: true))
        if let sandboxDocs = FileManager.default.urls(for: .documentDirectory,
                                                      in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: sandboxDocs
                .appendingPathComponent(".pycache", isDirectory: true))
        }
        setenv("MPLCONFIGDIR", toolDir, 1)

        // CRITICAL: force Python to use the system malloc for ALL
        // allocations instead of its own `pymalloc` arena allocator.
        //
        // Why: pymalloc keeps freed memory in a per-arena pool and
        // NEVER returns pages to the OS during a process's lifetime.
        // That means even after `gc.collect()` + explicit ref drops,
        // the kernel still sees our RSS as elevated, iOS jetsam
        // counts it against our budget, and a memory-heavy manim
        // scene leaves 3–7 GB of RSS "stuck" after it finishes even
        // though Python-visible objects are all dead.
        //
        // With `PYTHONMALLOC=malloc`, Python uses Darwin's system
        // malloc. Darwin DOES return freed pages on
        // `malloc_zone_pressure_relief()` (which we call from our
        // between-scene cleanup). End-to-end effect: after
        // scene.render() finishes + cleanup runs, RSS actually
        // drops back to baseline, visible to iOS, jetsam forgets.
        //
        // Cost: system malloc is slightly slower than pymalloc for
        // very small allocations — a few-percent overall. Acceptable
        // trade for not getting jetsam-killed at scene 2.
        //
        // Must be set BEFORE Py_Initialize; has no effect after.
        setenv("PYTHONMALLOC", "malloc", 1)

        // iOS's /tmp resolves to the system-owned /private/var/tmp which is
        // read-only for sandboxed apps. Point TMPDIR / TMP / TEMP at the
        // writable per-app container tmp so Python's tempfile.gettempdir(),
        // PIL's Image.save() default, pip's build cache etc. all work.
        let tmpDir = NSTemporaryDirectory()
        setenv("TMPDIR", tmpDir, 1)
        setenv("TMP",    tmpDir, 1)
        setenv("TEMP",   tmpDir, 1)

        environmentConfigured = true
    }

    private func ensureToolOutputDirectory() throws -> URL {
        if let cached = toolOutputDirectoryURL {
            return cached
        }
        // Inside the App Group Workspace so renders appear in the Files
        // Location. Detection still works — it keys off the "/ToolOutputs/"
        // path substring, which this nested path still contains.
        let outputURL = AppPaths.toolOutputsURL
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        toolOutputDirectoryURL = outputURL
        return outputURL
    }

    private func firstPythonVersionPath(in rootURL: URL) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let candidates = entries
            .filter { $0.lastPathComponent.hasPrefix("python") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return candidates.first?.path
    }

    private func mainGlobals() throws -> PyObjectPointer {
        guard let module = "__main__".withCString({ PyImport_AddModule($0) }) else {
            throw RuntimeError.message("Unable to load Python __main__ module.")
        }
        guard let globals = PyModule_GetDict(module) else {
            throw RuntimeError.message("Unable to access Python global dictionary.")
        }
        return globals
    }

    private func runStatements(_ source: String, filename: String) throws {
        // Crash-proof GIL guard: every path to PyEval_EvalCode must hold
        // the GIL. On Mac "Designed for iPad" we've seen EXC_BAD_ACCESS
        // deep inside the evaluator; most commonly the culprit is a
        // missing GIL acquire on a background thread. Surface the bug as
        // a throwable error instead of a SIGBUS.
        if PyGILState_Check() == 0 {
            let who = Thread.current.description
            NSLog("[PythonRuntime] runStatements called without GIL on %@ " +
                  "(filename=%@, source.count=%d) — refusing to evaluate",
                  who, filename, source.count)
            throw RuntimeError.message(
                "Python evaluator called without GIL on \(who); " +
                "wrap the call in PyGILState_Ensure / Release.")
        }
        let compiled = source.withCString { sourcePointer in
            filename.withCString { filenamePointer in
                Py_CompileString(sourcePointer, filenamePointer, fileInputMode)
            }
        }
        guard let codeObject = compiled else {
            throw RuntimeError.message(currentPythonError() ?? "Failed to compile Python source.")
        }
        defer { Py_DecRef(codeObject) }

        let globals = try mainGlobals()
        // Breadcrumb: if PyEvK1al_EvalCode SIGBUSes (seen on Mac Designed-
        // for-iPad when an iOS-built C extension fails to properly load
        // its dylib and stores a stale function pointer), this NSLog is
        // the last thing in Console.app — tells us which source was the
        // trigger.
        NSLog("[PythonRuntime] evaluating %@ (%d chars)", filename, source.count)
        guard let result = PyEval_EvalCode(codeObject, globals, globals) else {
            throw RuntimeError.message(currentPythonError() ?? "Failed to execute Python code.")
        }
        Py_DecRef(result)
    }

    private func setGlobalString(_ value: String, key: String, globals: PyObjectPointer) throws {
        let pyValue = value.withCString { PyUnicode_FromString($0) }
        guard let pyValue else {
            throw RuntimeError.message(currentPythonError() ?? "Unable to convert Swift string for Python.")
        }
        defer { Py_DecRef(pyValue) }

        let status = key.withCString { keyPointer in
            PyDict_SetItemString(globals, keyPointer, pyValue)
        }
        if status != 0 {
            throw RuntimeError.message(currentPythonError() ?? "Unable to store Python runtime variable.")
        }
    }

    private func getGlobalString(_ key: String, globals: PyObjectPointer) -> String {
        let object = key.withCString { keyPointer in
            PyDict_GetItemString(globals, keyPointer)
        }
        guard let object else { return "" }
        return pythonString(from: object) ?? ""
    }

    private func pythonString(from object: PyObjectPointer) -> String? {
        var size: PySsizeT = 0
        if let utf8 = PyUnicode_AsUTF8AndSize(object, &size) {
            return String(cString: utf8)
        }
        guard let rendered = PyObject_Str(object) else {
            return nil
        }
        defer { Py_DecRef(rendered) }
        var renderedSize: PySsizeT = 0
        guard let utf8 = PyUnicode_AsUTF8AndSize(rendered, &renderedSize) else {
            return nil
        }
        return String(cString: utf8)
    }

    private func currentPythonError() -> String? {
        guard PyErr_Occurred() != nil else {
            return nil
        }
        var type: PyObjectPointer?
        var value: PyObjectPointer?
        var traceback: PyObjectPointer?
        PyErr_Fetch(&type, &value, &traceback)
        PyErr_NormalizeException(&type, &value, &traceback)
        defer {
            if let type { Py_DecRef(type) }
            if let value { Py_DecRef(value) }
            if let traceback { Py_DecRef(traceback) }
        }
        if let value, let text = pythonString(from: value), !text.isEmpty {
            return text
        }
        if let type, let text = pythonString(from: type), !text.isEmpty {
            return text
        }
        return "Unknown Python error."
    }

    private func pythonQuoted(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    private func pythonArrayLiteral(_ values: [String]) -> String {
        let encoded = values.map { pythonQuoted($0) }
        return "[\(encoded.joined(separator: ", "))]"
    }


    private static let executionWrapperScript = """
import base64, io, os, sys, time, traceback, uuid, warnings
warnings.filterwarnings("ignore", category=SyntaxWarning)
warnings.filterwarnings("ignore", category=DeprecationWarning)
__codebench_stdout = ""
__codebench_stderr = ""
__codebench_plot_path = ""
# Picker target — baked in as a Python literal by Swift at runtime
# (see PythonRuntime.swift `wrapperSource = ...replacingOccurrences`).
# This used to be `str(globals().get("__codebench_target_scene", ""))`
# but that path was unreliable: the global was observed empty here
# even when Swift's setGlobalString had successfully stored it,
# under conditions that never reproduced in isolation (race between
# the Swift main-thread property write, the dispatch queue boundary,
# and the wrapper read). Source-baked literal removes the entire
# cross-thread / cross-language data path.
_codebench_picker_target_locked = (__CODEBENCH_TARGET_SCENE_LITERAL__ or "").strip()
try:
    sys.__stderr__.write(
        f"[picker] entry locked = "
        f"{_codebench_picker_target_locked!r}\\n")
    sys.__stderr__.flush()
except Exception:
    pass
_t0 = time.time()
# On iOS there's no real tty — sys.__stderr__ may be broken (Errno 5).
# Use a StringIO log buffer that we can read later if needed.
_log_buf = io.StringIO()
def _log(msg):
    line = f"[py-exec] [{time.time()-_t0:.2f}s] {msg}"
    _log_buf.write(line + "\\n")
    try:
        sys.__stderr__.write(line + "\\n")
        sys.__stderr__.flush()
    except Exception:
        pass
_log("Decoding code...")
_offlinai_code = base64.b64decode(__codebench_code_b64.encode("utf-8")).decode("utf-8", "replace")
_log(f"Code decoded ({len(_offlinai_code)} chars)")

# Pre-load the Fortran I/O runtime stubs so scipy's ARPACK (and any other
# flang-compiled extension) can resolve `_Fortran*` symbols at dlopen time.
# The stubs live in the app bundle's Frameworks/ directory. Searching for
# it: iOS Python sys.path entries include the app bundle resource paths,
# so we scan them for anything that looks like the bundle root and build
# the Frameworks/libfortran_io_stubs.dylib path from there.
try:
    import ctypes
    import os as _os_stub
    _candidates = []
    # (1) Derive from entries of sys.path that point into the app bundle.
    # The wrap-loose-dylibs.sh build script wraps libfortran_io_stubs.dylib
    # as Frameworks/libfortran_io_stubs.framework/libfortran_io_stubs (App
    # Store requires .framework wrapping; loose .dylibs are rejected).
    # We try the new wrapped path first, then fall back to the old loose
    # path for builds that haven't run wrap-loose-dylibs.sh yet.
    for _p in sys.path:
        if _p and "CodeBench.app" in _p:
            _root = _p.split("CodeBench.app", 1)[0] + "CodeBench.app"
            # New (post-wrap) path: framework-wrapped binary
            _candidates.append(_os_stub.path.join(
                _root, "Frameworks",
                "libfortran_io_stubs.framework",
                "libfortran_io_stubs"))
            # Old (pre-wrap) path: loose dylib in Frameworks/
            _candidates.append(_os_stub.path.join(
                _root, "Frameworks", "libfortran_io_stubs.dylib"))
            break
    # (2) Fallbacks via dyld's @rpath / @executable_path search
    _candidates += [
        "@rpath/libfortran_io_stubs.framework/libfortran_io_stubs",
        "@rpath/libfortran_io_stubs.dylib",
        "@executable_path/Frameworks/libfortran_io_stubs.framework/libfortran_io_stubs",
        "libfortran_io_stubs.dylib",
    ]
    _loaded = False
    _errs = []
    for _candidate in _candidates:
        try:
            ctypes.CDLL(_candidate, mode=ctypes.RTLD_GLOBAL)
            _log(f"pre-loaded fortran IO stubs from {_candidate}")
            _loaded = True
            break
        except OSError as _e:
            _errs.append(f"{_candidate}: {_e}")
    if not _loaded:
        # Only surface this to the user's terminal if it actually
        # matters (scipy arpack / propack fail without the stubs).
        _log("fortran IO stubs preload failed; scipy arpack/propack will crash")
        _log(f"tried {len(_candidates)} paths:")
        for _e in _errs[:4]:
            _log(f"  {_e}")
except Exception as _fe:
    _log(f"fortran IO stubs preload skipped: {type(_fe).__name__}: {_fe}")

# Streaming stdout/stderr — writes to file immediately so Swift can poll
class _StreamWriter:
    def __init__(self, path):
        self._buf = io.StringIO()
        self._f = open(path, 'w', encoding='utf-8') if path else None
    def write(self, s):
        if s:
            # Click (streamlit's dep), and some other libs that go
            # through binary-stream APIs, can hand us bytes. Decode so
            # the underlying StringIO + utf-8 file handle don't choke
            # with `TypeError: string argument expected, got 'bytes'`.
            if isinstance(s, (bytes, bytearray)):
                try:
                    s = bytes(s).decode('utf-8', errors='replace')
                except Exception:
                    s = str(s)
            # Tolerate writes after close — happens when third-party libs
            # (transformers' logger, manim's pango warnings, etc.) emit
            # messages after the wrapper has finished and closed its file.
            # Without this guard every post-exit log emits `ValueError:
            # I/O operation on closed file.` via Python's logging module.
            try:
                self._buf.write(s)
            except (ValueError, OSError):
                pass
            if self._f:
                try:
                    self._f.write(s)
                    self._f.flush()
                except (ValueError, OSError):
                    pass
        return len(s) if s else 0
    def flush(self):
        if self._f:
            try:
                self._f.flush()
            except (ValueError, OSError):
                pass
    def getvalue(self):
        return self._buf.getvalue()
    def close(self):
        if self._f:
            self._f.close()
    def fileno(self):
        raise io.UnsupportedOperation("fileno")
    @property
    def encoding(self):
        return 'utf-8'
    def isatty(self):
        return True
    def readable(self):
        return False
    def writable(self):
        return True

_stream_dir = globals().get('__codebench_tool_dir', '')
_out_stream = _StreamWriter(os.path.join(_stream_dir, '_stream_stdout.txt') if _stream_dir else '')
_err_stream = _StreamWriter(os.path.join(_stream_dir, '_stream_stderr.txt') if _stream_dir else '')
_old_stdout, _old_stderr = sys.stdout, sys.stderr
sys.stdout, sys.stderr = _out_stream, _err_stream
try:
    # Import numpy and create SafeArray subclass so `if array:` never crashes
    _log("Importing numpy...")
    try:
        import numpy as np
        np.seterr(divide='ignore', invalid='ignore')

        # ndarray.__bool__ raises on multi-element arrays. We can't patch the
        # immutable builtin type, but we CAN subclass it. SafeArray.__bool__
        # falls back to .any(), and __array_finalize__ ensures ALL numpy ops
        # (ufuncs, slicing, arithmetic) propagate the subclass automatically.
        class SafeArray(np.ndarray):
            def __new__(cls, input_array):
                return np.asarray(input_array).view(cls)
            def __array_finalize__(self, obj):
                pass
            def __bool__(self):
                if self.size == 0: return False
                if self.size == 1: return bool(self.flat[0])
                return bool(self.any())
            def __and__(self, other):
                return np.bitwise_and(np.asarray(self), np.asarray(other)).view(SafeArray)
            def __or__(self, other):
                return np.bitwise_or(np.asarray(self), np.asarray(other)).view(SafeArray)
            # SafeArray is defined inside the runtime-init script, so its
            # __module__ is "__main__" with no stable import path. pickle
            # would record "__main__.SafeArray" and fail on unpickle (the
            # name doesn't exist there in user scripts). Streamlit's
            # @st.cache_data, joblib, multiprocessing.Queue, anything
            # that pickles a DataFrame hits this. Reduce as a plain
            # ndarray instead — round-trips through pickle losslessly,
            # just loses the SafeArray subclass identity (the runtime
            # re-applies the patch on next module import anyway).
            def __reduce__(self):
                return np.ndarray.__reduce__(self.view(np.ndarray))
            def __reduce_ex__(self, protocol):
                return np.ndarray.__reduce_ex__(self.view(np.ndarray), protocol)

        # Patch numpy functions ONCE so they return SafeArray.
        # Guard: skip if already patched (script re-runs per execution).
        if not getattr(np, '_offlinai_patched', False):
            np._offlinai_patched = True

            _np_creators = [
                'linspace', 'arange', 'zeros', 'ones', 'array', 'asarray',
                'empty', 'full', 'zeros_like', 'ones_like', 'empty_like',
                'full_like', 'logspace', 'geomspace', 'eye', 'identity',
                'diag', 'fromfunction', 'copy',
            ]
            for _fn_name in _np_creators:
                _orig = getattr(np, _fn_name, None)
                if _orig is None:
                    continue
                def _make_safe(_orig_fn):
                    def _wrapper(*a, **k):
                        r = _orig_fn(*a, **k)
                        if isinstance(r, np.ndarray) and type(r) is np.ndarray:
                            return r.view(SafeArray)
                        return r
                    _wrapper.__name__ = _orig_fn.__name__
                    return _wrapper
                setattr(np, _fn_name, _make_safe(_orig))

            # meshgrid returns a list of arrays
            _orig_meshgrid = np.meshgrid
            def _safe_meshgrid(*a, **k):
                results = _orig_meshgrid(*a, **k)
                return [r.view(SafeArray) if isinstance(r, np.ndarray) else r for r in results]
            np.meshgrid = _safe_meshgrid

            # random functions
            for _rng_name in ['rand', 'randn', 'random', 'uniform', 'normal', 'randint']:
                _orig_rng = getattr(np.random, _rng_name, None)
                if _orig_rng:
                    def _make_safe_rng(_orig_fn):
                        def _wrapper(*a, **k):
                            r = _orig_fn(*a, **k)
                            if isinstance(r, np.ndarray) and type(r) is np.ndarray:
                                return r.view(SafeArray)
                            return r
                        return _wrapper
                    setattr(np.random, _rng_name, _make_safe_rng(_orig_rng))

            _log(f"numpy {np.__version__} OK (SafeArray patched)")
        else:
            _log(f"numpy {np.__version__} OK (already patched)")
    except Exception as _e:
        _log(f"numpy failed: {_e}")

    # Import matplotlib (our plotly-backed package in site-packages/matplotlib/)
    _log("Importing matplotlib...")
    _plt = None
    try:
        import matplotlib
        import matplotlib.pyplot as _plt
        _log(f"matplotlib {matplotlib.__version__} OK")
    except Exception as _e:
        _log(f"matplotlib failed: {_e}")

    # CSS patch injected into every generated plotly HTML to make the chart
    # fill 100% of the WKWebView viewport — no fixed 420px heights, no cropped
    # bottoms.  The `!important` wins over Plotly's inline styles, and setting
    # html/body/wrapper to 100% gives the `.js-plotly-plot` div something to
    # expand into.
    __codebench_plotly_css = (
        "<style>"
        "html, body { margin:0 !important; padding:0 !important; width:100% !important; height:100% !important; overflow:hidden !important; background:transparent !important; }"
        "body > div:first-child { width:100% !important; height:100% !important; }"
        ".plotly-graph-div, .js-plotly-plot, .svg-container, .main-svg { width:100% !important; height:100% !important; }"
        "</style>"
        "<script>"
        "window.addEventListener('load', function() {"
        "  if (!window.Plotly) return;"
        "  function _fill() {"
        "    document.querySelectorAll('.js-plotly-plot').forEach(function(p) {"
        "      try { Plotly.Plots.resize(p); } catch (e) {}"
        "    });"
        "  }"
        "  _fill();"
        "  setTimeout(_fill, 80); setTimeout(_fill, 300);"
        "  window.addEventListener('resize', _fill);"
        "  if (window.ResizeObserver) new ResizeObserver(_fill).observe(document.body);"
        "});"
        "</script>"
    )

    def __codebench_save_plotly_html(_fig, _path):
        # Serialize a plotly figure as HTML that fills 100% of the viewport.
        # Strip locked pixel dimensions and enable autosize + responsive mode.
        try:
            _fig.update_layout(
                autosize=True,
                height=None,
                width=None,
                margin=dict(l=40, r=20, t=40, b=40),
            )
        except Exception:
            pass
        _fig.write_html(
            _path,
            include_plotlyjs=True,
            full_html=True,
            default_width="100%",
            default_height="100%",
            config={"responsive": True, "displayModeBar": False},
        )
        # Splice our CSS/JS override into <head>
        try:
            with open(_path, "r", encoding="utf-8") as _f:
                _html = _f.read()
            if "<head>" in _html:
                _html = _html.replace("<head>", "<head>" + __codebench_plotly_css, 1)
            else:
                _html = __codebench_plotly_css + _html
            with open(_path, "w", encoding="utf-8") as _f:
                _f.write(_html)
        except Exception as _e:
            _log(f"css splice failed: {_e}")

    # Hook matplotlib.pyplot.show to capture chart output
    if _plt and hasattr(_plt, '_show_hook'):
        def _offlinai_mpl_show(fig_obj=None):
            global __codebench_plot_path
            os.makedirs(__codebench_tool_dir, exist_ok=True)
            if fig_obj is not None and hasattr(fig_obj, 'write_html'):
                _path = os.path.join(__codebench_tool_dir, f"chart_{uuid.uuid4().hex[:8]}.html")
                _real_fig = getattr(fig_obj, '_fig', fig_obj)
                __codebench_save_plotly_html(_real_fig, _path)
                __codebench_plot_path = _path
                _log(f"chart saved: {_path}")
                print(f"[plot saved] {_path}", flush=True)
            else:
                _log("show() called but no plotly figure available")
        _plt._show_hook = _offlinai_mpl_show

    # Hook plotly.graph_objects.Figure.show directly.
    #
    # Catches AttributeError too — plotly.graph_objects uses lazy
    # __getattr__ to expose Figure/Scatter/etc. On an iOS build where
    # validators or some sub-module failed to initialize, the module
    # imports fine but accessing Figure raises AttributeError. That
    # used to bubble up and kill every script run (even ones that
    # don't touch plotly). Now we just skip the hook installation.
    try:
        import plotly.graph_objects as _pgo
        _Figure = getattr(_pgo, "Figure", None)
        if _Figure is None:
            _log("plotly loaded but Figure missing (iOS-stubbed build); skipping hook")
        else:
            _log("plotly OK")
            def _offlinai_plotly_show(self, *args, **kwargs):
                global __codebench_plot_path
                os.makedirs(__codebench_tool_dir, exist_ok=True)
                _path = os.path.join(__codebench_tool_dir, f"chart_{uuid.uuid4().hex[:8]}.html")
                # Clean numpy arrays for JSON serialization
                try:
                    import numpy as _npx
                    for trace in self.data:
                        for attr in ['x', 'y', 'z']:
                            val = getattr(trace, attr, None)
                            if val is not None and hasattr(val, 'tolist'):
                                arr = _npx.asarray(val, dtype=float).ravel()
                                trace[attr] = [None if not _npx.isfinite(v) else float(v) for v in arr]
                except Exception:
                    pass
                __codebench_save_plotly_html(self, _path)
                __codebench_plot_path = _path
                _log(f"plotly chart saved: {_path}")
                print(f"[plot saved] {_path}", flush=True)
            _Figure.show = _offlinai_plotly_show
    except (ImportError, AttributeError) as _plotly_hook_err:
        _log(f"plotly hook skipped: {type(_plotly_hook_err).__name__}: {_plotly_hook_err}")
    except Exception as _plotly_hook_err:
        _log(f"plotly hook crashed ({type(_plotly_hook_err).__name__}): skipping")

    # Set up fontconfig BEFORE importing manim, so manimpango's
    # __init__.py (triggered transitively by `import manim`) sees
    # FONTCONFIG_FILE and takes the native-Pango path. Native Pango
    # has FreeType linked and handles per-character font fallback for
    # CJK text; the pycairo fallback in this iOS build has no font
    # backend and can only draw basic Latin, so Chinese text is
    # invisible unless we get onto the native path.
    #
    # The actual font registration (manimpango.register_font) happens
    # AFTER import, which is fine — fontconfig is already set up and
    # Pango re-scans its app-font list on each layout call.
    try:
        _bundle_root = None
        for _p in sys.path:
            if "CodeBench.app" in _p:
                _bundle_root = _p.split("CodeBench.app", 1)[0] + "CodeBench.app"
                break
        _font_dir = None
        if _bundle_root:
            # Probe order:
            #   1. Subdir layouts that exist if KaTeX/ was added as a true
            #      folder reference (preserves structure).
            #   2. The bundle root itself — iOS .app's Resources convention
            #      flattens individual file references to the root, and
            #      that's where Xcode actually places these .ttf/.otf files
            #      in this project (see ls of CodeBench.app — KaTeX_*.ttf
            #      and NotoSans*-Regular.otf all sit alongside Info.plist).
            #   We pick the first dir that contains a sentinel font we know
            #   to be in the bundle (KaTeX_Main-Regular.ttf), so a stray
            #   empty 'katex/fonts/' from the build script doesn't hijack
            #   the lookup.
            for _rel in ("katex/fonts", "Frameworks/katex/fonts",
                         "KaTeX/fonts", "Frameworks/KaTeX/fonts", ""):
                _cand_dir = os.path.join(_bundle_root, _rel) if _rel else _bundle_root
                if os.path.isdir(_cand_dir) and os.path.exists(
                    os.path.join(_cand_dir, "KaTeX_Main-Regular.ttf")
                ):
                    _font_dir = _cand_dir
                    break
        if _font_dir:
            _fc_file_pre = os.path.join(__codebench_tool_dir, "fonts.conf")
            # CJK fallback order: Noto Sans SC has the broadest unified-Han
            # coverage (Simplified Chinese ⊃ most Traditional ideographs the
            # average user types), then Noto Sans JP for kana + Japanese-only
            # kanji, then Noto Sans KR for Hangul + Korean Hanja. Listed in
            # descending coverage so fontconfig finds a match for any CJK
            # codepoint without fanning out to expensive system scans.
            _prefer_pre = (
                "<family>KaTeX_Main</family>"
                "<family>Noto Sans SC</family>"
                "<family>Noto Sans JP</family>"
                "<family>Noto Sans KR</family>"
            )
            _fc_lines_pre = [
                "<fontconfig>",
                "  <dir>" + _font_dir + "</dir>",
                "  <cachedir>" + __codebench_tool_dir + "/fontcache</cachedir>",
                "  <alias><family>serif</family><prefer>" + _prefer_pre + "</prefer></alias>",
                "  <alias><family>sans-serif</family><prefer>" + _prefer_pre + "</prefer></alias>",
                "  <alias><family>sans</family><prefer>" + _prefer_pre + "</prefer></alias>",
                "  <alias><family>monospace</family><prefer>" + _prefer_pre + "</prefer></alias>",
                "  <alias><family>Times</family><prefer>" + _prefer_pre + "</prefer></alias>",
                "</fontconfig>",
                "",
            ]
            os.makedirs(f"{__codebench_tool_dir}/fontcache", exist_ok=True)
            with open(_fc_file_pre, "w") as _fcf_pre:
                _fcf_pre.write(chr(10).join(_fc_lines_pre))
            os.environ["FONTCONFIG_FILE"] = _fc_file_pre
            os.environ["FONTCONFIG_PATH"] = __codebench_tool_dir
            _log(f"[manim-font] fontconfig pre-wired: {_fc_file_pre}")
    except Exception as _fc_pre_err:
        _log(f"[manim-font] pre-import fontconfig setup failed: {_fc_pre_err}")

    # Experimental: GPU (Metal) cairo backend for manim, opt-in via the Settings
    # toggle. Swap the `cairo` module for the CairoMetal shim BEFORE manim imports
    # cairo. Reversible + safe: any failure falls back to the normal CPU cairo.
    if str(globals().get('__codebench_manim_gpu', '0')) == '1':
        try:
            import os as _os
            import cairo_metal as _cmetal
            _cmdir = _os.path.dirname(getattr(_cmetal, '__file__', '') or '')
            _cmml = _os.path.join(_cmdir, 'cairo_metal_runtime', 'default.metallib')
            if _os.path.exists(_cmml):
                _os.environ['CM_METALLIB'] = _cmml
            _cmsrc = _os.path.join(_cmdir, 'cairo_metal_runtime', 'fill.metal')
            if _os.path.exists(_cmsrc):
                _os.environ['CM_METAL_SRC'] = _cmsrc
            # Self-test gates activation: if the GPU can't render a test
            # pattern, fall back to CPU rather than produce a broken render.
            _ok, _dev, _ = _cmetal.gpu_selftest()
            if not _ok:
                raise RuntimeError("GPU init check did not pass")
            sys.modules['cairo'] = _cmetal
            globals()['__codebench_manim_gpu_active'] = True
            _log(f"[manim] GPU (Metal) rendering on {_dev}")
        except Exception as _gpe:
            globals()['__codebench_manim_gpu_active'] = False
            # Detail to the Xcode console only; the user-facing line avoids the
            # word "error" so a successful CPU render isn't flagged as failed.
            print(f"[manim] GPU unavailable ({type(_gpe).__name__}: {_gpe}); using CPU", flush=True)
            _log("[manim] GPU rendering not available - using CPU renderer")

    # Configure manim for iOS (if available)
    try:
        import manim
        _manim_run_id = uuid.uuid4().hex[:8]
        _manim_media = os.path.join(__codebench_tool_dir, f"manim_{_manim_run_id}")
        os.makedirs(_manim_media, exist_ok=True)
        manim.config.media_dir = _manim_media
        manim.config.renderer = "cairo"
        manim.config.format = "mp4"
        manim.config.write_to_movie = True
        manim.config.save_last_frame = False
        manim.config.preview = False
        manim.config.show_in_file_browser = False
        manim.config.disable_caching = True
        # Logger at ERROR so info-level chatter ("File ready at …",
        # caching messages, partial-movie listings) stays out of the
        # terminal. The default tqdm progress bar is left alone so the
        # user still sees per-animation progress while a long render
        # is running. Our own [manim-debug] / [diag] / [fallback]
        # prefixes are filtered to NSLog by the Swift terminal layer.
        manim.config.verbosity = "ERROR"
        # Quality presets. 0–4 use manim's built-in presets (each sets
        # pixel_width, pixel_height AND frame_rate together). 8K (idx 5) has no
        # built-in preset, so we set the pixels explicitly AND set frame_rate
        # explicitly — custom pixels alone would leave frame_rate at manim's
        # default, the gotcha the old code avoided by capping at 1080p. High-res
        # is now memory-safe via the capped/downsampled GIF buffer + frame
        # streaming + malloc pressure relief (ported from ManimStudio's 8K path).
        _mq = int(globals().get('__codebench_manim_quality', '0') or '0')
        _mfps = int(globals().get('__codebench_manim_fps', '0') or '0')
        if _mq == 5:
            manim.config.pixel_width = 7680
            manim.config.pixel_height = 4320
            manim.config.frame_rate = float(_mfps) if _mfps > 0 else 30.0
        else:
            _quality_map = {0: 'low_quality', 1: 'medium_quality',
                            2: 'high_quality', 3: 'production_quality',
                            4: 'fourk_quality'}
            manim.config.quality = _quality_map.get(_mq, 'low_quality')
            # Honor the FPS selector: manim's quality preset RESETS frame_rate to
            # its own default (15/30/60), so re-apply the chosen fps AFTER setting
            # quality -- otherwise the FPS setting silently does nothing for 0-4.
            if _mfps > 0:
                manim.config.frame_rate = float(_mfps)
        _log(f"manim quality idx={_mq} res={manim.config.pixel_width}x{manim.config.pixel_height} fps={manim.config.frame_rate}")

        # iOS: Pango segfaults in cairo_scaled_font_glyph_extents when the
        # fallback font ("Times 9.999") can't be resolved via fontconfig.
        # iOS has no system fonts.conf, so we generate a minimal one at
        # runtime pointing at our bundled katex/fonts/ directory, set
        # FONTCONFIG_FILE before Pango/manim touch anything, and ALSO call
        # manimpango.register_font() as a belt-and-braces measure.
        try:
            _bundle_root = None
            for _p in sys.path:
                if "CodeBench.app" in _p:
                    _bundle_root = _p.split("CodeBench.app", 1)[0] + "CodeBench.app"
                    break
            _log(f"[manim-font] bundle_root={_bundle_root}")
            _font_dir = None
            _font_path = None
            # All three Noto Sans CJK subset fonts the bundle may contain.
            # SC is required for Simplified Chinese; JP carries kana +
            # Japanese-only kanji; KR carries Hangul. We register every
            # one that's actually present so the build is forgiving if a
            # particular .otf is missing (e.g. fetch_cjk_fonts.sh hasn't
            # been run yet on a fresh checkout).
            _cjk_fonts = []  # list of (family_name_for_log, full_path)
            if _bundle_root:
                # Same probe order as the pre-import setup: prefer subdirs
                # if they exist, fall back to the bundle root itself (where
                # iOS Xcode actually places these flattened font files).
                # Sentinel match on KaTeX_Main-Regular.ttf to skip empty
                # katex/fonts/ scaffolding the build script may have made.
                for _rel in ("katex/fonts", "Frameworks/katex/fonts",
                             "KaTeX/fonts", "Frameworks/KaTeX/fonts", ""):
                    _cand_dir = os.path.join(_bundle_root, _rel) if _rel else _bundle_root
                    if not os.path.isdir(_cand_dir):
                        continue
                    _ttf = os.path.join(_cand_dir, "KaTeX_Main-Regular.ttf")
                    if not os.path.exists(_ttf):
                        continue
                    _font_dir = _cand_dir
                    _font_path = _ttf
                    for _label, _fname in (
                        ("Noto Sans SC", "NotoSansSC-Regular.otf"),
                        ("Noto Sans JP", "NotoSansJP-Regular.otf"),
                        ("Noto Sans KR", "NotoSansKR-Regular.otf"),
                    ):
                        _p = os.path.join(_cand_dir, _fname)
                        if os.path.exists(_p):
                            _cjk_fonts.append((_label, _p))
                    break
            _log(f"[manim-font] font_dir={_font_dir} latin={_font_path}")
            for _lbl, _p in _cjk_fonts:
                _log(f"[manim-font] cjk={_lbl} -> {_p}")
            # Keep _cjk_font_path defined for back-compat with later log lines.
            _cjk_font_path = _cjk_fonts[0][1] if _cjk_fonts else None

            if _font_dir:
                # Write a fonts.conf that maps Pango's default families to
                # KaTeX_Main (Latin coverage), with Noto Sans JP as the
                # automatic fallback for codepoints KaTeX can't render —
                # that's what gives us CJK support. Fontconfig walks the
                # <prefer> list in order and picks the first family that
                # has the glyph, so `serif` → tries KaTeX_Main first, falls
                # back to Noto Sans JP on Hanzi/Kanji/Kana.
                _fc_file = os.path.join(__codebench_tool_dir, "fonts.conf")
                _prefer = "<family>KaTeX_Main</family>"
                # Append every bundled CJK font as a fallback. Order =
                # descending unified-Han coverage so fontconfig finds the
                # cheapest match per codepoint: SC → JP → KR.
                for _lbl, _ in _cjk_fonts:
                    _prefer += f"<family>{_lbl}</family>"
                _lines = [
                    "<fontconfig>",
                    "  <dir>" + _font_dir + "</dir>",
                    "  <cachedir>" + __codebench_tool_dir + "/fontcache</cachedir>",
                    "  <alias><family>serif</family><prefer>" + _prefer + "</prefer></alias>",
                    "  <alias><family>sans-serif</family><prefer>" + _prefer + "</prefer></alias>",
                    "  <alias><family>sans</family><prefer>" + _prefer + "</prefer></alias>",
                    "  <alias><family>monospace</family><prefer>" + _prefer + "</prefer></alias>",
                    "  <alias><family>Times</family><prefer>" + _prefer + "</prefer></alias>",
                    "</fontconfig>",
                    "",
                ]
                _fc_content = chr(10).join(_lines)
                os.makedirs(f"{__codebench_tool_dir}/fontcache", exist_ok=True)
                with open(_fc_file, "w") as _fcf:
                    _fcf.write(_fc_content)
                os.environ["FONTCONFIG_FILE"] = _fc_file
                os.environ["FONTCONFIG_PATH"] = __codebench_tool_dir
                _log(f"[manim-font] wrote {_fc_file}")

            # Register both fonts with manimpango via direct path. The
            # Latin one keeps rendering LaTeX math and English text;
            # the CJK one lets `Text("中文")` find glyphs via fontconfig's
            # <prefer> fallback chain (or direct select_font_face in
            # the pycairo compat path, which picks it by family name).
            try:
                import manimpango as _mp
                if _font_path and hasattr(_mp, "register_font"):
                    _ok = _mp.register_font(_font_path)
                    _log(f"[manim-font] register_font latin = {_ok}")
                # Register every bundled CJK font with manimpango. This is
                # belt-and-braces alongside the fontconfig <prefer> chain:
                # Pango's fc_config picks up codepoint fallback automatically,
                # but register_font ensures direct family-name lookups
                # (e.g. Text("中文", font="Noto Sans SC")) work too.
                if hasattr(_mp, "register_font"):
                    for _lbl, _p in _cjk_fonts:
                        _ok2 = _mp.register_font(_p)
                        _log(f"[manim-font] register_font {_lbl} = {_ok2}")
                manim.config.font = "KaTeX_Main"
            except BaseException as _e2:
                _log(f"[manim-font] manimpango.register_font failed: {_e2}")
        except BaseException as _fe:
            import traceback as _tb
            _log(f"[manim-font] font setup crashed: {type(_fe).__name__}: {_fe}")
            _tb.print_exc()

        # Monkey-patch to capture frames → animated GIF (since ffmpeg unavailable)
        if not getattr(manim.Scene, '_offlinai_patched', False):
            _orig_render = manim.Scene.render
            # Also patch write_frame to collect frames for GIF
            from manim.scene.scene_file_writer import SceneFileWriter
            _orig_write_frame = SceneFileWriter.write_frame
            _collected_frames = []  # shared frame buffer (for the GIF output)
            # CAP + DOWNSAMPLE (ported from ManimStudio's 8K-safe path). Holding
            # every full-res frame as a PIL image is the dominant memory cost of a
            # render and OOM-kills the app at high resolution — this is why 4K+
            # used to be refused outright. The frames are ONLY used to assemble the
            # GIF (which is ~480px wide anyway), so we cap the count and downsample
            # at capture time, bounding GIF memory to a small constant regardless
            # of render resolution or scene length. Full-res frames still stream to
            # the mp4 via the original writer (never accumulated).
            _MAX_COLLECT = 240
            _GIF_MAX_W = 480

            def _capture_write_frame(self_fw, frame_or_renderer, num_frames=1):
                if len(_collected_frames) < _MAX_COLLECT:
                    try:
                        if isinstance(frame_or_renderer, np.ndarray):
                            frame = frame_or_renderer
                        elif hasattr(frame_or_renderer, 'get_frame'):
                            frame = frame_or_renderer.get_frame()
                        else:
                            frame = None
                        if frame is not None and frame.size > 0:
                            from PIL import Image as _PILImage
                            if frame.shape[-1] == 4:
                                img = _PILImage.fromarray(frame, 'RGBA').convert('RGB')
                            else:
                                img = _PILImage.fromarray(frame, 'RGB')
                            # Downsample at capture so we never hold full-res frames.
                            if img.width > _GIF_MAX_W:
                                _r = _GIF_MAX_W / img.width
                                img = img.resize((_GIF_MAX_W, int(img.height * _r)),
                                                 _PILImage.LANCZOS)
                            _collected_frames.append(img)
                    except Exception:
                        pass
                # Always run the original so the mp4 / save_last_frame PNG is written.
                try:
                    _orig_write_frame(self_fw, frame_or_renderer, num_frames)
                except Exception:
                    pass

            SceneFileWriter.write_frame = _capture_write_frame

            # GPU mode root-cause fix: CairoRenderer.get_frame() does
            # `np.array(self.camera.pixel_array)` — a COPY taken BEFORE write_frame
            # runs. Our GPU copy-back happened inside write_frame, i.e. AFTER that
            # snapshot, so the encoded copy stayed black even though the GPU drew.
            # Flush the GPU frame into camera.pixel_array BEFORE the snapshot.
            if str(globals().get('__codebench_manim_gpu', '0')) == '1':
                try:
                    from manim.renderer.cairo_renderer import CairoRenderer as _CR
                    if not getattr(_CR, '_offlinai_gpu_getframe', False):
                        _CR._offlinai_gpu_getframe = True
                        _orig_get_frame = _CR.get_frame
                        def _gpu_get_frame(self, _o=_orig_get_frame):
                            try:
                                sys.modules['cairo']._flush_all()
                            except Exception:
                                pass
                            return _o(self)
                        _CR.get_frame = _gpu_get_frame
                except Exception as _ge:
                    print(f"[manim] GPU get_frame hook not installed: {type(_ge).__name__}: {_ge}", flush=True)

            # --- temporary render profiler: shows where the render time goes ---
            # (low overhead: perf_counter around the key stages, summarized once
            #  at render end). Installed for both CPU and GPU so they compare.
            import time as _time
            globals().setdefault('__cb_prof', {})
            def _prof_wrap(_obj, _name, _key):
                _o = getattr(_obj, _name, None)
                if _o is None or getattr(_o, '_cb_prof', False):
                    return
                def _w(*a, **k):
                    _t = _time.perf_counter()
                    try:
                        return _o(*a, **k)
                    finally:
                        _pp = globals()['__cb_prof']
                        _pp[_key] = _pp.get(_key, 0.0) + (_time.perf_counter() - _t)
                _w._cb_prof = True
                setattr(_obj, _name, _w)
            try:
                from manim.camera.camera import Camera as _CamP
                _prof_wrap(_CamP, 'set_cairo_context_path', '1_path_build_geometry')
                _prof_wrap(_CamP, 'apply_fill', '2_fill')
                _prof_wrap(_CamP, 'apply_stroke', '3_stroke')
                from manim.renderer.cairo_renderer import CairoRenderer as _CRP2
                _prof_wrap(_CRP2, 'get_frame', '4_get_frame_and_gpu_copyback')
                from manim.scene.scene_file_writer import SceneFileWriter as _SFWP
                _prof_wrap(_SFWP, 'write_frame', '5_write_frame_encode')
                try:
                    import manimpango as _mpP
                    _prof_wrap(_mpP, 'text2svg', '0_pango_text2svg')
                except Exception:
                    pass
            except Exception as _pe:
                print(f"[manim] profiler install failed: {_pe}", flush=True)

            def _offlinai_manim_render(self, *args, **kwargs):
                global __codebench_plot_path
                import manim as _m
                # ── Pre-flight memory check ──────────────────────
                # The user reported renders at high quality crashing
                # the app via OOM jetsam EVEN AFTER our shell-builtin
                # pre-flight, because they invoke `scene.render()`
                # directly in Python — bypassing the `manim` builtin.
                # This monkey-patch IS the entry point for every
                # render path (auto-render and direct), so the check
                # belongs here.
                try:
                    import ctypes as _ct
                    _libsys = _ct.CDLL(None)
                    _avail_fn = getattr(_libsys, "os_proc_available_memory", None)
                    if _avail_fn is not None:
                        _avail_fn.restype = _ct.c_size_t
                        _avail = int(_avail_fn())
                        # Resolution-tiered peak-memory estimate. With frame
                        # streaming to ffmpeg + the capped/downsampled GIF buffer
                        # (write_frame patch above) + malloc pressure relief, even
                        # 4K/8K fit when there's enough headroom — so we no longer
                        # hard-refuse them; we only refuse if the device genuinely
                        # can't fit the per-frame working set (which is transient
                        # and freed each frame, so these are generous).
                        _h = int(getattr(_m.config, "pixel_height", 480) or 480)
                        _fps = int(getattr(_m.config, "frame_rate", 15) or 15)
                        if _h >= 4000:        # 8K
                            _need = 3 * 1024 * 1024 * 1024
                        elif _h >= 2000:      # 4K
                            _need = 2 * 1024 * 1024 * 1024
                        elif _h >= 1000:      # 1080p / 1440p
                            _need = 3 * 1024 * 1024 * 1024 if _fps >= 30 else 2 * 1024 * 1024 * 1024
                        elif _h >= 700:       # 720p
                            _need = 1024 * 1024 * 1024
                        elif _h >= 400:       # 480p
                            _need = 384 * 1024 * 1024
                        else:
                            _need = 200 * 1024 * 1024
                        if _avail and _need > _avail:
                            print(f"[manim] not enough memory for "
                                  f"{getattr(_m.config, 'pixel_width', '?')}x{_h}: "
                                  f"~{_need // (1024*1024)} MB needed but only "
                                  f"{_avail // (1024*1024)} MB free. Lower the "
                                  f"manim quality in Settings.",
                                  flush=True)
                            return
                except Exception:
                    pass
                _m.config.renderer = "cairo"
                _m.config.format = "mp4"
                _m.config.write_to_movie = True
                _m.config.save_last_frame = False
                _m.config.preview = False
                _m.config.disable_caching = True

                # ── Memory watchdog with FORCE-KILL ──────────────
                # When iOS-available memory drops below 150 MB,
                # the watchdog terminates the render workload
                # outright: inject SystemExit into every render/
                # encoder thread, force-close PyAV containers
                # (releases the videotoolbox IOSurface pool that
                # gc.collect cannot touch), drop manim modules,
                # and call malloc_zone_pressure_relief. The user
                # explicitly asked for "kill that process" when
                # memory is exceeded — this IS that kill.
                import threading as _wd_thr, time as _wd_time
                _wd_stop = _wd_thr.Event()
                _wd_killed = [False]
                def _hard_kill_render():
                    if _wd_killed[0]: return
                    _wd_killed[0] = True
                    try:
                        print(f"\\n[manim] memory watchdog FORCE-KILLING the "
                              f"render — terminating encoder threads and "
                              f"releasing IOSurface buffers.", flush=True)
                    except Exception: pass
                    import ctypes as _ck, gc as _gck, threading as _kth
                    # 1) Force-close PyAV / encoder / writer objects.
                    try:
                        _killers = ("close", "kill", "terminate",
                                    "release", "_close", "shutdown",
                                    "stop")
                        for _obj in _gck.get_objects():
                            _cls = type(_obj).__name__
                            if _cls in ("OutputContainer", "InputContainer",
                                        "VideoStream", "AudioStream",
                                        "CodecContext", "VideoCodecContext",
                                        "Stream", "SceneFileWriter",
                                        "Popen") or "Writer" in _cls:
                                for _m2 in _killers:
                                    _fn = getattr(_obj, _m2, None)
                                    if callable(_fn):
                                        try: _fn()
                                        except Exception: pass
                    except Exception: pass
                    # 2) SystemExit into every non-main, non-self thread.
                    try:
                        _api = _ck.pythonapi.PyThreadState_SetAsyncExc
                        _api.argtypes = [_ck.c_ulong, _ck.py_object]
                        _api.restype = _ck.c_int
                        _self_id = _kth.get_ident()
                        _main_id = _kth.main_thread().ident
                        for _t in _kth.enumerate():
                            if _t.ident in (_self_id, _main_id, None):
                                continue
                            if not _t.is_alive(): continue
                            for _ in range(2):
                                try: _api(_ck.c_ulong(_t.ident),
                                          _ck.py_object(SystemExit))
                                except Exception: pass
                    except Exception: pass
                    # 3) interrupt_main repeatedly.
                    try:
                        import _thread as _tt
                        for _ in range(5):
                            try: _tt.interrupt_main()
                            except Exception: pass
                    except Exception: pass
                    # 4) Drop modules + flush Cairo/Pango + malloc relief.
                    try:
                        _drop = ("manim", "manimlib", "manimpango",
                                 "moderngl", "av", "av.container",
                                 "av.codec", "av.stream", "av.video")
                        for _k in list(sys.modules):
                            if _k in _drop or any(_k.startswith(p + ".") for p in _drop):
                                sys.modules.pop(_k, None)
                        _gck.collect(); _gck.collect(); _gck.collect()
                        try:
                            _libc = _ck.CDLL(None)
                            _libc.malloc_zone_pressure_relief.argtypes = [_ck.c_void_p, _ck.c_size_t]
                            _libc.malloc_zone_pressure_relief.restype = _ck.c_size_t
                            _libc.malloc_zone_pressure_relief(None, 0)
                        except Exception: pass
                    except Exception: pass

                def _wd_loop():
                    import ctypes as _wc
                    try:
                        _libsys = _wc.CDLL(None)
                        _avail = getattr(_libsys, "os_proc_available_memory", None)
                        if _avail is None: return
                        _avail.restype = _wc.c_size_t
                    except Exception: return
                    _soft_at = 0.0
                    while not _wd_stop.wait(0.2):
                        try: _left = int(_avail())
                        except Exception: continue
                        if not _left: continue
                        _now = _wd_time.monotonic()
                        if _left < 250 * 1024 * 1024:
                            if not _soft_at:
                                _soft_at = _now
                                import _thread as _tt
                                try: _tt.interrupt_main()
                                except Exception: pass
                            if _left < 150 * 1024 * 1024 or _now - _soft_at > 1.0:
                                _hard_kill_render()
                                return
                _wd = _wd_thr.Thread(target=_wd_loop, daemon=True)
                _wd.start()
                # Log Pango status. `_pango_available` is set by our shim's
                # __init__.py; stock manimpango doesn't expose it, so default
                # to True (stock => always native).
                import manimpango as _mp
                _pango_ok = getattr(_mp, "_pango_available", True)
                if _pango_ok:
                    print("[manim] Pango: native rendering available")
                else:
                    print(f"[manim] Pango: pycairo compatibility mode ({getattr(_mp, '_pango_error', 'unknown')})")

                # iOS-specific: Pango falls back to 'Times 9.999' when no
                # font is available; on iOS fontconfig can't find Times,
                # so pango_layout returns NULL scaled_font and the render
                # segfaults. Register our bundled KaTeX_Main-Regular.ttf
                # and make it manim's default font to avoid the crash.
                try:
                    import os as _os_f, sys as _sys_f
                    _bundle_root = None
                    for _p in _sys_f.path:
                        if "CodeBench.app" in _p:
                            _bundle_root = _p.split("CodeBench.app", 1)[0] + "CodeBench.app"
                            break
                    _font_path = None
                    _cjk_font_path = None
                    if _bundle_root:
                        # The bundled folder is "KaTeX/fonts" (capital K),
                        # not lowercase "katex/fonts" — the lowercase entries
                        # below remain only as defensive fallbacks for older
                        # bundle layouts. The empty string "" probes the
                        # bundle root itself, where iOS Xcode flattens
                        # individual file references — that's actually
                        # where these .ttf/.otf land in this project.
                        # List capital-K subdirs first, then root.
                        for _rel in ("KaTeX/fonts",
                                     "Frameworks/KaTeX/fonts",
                                     "Frameworks/katex/fonts",
                                     "katex/fonts",
                                     ""):
                            _cand = _os_f.path.join(_bundle_root, _rel,
                                                    "KaTeX_Main-Regular.ttf")
                            if _os_f.path.exists(_cand):
                                _font_path = _cand
                                break
                        # Discover every bundled CJK font we can find. We
                        # register them ALL with manimpango — Pango's
                        # fontconfig fallback chain then picks per-codepoint
                        # so Hanzi → Noto Sans SC, kana → Noto Sans JP,
                        # Hangul → Noto Sans KR. List ordered by descending
                        # unified-Han coverage. Same dir layout as above.
                        _cjk_font_paths = []
                        for _rel in ("KaTeX/fonts",
                                     "Frameworks/KaTeX/fonts",
                                     "Frameworks/katex/fonts",
                                     "katex/fonts",
                                     ""):
                            _dir = _os_f.path.join(_bundle_root, _rel) if _rel else _bundle_root
                            if not _os_f.path.exists(_os_f.path.join(_dir, "KaTeX_Main-Regular.ttf")):
                                continue
                            for _cjk_name in ("NotoSansSC-Regular.otf",
                                              "NotoSansJP-Regular.otf",
                                              "NotoSansKR-Regular.otf"):
                                _cand = _os_f.path.join(_dir, _cjk_name)
                                if _os_f.path.exists(_cand):
                                    _cjk_font_paths.append(_cand)
                            break
                        # Keep _cjk_font_path defined (single path) for the
                        # legacy log line below. The new loop registers all.
                        _cjk_font_path = _cjk_font_paths[0] if _cjk_font_paths else None
                    if _font_path and hasattr(_mp, "register_font"):
                        _mp.register_font(_font_path)
                        print(f"[manim] registered font {_font_path}", flush=True)
                        # Make sure Text uses it by default
                        _m.config.font = "KaTeX_Main"
                        # Register every bundled CJK font — Pango's
                        # fontconfig fallback chain will pull from any
                        # registered font for codepoints the primary
                        # font can't render. The list may be empty on a
                        # build that didn't run scripts/fetch_cjk_fonts.sh.
                        for _cjkp in _cjk_font_paths:
                            try:
                                _mp.register_font(_cjkp)
                                print(f"[manim] registered CJK font {_cjkp}",
                                      flush=True)
                            except Exception as _cjke:
                                print(f"[manim] CJK font register failed for "
                                      f"{_cjkp}: {type(_cjke).__name__}: {_cjke}",
                                      flush=True)
                    else:
                        print(f"[manim] WARN: no bundled font found (root={_bundle_root})", flush=True)
                except Exception as _fe:
                    print(f"[manim] font registration failed: {type(_fe).__name__}: {_fe}", flush=True)
                _m.config.from_animation_number = 0
                _m.config.upto_animation_number = -1
                # Re-apply quality preset right before render to guarantee the
                # frame_rate/resolution survive any config churn during setup.
                # MUST mirror the 6-tier preset block above — a stale low/med/
                # high-only map here silently downgrades 1440p/4K/8K back to
                # low_quality (and resets 8K's explicit pixels to 480p), which
                # is exactly "selecting the manim quality does nothing".
                _q = int(globals().get('__codebench_manim_quality', '0') or '0')
                _qfps = int(globals().get('__codebench_manim_fps', '0') or '0')
                if _q == 5:
                    _m.config.pixel_width = 7680
                    _m.config.pixel_height = 4320
                    _m.config.frame_rate = float(_qfps) if _qfps > 0 else 30.0
                else:
                    _qmap = {0: 'low_quality', 1: 'medium_quality',
                             2: 'high_quality', 3: 'production_quality',
                             4: 'fourk_quality'}
                    _m.config.quality = _qmap.get(_q, 'low_quality')
                    # Re-apply the chosen FPS after the quality preset (which
                    # resets frame_rate) so the FPS selector actually takes effect.
                    if _qfps > 0:
                        _m.config.frame_rate = float(_qfps)
                _collected_frames.clear()
                # ── Render with guaranteed teardown ─────────────────
                # The user-reported symptom: when a render is killed
                # mid-way (MemoryError, KeyboardInterrupt from the
                # watchdog, encoder crash), the PyAV/videotoolbox
                # encoder's IOSurface buffers stay alive AND a
                # background frame-producer thread keeps churning
                # because Scene.render() raised before reaching its
                # own cleanup. The user sees: "RAM stays high until
                # the next process finishes."
                #
                # Force-close everything that holds GPU/IOSurface
                # state in a finally block — this runs no matter
                # what happens inside _orig_render, so a half-
                # finished render can't leave threads/buffers alive.
                # Capture the output-path info BEFORE the finally
                # clears self.renderer (the result-discovery block
                # below needs movie_file_path / image_file_path off
                # the file_writer, and once we tear down to free
                # IOSurface buffers those refs are gone).
                _captured_movie_path = None
                _captured_image_path = None
                try:
                    _orig_render(self, *args, **kwargs)
                    try:
                        _fwc = self.renderer.file_writer
                        _captured_movie_path = str(getattr(_fwc, "movie_file_path", "") or "") or None
                        _captured_image_path = str(getattr(_fwc, "image_file_path", "") or "") or None
                    except Exception: pass
                finally:
                    # Stop the watchdog FIRST so it can't fire
                    # interrupt_main into the next builtin / user
                    # script after this render returns.
                    try:
                        _wd_stop.set()
                        _wd.join(timeout=0.5)
                    except Exception: pass
                    try:
                        _renderer = getattr(self, "renderer", None)
                        _fw = getattr(_renderer, "file_writer", None) if _renderer else None
                        if _fw is not None:
                            # 1) Stop / drain the encoder. Manim's
                            # SceneFileWriter exposes finish() which
                            # flushes + closes the PyAV streams. Call
                            # it even if Scene.render already did, it's
                            # idempotent on a closed writer.
                            for _meth in ("close_partial_movie_stream",
                                          "finish_last_animation",
                                          "finish"):
                                _fn = getattr(_fw, _meth, None)
                                if callable(_fn):
                                    try: _fn()
                                    except Exception: pass
                            # 2) Drop direct refs to PyAV
                            # OutputContainer / VideoStream / encoder
                            # — these own the videotoolbox IOSurface
                            # pool. If we don't release them
                            # explicitly, gc has to wait for a cycle
                            # break that never comes (PyAV objects
                            # back-reference each other).
                            for _attr in (
                                "output_container", "video_stream",
                                "_output_container", "_video_stream",
                                "encoder", "writing_process",
                                "partial_movie_writer",
                                "current_writer",
                            ):
                                _obj = getattr(_fw, _attr, None)
                                if _obj is not None:
                                    for _close in ("close", "kill",
                                                   "terminate"):
                                        _cf = getattr(_obj, _close, None)
                                        if callable(_cf):
                                            try: _cf()
                                            except Exception: pass
                                    try: setattr(_fw, _attr, None)
                                    except Exception: pass
                        # 3) Drop renderer + camera which hold Cairo
                        # surfaces and the per-frame numpy buffer.
                        for _attr in ("camera", "renderer",
                                      "moving_mobjects", "mobjects"):
                            try:
                                _val = getattr(self, _attr, None)
                                if isinstance(_val, list):
                                    _val.clear()
                                else:
                                    setattr(self, _attr, None)
                            except Exception: pass
                    except Exception:
                        pass
                    # 4) Force GC + libmalloc page release so the
                    # Xcode memory graph drops NOW, not on the next
                    # script's exit. This is the same sequence run
                    # in the shell-builtin's finally; doing it here
                    # too means it lands no matter how the render
                    # was kicked off (auto-render, direct call, or
                    # CLI builtin).
                    try:
                        import gc as _gc, ctypes as _ct, ctypes.util as _cu
                        _gc.collect(); _gc.collect()
                        # Cairo / Pango global caches.
                        for _libname in ("libpangocairo-1.0.0.dylib",
                                         "libpangocairo-1.0.dylib"):
                            try:
                                _lpc = _ct.CDLL(_libname)
                                _lpc.pango_cairo_font_map_set_default(None)
                                break
                            except Exception: continue
                        for _libname in (_cu.find_library("cairo") or "libcairo.2.dylib",
                                         "libcairo.2.dylib"):
                            try:
                                _lc = _ct.CDLL(_libname)
                                _lc.cairo_debug_reset_static_data()
                                break
                            except Exception: continue
                        # Per-zone pressure relief — manimpango/numpy
                        # have their own zones in some builds.
                        _libc = _ct.CDLL(None)
                        try:
                            _libc.malloc_zone_pressure_relief.argtypes = [_ct.c_void_p, _ct.c_size_t]
                            _libc.malloc_zone_pressure_relief.restype = _ct.c_size_t
                            _libc.malloc_zone_pressure_relief(None, 0)
                        except Exception: pass
                    except Exception: pass
                print(f"[manim-debug] frames_written={len(_collected_frames)} skip={getattr(self.renderer, 'skip_animations', '?') if getattr(self, 'renderer', None) else '?'} sections_skip={getattr(self.renderer.file_writer.sections[-1], 'skip_animations', '?') if getattr(self, 'renderer', None) and hasattr(self.renderer, 'file_writer') and self.renderer.file_writer.sections else '?'}")
                _pp = globals().get('__cb_prof', {})
                if _pp:
                    _psum = "  ".join(f"{_k}={_v:.1f}s" for _k, _v in sorted(_pp.items()))
                    _log(f"[manim] PROFILE {_psum}")
                    print(f"[manim] PROFILE {_psum}", flush=True)
                try:
                    # Result discovery uses the paths captured BEFORE
                    # the teardown (self.renderer was cleared in the
                    # finally above to release IOSurface buffers).
                    _log(f"fw paths: movie={_captured_movie_path}, image={_captured_image_path}")
                    # 1. Check for mp4 video (PyAV + ffmpeg)
                    movie_path = _captured_movie_path
                    if movie_path and os.path.exists(movie_path) and os.path.getsize(movie_path) > 500:
                        __codebench_plot_path = movie_path
                        _log(f"manim MP4: {movie_path} ({os.path.getsize(movie_path)} bytes)")
                        print(f"[manim rendered] {movie_path}", flush=True)
                        _collected_frames.clear()
                        return
                    # 2. Fallback: assemble GIF from captured frames
                    if len(_collected_frames) >= 2:
                        from PIL import Image as _PILImage
                        gif_path = os.path.join(_m.config.media_dir, f"{type(self).__name__}.gif")
                        frames = _collected_frames
                        if len(frames) > 80:
                            step = len(frames) // 80
                            frames = frames[::step]
                        w, h = frames[0].size
                        if w > 480:
                            ratio = 480 / w
                            new_size = (480, int(h * ratio))
                            frames = [f.resize(new_size, _PILImage.LANCZOS) for f in frames]
                        fps = _m.config.frame_rate or 15
                        duration = max(int(1000 / fps), 33)
                        frames[0].save(gif_path, save_all=True, append_images=frames[1:], duration=duration, loop=0, optimize=True)
                        if os.path.exists(gif_path) and os.path.getsize(gif_path) > 100:
                            __codebench_plot_path = gif_path
                            _log(f"manim GIF: {gif_path} ({len(frames)} frames)")
                            print(f"[manim rendered] {gif_path}", flush=True)
                            _collected_frames.clear()
                            return
                    # 3. Fallback: static PNG
                    img_path = _captured_image_path
                    if img_path and os.path.exists(img_path):
                        __codebench_plot_path = img_path
                        _log(f"manim PNG: {img_path}")
                        print(f"[manim rendered] {img_path}", flush=True)
                    else:
                        latest = None
                        latest_t = 0
                        for root, dirs, files in os.walk(_m.config.media_dir):
                            for f in files:
                                if f.endswith(('.mp4', '.gif', '.png')):
                                    fpath = os.path.join(root, f)
                                    mt = os.path.getmtime(fpath)
                                    if mt > latest_t:
                                        latest = fpath
                                        latest_t = mt
                        if latest:
                            __codebench_plot_path = latest
                            _log(f"manim found: {latest}")
                            print(f"[manim rendered] {latest}", flush=True)
                except Exception as e:
                    _log(f"manim output error: {e}")
                _collected_frames.clear()

            manim.Scene.render = _offlinai_manim_render
            manim.Scene._offlinai_patched = True

        # ── Per-animation cleanup monkey-patch ────────────────────
        # Deliberately OUTSIDE the render-patch guard above. The
        # render patch is install-once; the Python runtime is
        # long-lived, so a prior run sets `_offlinai_patched = True`
        # and the render block is skipped on subsequent runs.
        # The play patch has its OWN guard so it installs exactly
        # once, independently of the render patch. If this were
        # nested like before, re-runs never got the play patch and
        # the `[splt] play #N` lines never appeared — which is
        # exactly the symptom we debugged.
        if not getattr(manim.Scene, "_offlinai_play_patched", False):
            _orig_play = manim.Scene.play
            _play_count = [0]   # cell so closure can bump it

            def _offlinai_play_with_cleanup(self, *_a, **_kw):
                try:
                    _r = _orig_play(self, *_a, **_kw)
                finally:
                    _play_count[0] += 1
                    # PER-PLAY cleanup is intentionally MINIMAL:
                    # only safe cache drops + RSS logging. The
                    # previous attempt ran gc.collect() and
                    # malloc_pressure_relief on every play, which
                    # raced with manim's SceneFileWriter writer
                    # thread (which can still be mid-write when
                    # play() returns) and crashed with
                    # EXC_BAD_ACCESS (0x137600000-style use-
                    # after-free). Heavy cleanup belongs in the
                    # BETWEEN-SCENE hook where the writer thread
                    # has been joined.
                    try:
                        import psutil as _pp
                        import manim as _pmx
                        # Safe: clear TeX/SVG string→mob dicts.
                        # `.clear()` only drops references; nothing
                        # else is iterating over these between plays.
                        for _path, _attr in (
                                (_pmx, '_tex_string_to_mob_map'),
                                (_pmx, '_tex_cache'),
                                (getattr(_pmx, 'mobject', None),
                                 '_tex_cache'),):
                            if _path is None:
                                continue
                            _c = getattr(_path, _attr, None)
                            if _c is not None and hasattr(_c, 'clear'):
                                try: _c.clear()
                                except Exception: pass

                        _n = _play_count[0]
                        # Use phys_footprint (what Xcode/jetsam see)
                        # not psutil.rss (undercounts by ~2x on iOS
                        # because it misses compressed / IOSurface /
                        # VideoToolbox encoder buffers).
                        _phys_mb = -1
                        try:
                            import ctypes as _tc
                            _lS = _tc.CDLL("/usr/lib/libSystem.dylib")
                            _b = (_tc.c_uint64 * 64)()
                            _cnt = _tc.c_uint32(_tc.sizeof(_b) // 4)
                            _lS.mach_task_self.restype = _tc.c_uint32
                            _lS.task_info.argtypes = [
                                _tc.c_uint32, _tc.c_uint32,
                                _tc.POINTER(_tc.c_uint64),
                                _tc.POINTER(_tc.c_uint32)]
                            _lS.task_info.restype = _tc.c_int
                            if _lS.task_info(_lS.mach_task_self(),
                                             22, _b,
                                             _tc.byref(_cnt)) == 0:
                                _phys_mb = int(_b[18]) // (1024*1024)
                        except Exception:
                            pass
                        _rss = int(_pp.Process().memory_info().rss
                                   // (1024*1024))
                        if _phys_mb > 0:
                            _log(f"[splt]   play #{_n}: "
                                 f"phys={_phys_mb}MB  rss={_rss}MB")
                        else:
                            _log(f"[splt]   play #{_n}: rss={_rss}MB")
                    except Exception:
                        pass
                return _r

            manim.Scene.play = _offlinai_play_with_cleanup
            manim.Scene._offlinai_play_patched = True
            _log("[manim] Scene.play patched with per-animation cleanup")

        # CJK-aware Text factory.
        #
        # The bundled pycairo has no FreeType/Quartz backend, so manim's
        # normal `Text('中文')` pipeline produces notdef boxes for any
        # non-Latin glyph — there's no way for Cairo to load our bundled
        # NotoSansJP. Sidestep that by intercepting the Text class at
        # the manim-module level (before any user `from manim import *`)
        # and, when the input has CJK codepoints, rasterize the text via
        # Pillow's FreeType (which IS linked into Pillow on iOS) and
        # return an `ImageMobject` instead of the SVG-derived VMobject.
        # Non-CJK strings still go through the original Text class so
        # LaTeX / English / math text is unaffected.
        # manimpango's text2svg now uses fontTools to extract OTF/TTF
        # glyph outlines directly, bypassing Cairo's toy API entirely.
        # That means CJK works the same way Latin does — read the cmap,
        # pull the bezier outline via SVGPathPen, emit <path> per glyph.
        # The only failure mode is fontTools not being importable (the
        # iOS bundle doesn't include the wheel). Probe for that, and
        # also confirm at least one registered font has both a CJK
        # codepoint AND a distinct outline for it (defense against
        # bundled font being a Latin-only subset).
        def _fonttools_can_extract_cjk():
            try:
                from fontTools.ttLib import TTFont
                from fontTools.pens.svgPathPen import SVGPathPen
            except ImportError:
                _log("[manim] fontTools not bundled — falling back to "
                     "PIL rasterizer for CJK")
                return False
            # Walk our font discovery probe order to confirm at least
            # one OTF in the bundle is a real CJK font.
            _candidate_fonts = []
            if _bundle_root:
                for _fname in ("NotoSansSC-Regular.otf",
                               "NotoSansJP-Regular.otf",
                               "NotoSansKR-Regular.otf"):
                    for _rel in ("KaTeX/fonts", "katex/fonts",
                                 "Frameworks/KaTeX/fonts",
                                 "Frameworks/katex/fonts", ""):
                        _dir = os.path.join(_bundle_root, _rel) if _rel else _bundle_root
                        _cand = os.path.join(_dir, _fname)
                        if os.path.exists(_cand):
                            _candidate_fonts.append(_cand)
                            break
            if not _candidate_fonts:
                _log("[manim] fontTools available but no CJK font "
                     "bundled — falling back to PIL rasterizer")
                return False
            for _fpath in _candidate_fonts:
                try:
                    _ttf = TTFont(_fpath, lazy=True, recalcBBoxes=False,
                                  recalcTimestamp=False)
                    _cmap = _ttf.getBestCmap()
                    if 0x4E2D not in _cmap or 0x56FD not in _cmap:
                        continue
                    _gs = _ttf.getGlyphSet()
                    _pen_a = SVGPathPen(_gs)
                    _pen_b = SVGPathPen(_gs)
                    _gs[_cmap[0x4E2D]].draw(_pen_a)  # 中
                    _gs[_cmap[0x56FD]].draw(_pen_b)  # 国
                    _da, _db = _pen_a.getCommands(), _pen_b.getCommands()
                    if (_da and _db and _da != _db
                            and len(_da) > 30 and len(_db) > 30):
                        _log(f"[manim] fontTools CJK probe OK: "
                             f"{os.path.basename(_fpath)} "
                             f"中={len(_da)}c 国={len(_db)}c")
                        return True
                except Exception as _e:
                    _log(f"[manim] fontTools probe error on "
                         f"{os.path.basename(_fpath)}: {_e}")
                    continue
            return False

        _cairo_cjk_ok = _fonttools_can_extract_cjk()
        _log(f"[manim] CJK extraction "
             f"{'via fontTools (real Write/Create stroke trace)' if _cairo_cjk_ok else 'unavailable — PIL-rasterize fallback'}")

        # The defensive ImageMobject shims below ALWAYS install (regardless
        # of the Cairo probe outcome) because LaTeX/BusyTeX, user code,
        # or any other path can still produce ImageMobjects inside a
        # VGroup. The PIL rasterizer + manim.Text replacement, on the
        # other hand, is gated on `not _cairo_cjk_ok` — when Cairo can
        # extract CJK paths natively, manim.Text runs unchanged so we
        # get real Write/Create stroke-trace animations on bezier curves.
        if not getattr(manim, "_offlinai_cjk_text_patched", False):
            _orig_Text = manim.Text
            _cjk_png_dir = os.path.join(_manim_media, "cjk_text")
            os.makedirs(_cjk_png_dir, exist_ok=True)

            def _has_cjk(s: str) -> bool:
                for _ch in s:
                    _cp = ord(_ch)
                    if (0x3000 <= _cp <= 0x30FF
                            or 0x3400 <= _cp <= 0x4DBF
                            or 0x4E00 <= _cp <= 0x9FFF
                            or 0xAC00 <= _cp <= 0xD7AF
                            or 0xF900 <= _cp <= 0xFAFF
                            or 0xFF00 <= _cp <= 0xFFEF):
                        return True
                return False

            def _cjk_factory(*args, **kwargs):
                # Accept either Text("中") or Text(text="中").
                text_arg = args[0] if args else kwargs.get("text", "")
                if not isinstance(text_arg, str) or not _has_cjk(text_arg):
                    return _orig_Text(*args, **kwargs)
                # Rasterize per-character into a VGroup of ImageMobjects.
                # This gives manim a multi-child target for animations
                # like Write / Create. Manim's animation.py has an iOS
                # image-fallback patch in `interpolate_mobject` that,
                # for any introducer/remover animation, walks the family
                # and ramps each ImageMobject's opacity per-child using
                # `self.get_sub_alpha(...)` — so Write's smart
                # `lag_ratio = min(4.0/N, 0.2)` produces a typewriter
                # reveal across these per-char children.
                #
                # Per-char PNGs are cached by (char, size, color, font),
                # so repeated renders / repeated runs in the same shell
                # only do PIL work for newly-seen glyphs.
                try:
                    from PIL import Image, ImageDraw, ImageFont
                    import hashlib, manim as _mm
                    _size_px = int(kwargs.get("font_size",
                                              _mm.DEFAULT_FONT_SIZE) * 2)
                    _color_str = str(kwargs.get("color", "WHITE"))
                    _color_rgba = (255, 255, 255, 255)
                    try:
                        _col = _mm.utils.color.ManimColor(_color_str)
                        _r, _g, _b = _col.to_rgb()
                        _color_rgba = (int(_r * 255), int(_g * 255),
                                       int(_b * 255), 255)
                    except Exception:
                        pass
                    # Find the best-matching bundled CJK font for this
                    # specific text. PIL ImageFont.truetype only takes
                    # ONE font (no per-glyph fallback), so we pick the
                    # font whose script most likely covers the string:
                    #   Hangul present → Noto Sans KR
                    #   Hiragana/Katakana present → Noto Sans JP
                    #   else (CJK Unified Ideographs only) → Noto Sans SC
                    # Each candidate is tried at every probable bundle
                    # location ("" = bundle root, where iOS flattens).
                    def _has_range(s, lo, hi):
                        return any(lo <= ord(_c) <= hi for _c in s)
                    if _has_range(text_arg, 0xAC00, 0xD7AF):
                        _preferred = ("NotoSansKR-Regular.otf",
                                      "NotoSansSC-Regular.otf",
                                      "NotoSansJP-Regular.otf")
                    elif _has_range(text_arg, 0x3040, 0x30FF):
                        _preferred = ("NotoSansJP-Regular.otf",
                                      "NotoSansSC-Regular.otf",
                                      "NotoSansKR-Regular.otf")
                    else:
                        _preferred = ("NotoSansSC-Regular.otf",
                                      "NotoSansJP-Regular.otf",
                                      "NotoSansKR-Regular.otf")
                    _font_file = None
                    if _bundle_root:
                        for _fname in _preferred:
                            for _rel in ("KaTeX/fonts", "katex/fonts",
                                         "Frameworks/KaTeX/fonts",
                                         "Frameworks/katex/fonts", ""):
                                _dir = os.path.join(_bundle_root, _rel) if _rel else _bundle_root
                                _cand = os.path.join(_dir, _fname)
                                if os.path.exists(_cand):
                                    _font_file = _cand
                                    break
                            if _font_file:
                                break
                    if _font_file is None:
                        print("[manim] CJK font not found; falling back to Text()",
                              flush=True)
                        return _orig_Text(*args, **kwargs)
                    _font = ImageFont.truetype(_font_file, _size_px)
                    # Per-character rasterization so the result is a
                    # VGroup of N ImageMobjects (one per char) instead
                    # of a single image. Combined with manim's iOS
                    # image-fallback in animation.py (which now staggers
                    # opacity by lag_ratio across image siblings),
                    # `Write(Text("中文"))` produces a typewriter reveal:
                    # Write's smart default `lag_ratio = min(4.0/N, 0.2)`
                    # makes char `i` fade in at `i * lag_ratio * run_time`,
                    # which is exactly what Write does on Latin VMobject
                    # children. No hardcoded values; the timing scales
                    # naturally with the string length.
                    _ascent, _descent = _font.getmetrics()
                    _line_h = max(1, _ascent + _descent)
                    _font_basename = os.path.basename(_font_file)
                    _char_pngs = []
                    # Swift triple-quoted strings expand \\n / \\r as literal
                    # newlines before Python parses the source — use chr()
                    # codes here to avoid string-literal corruption.
                    _NL_CHAR = chr(10)
                    _CR_CHAR = chr(13)
                    for _ch in text_arg:
                        if _ch == _NL_CHAR or _ch == _CR_CHAR:
                            # Manim multi-line CJK isn't supported here;
                            # collapse newlines to a wide blank space so
                            # the user at least sees a gap.
                            _ch_w = int(_size_px * 1.0)
                            _ch_key = f"_nl_{_size_px}"
                            _is_blank = True
                        elif _ch.isspace():
                            _ch_w = int(_size_px * 0.4)
                            _ch_key = f"_sp_{_size_px}"
                            _is_blank = True
                        else:
                            _ch_w = max(1, int(round(_font.getlength(_ch))))
                            _ch_key = hashlib.sha256(
                                f"{_ch}|{_size_px}|{_color_rgba}|"
                                f"{_font_basename}".encode("utf-8")
                            ).hexdigest()[:16]
                            _is_blank = False
                        _ch_png = os.path.join(_cjk_png_dir,
                                               f"ch_{_ch_key}.png")
                        if not os.path.exists(_ch_png):
                            _ch_img = Image.new("RGBA",
                                                (_ch_w, _line_h),
                                                (0, 0, 0, 0))
                            if not _is_blank:
                                _ch_draw = ImageDraw.Draw(_ch_img)
                                _ch_draw.text((0, 0), _ch, font=_font,
                                              fill=_color_rgba)
                            _ch_img.save(_ch_png)
                        _char_pngs.append(_ch_png)
                    # Height in manim units — roughly match what Text()
                    # would produce for the same font_size.
                    _font_size_units = kwargs.get("font_size",
                                                  _mm.DEFAULT_FONT_SIZE)
                    _target_h = _font_size_units / 48.0
                    _vg = _mm.VGroup()
                    for _png_path in _char_pngs:
                        _imob = _mm.ImageMobject(_png_path)
                        _imob.scale_to_fit_height(_target_h)
                        _vg.add(_imob)
                    if len(_vg.submobjects) > 1:
                        _vg.arrange(_mm.RIGHT, buff=0)
                    elif len(_vg.submobjects) == 1:
                        # Single-char group: nothing to arrange.
                        pass
                    return _vg
                except BaseException as _ce:
                    print(f"[manim] CJK rasterize failed: {type(_ce).__name__}: {_ce} — falling back to Text()",
                          flush=True)
                    return _orig_Text(*args, **kwargs)

            # Only swap manim.Text for the PIL rasterizer when Cairo can't
            # extract CJK paths natively. With native Cairo extraction,
            # manim.Text → manimpango.text2svg → SVG <path d="..."/> per
            # glyph → SVGMobject (real VMobject with bezier curves), and
            # Write/Create trace strokes the way desktop manim does.
            if not _cairo_cjk_ok:
                manim.Text = _cjk_factory
                _log("[manim] CJK-aware Text factory installed (PIL rasterize)")
            else:
                _log("[manim] manim.Text left native — fontTools extracts CJK paths")
            manim._offlinai_cjk_text_patched = True

            # Make VGroup accept ImageMobject children. Our CJK Text
            # factory returns ImageMobject (rasterized via Pillow, since
            # Cairo can't load CJK fonts on iOS), but user scripts do
            # `VGroup(text1, text2, …)` which raises TypeError because
            # VGroup.add() only accepts VMobject. Route non-VMobject
            # adds through the base Mobject.add instead — positioning /
            # fade / scale / shift all still work on mixed groups. The
            # one operation that doesn't is per-vertex `Transform()`
            # between a VMobject and an ImageMobject, which would need
            # vector outlines neither side has anyway.
            try:
                _VGroup = manim.VGroup
                _ImageMobject = manim.ImageMobject
                if not getattr(_VGroup, "_offlinai_accepts_image_mobject", False):
                    _orig_VGroup_add = _VGroup.add
                    def _cjk_tolerant_add(self, *mobjects):
                        vmobs = []
                        others = []
                        for m in mobjects:
                            if isinstance(m, _ImageMobject):
                                others.append(m)
                            else:
                                vmobs.append(m)
                        if vmobs:
                            _orig_VGroup_add(self, *vmobs)
                        if others:
                            # Bypass `VGroup._assert_valid_submobjects`
                            # entirely — appending to `submobjects`
                            # directly is exactly what `Mobject.add`
                            # does after its type check, so every
                            # downstream group op (shift/scale/fade/
                            # animate) still works on the mixed set.
                            for _m in others:
                                if _m is self:
                                    continue
                                if _m not in self.submobjects:
                                    self.submobjects.append(_m)
                        return self
                    _VGroup.add = _cjk_tolerant_add
                    _VGroup._offlinai_accepts_image_mobject = True
                    _log("[manim] VGroup patched to accept ImageMobject")

                # Give ImageMobject a `get_anchors` so that VGroup ops
                # that walk the family (arrange / center / get_center /
                # get_critical_point / get_points_defining_boundary)
                # see the image's four corner points as its boundary
                # contribution. Without this, mixed VGroups raise
                # `AttributeError: ImageMobject has no attribute
                # 'anchors'` as soon as you call `.arrange()`.
                if "_offlinai_has_get_anchors" not in _ImageMobject.__dict__:
                    def _image_get_anchors(self):
                        try:
                            _pts = self.points
                            if _pts is not None and len(_pts):
                                return _pts
                        except Exception:
                            pass
                        import numpy as _np_local
                        return _np_local.zeros((0, 3))
                    _ImageMobject.get_anchors = _image_get_anchors
                    _ImageMobject._offlinai_has_get_anchors = True
                    _log("[manim] ImageMobject.get_anchors shim installed")

                # VMobject-style setters that VGroup.set_fill / set_stroke
                # / set_color etc. propagate to EVERY submobject. On a
                # real ImageMobject these attributes don't exist, so
                # Mobject.__getattr__ generates a stub that takes only
                # (self, value) — then VGroup passes (color, opacity,
                # family) and we get "takes 2 positional arguments but
                # 4 were given". No-ops are safe because images don't
                # have vector fill/stroke; fade/transparency still works
                # via set_opacity (which ImageMobject provides natively).
                # Same __dict__ guard as below: Mobject.__getattr__
                # auto-generates attrs, so hasattr / getattr would falsely
                # report this flag as present.
                if "_offlinai_has_vmobject_setters" not in _ImageMobject.__dict__:
                    def _image_noop_setter(*_args, **_kwargs):
                        return _args[0] if _args else None
                    for _name in ("set_fill", "set_stroke",
                                  "set_background_stroke",
                                  "set_sheen", "set_sheen_direction",
                                  "set_shade_in_3d",
                                  "set_stroke_color", "set_fill_color",
                                  "match_style",
                                  "pointwise_become_partial",
                                  "set_anchors_and_handles"):
                        # Cannot use hasattr() to guard here: Mobject's
                        # __getattr__ auto-generates a 2-arg setter on
                        # demand for any unknown attribute, so hasattr()
                        # always returns True. That auto-setter is exactly
                        # the one that breaks VGroup.set_fill propagation
                        # (it calls `submobject.set_fill(color, opacity,
                        # family)` — 3 args — but the auto-setter only
                        # accepts 1). Use __dict__ to check if WE'VE
                        # explicitly defined the method on the class
                        # itself, and if not, install our flexible no-op.
                        if _name not in _ImageMobject.__dict__:
                            setattr(_ImageMobject, _name, _image_noop_setter)
                    # VMobject-style scalar attrs. manim's get_X
                    # auto-getter does `getattr(self, 'X')` and raises
                    # AttributeError if absent (e.g. get_stroke_width
                    # → stroke_width). Giving ImageMobject sensible
                    # defaults makes `Write`, `DrawBorderThenFill`,
                    # `ShowCreation` etc. see a no-stroke / no-fill
                    # vector — they then skip the outline phase for
                    # this child without crashing the whole render.
                    for _name, _default in (
                            ("stroke_width", 0.0),
                            ("background_stroke_width", 0.0),
                            ("fill_opacity", 1.0),
                            ("stroke_opacity", 0.0),
                            ("background_stroke_opacity", 0.0),
                            ("sheen_factor", 0.0),
                            ("sheen_direction", None),
                            ("fill_color", None),
                            ("stroke_color", None),
                            ("background_stroke_color", None),
                            ("n_points_per_curve", 1)):
                        if not hasattr(_ImageMobject, _name):
                            setattr(_ImageMobject, _name, _default)
                    _ImageMobject._offlinai_has_vmobject_setters = True
                    _log("[manim] ImageMobject VMobject shims installed")

                # ───────────────────────────────────────────────────
                # Stroke-trace animations (Write / Create / etc.) need
                # vector outlines. When the user writes Write(Text("中文"))
                # our CJK shim returns an ImageMobject — the existing
                # VMobject scalar-attr defaults (stroke_width=0,
                # fill_opacity=1) make these animations a NO-OP on the
                # image, which the user perceives as "the text never
                # appears" or "appears instantly at the end".
                #
                # Re-route the common stroke-trace animations to FadeIn
                # (and Unwrite/Uncreate to FadeOut) when the entire
                # animation target is ImageMobject-only. Mixed VMobject +
                # ImageMobject targets fall through to the original
                # animation — its stroke phase still works on the
                # VMobject children, and the ImageMobject children skip
                # their outline (handled by the no-op setters above).
                #
                # Implementation: rebind __class__ on the animation
                # instance during __init__ to the fallback class, then
                # call its __init__ with the original args. All manim
                # Animation subclasses share the same memory layout
                # (no __slots__), so __class__ swap is well-defined.
                def _has_image_in_family(_m, _seen=None):
                    if _seen is None:
                        _seen = set()
                    _id = id(_m)
                    if _id in _seen:
                        return False
                    _seen.add(_id)
                    if isinstance(_m, _ImageMobject):
                        return True
                    for _c in getattr(_m, "submobjects", []) or []:
                        if _has_image_in_family(_c, _seen):
                            return True
                    return False

                def _all_image_in_family(_m, _seen=None):
                    if _seen is None:
                        _seen = set()
                    _id = id(_m)
                    if _id in _seen:
                        return True
                    _seen.add(_id)
                    _kids = getattr(_m, "submobjects", []) or []
                    if not _kids:
                        return isinstance(_m, _ImageMobject)
                    return all(_all_image_in_family(_c, _seen) for _c in _kids)

                # NOTE on stroke-trace animations (Write / Create / etc.):
                # We DON'T __class__-swap them to FadeIn here. Manim's
                # animation.py has an iOS image-fallback patch in
                # `interpolate_mobject` that, for any introducer or
                # remover animation, walks the family and ramps each
                # ImageMobject's opacity using `self.get_sub_alpha(...)` —
                # so the animation's OWN `lag_ratio` is honored. Write
                # computes a smart default (`min(4.0/N, 0.2)` for N
                # children) inside its `__init__`, which gives a
                # noticeable typewriter reveal across per-character
                # ImageMobject children of our CJK Text VGroup. Letting
                # Write run natively preserves that smart default;
                # swapping to FadeIn replaces it with FadeIn's lag=0.

                # Transform between two CJK Texts: manim's vertex
                # interpolation can't bridge ImageMobject → ImageMobject,
                # so substitute with FadeTransform (cross-fade). For
                # ReplacementTransform the API is identical (target
                # replaces source after the animation), so the same
                # substitution works.
                _FadeTransform = getattr(manim, "FadeTransform", None)
                def _patch_transform(_anim_cls, _label):
                    if _anim_cls is None or _FadeTransform is None:
                        return
                    if getattr(_anim_cls, "_offlinai_image_aware", False):
                        return
                    _orig_init = _anim_cls.__init__
                    def _new_init(_self, _mob_a, _mob_b=None, *_a, **_kw):
                        if (_mob_a is not None and _mob_b is not None
                                and _has_image_in_family(_mob_a)
                                and _has_image_in_family(_mob_b)):
                            _self.__class__ = _FadeTransform
                            _FadeTransform.__init__(_self, _mob_a, _mob_b,
                                                    *_a, **_kw)
                            return
                        _orig_init(_self, _mob_a, _mob_b, *_a, **_kw) \
                            if _mob_b is not None else \
                            _orig_init(_self, _mob_a, *_a, **_kw)
                    _anim_cls.__init__ = _new_init
                    _anim_cls._offlinai_image_aware = True
                    _log(f"[manim] {_label} → FadeTransform on ImageMobject pairs")

                for _n in ("Transform", "ReplacementTransform",
                           "TransformFromCopy"):
                    _patch_transform(getattr(manim, _n, None), _n)
            except Exception as _vge:
                _log(f"[manim] VGroup patch failed: {_vge}")
        _log("manim configured for iOS (Cairo → GIF animation)")
    except ImportError:
        _log("manim not available")
    except Exception as _me:
        _log(f"manim config error: {_me}")

    # Pre-import useful math modules so user code can use them
    import math
    import cmath
    from math import factorial, gcd, comb, perm, isqrt
    from fractions import Fraction
    try:
        import decimal
        from decimal import Decimal
    except ImportError:
        pass

    # Test helper for templates (avoids nested exec + try/except indentation issues)
    _offlinai_test_pass = 0
    _offlinai_test_fail = 0
    _offlinai_test_errors = []
    def _offlinai_test(name, fn):
        global _offlinai_test_pass, _offlinai_test_fail, _offlinai_test_errors
        try:
            fn()
            _offlinai_test_pass += 1
            print("  ok " + str(name))
        except Exception as _te:
            _offlinai_test_fail += 1
            _offlinai_test_errors.append((str(name), str(_te)[:100]))
            print("  FAIL " + str(name) + ": " + str(_te)[:80])

    # Auto-inject `from manim import *` so that scripts which reference
    # Scene / VGroup / Text / etc. without their own import still run.
    # Strategy: use tokenize to find *bare identifiers* in the user's code
    # and only auto-inject `from manim import *` if at least one of a
    # known manim-name set is referenced. Plain scripts (no manim usage)
    # pay zero cost. Scripts that do their own `from manim import ...` /
    # `import manim` take the user's import as-is (we don't touch).
    _has_manim_import = (
        'from manim' in _offlinai_code or
        'import manim' in _offlinai_code
    )
    _looks_like_manim = False
    if not _has_manim_import:
        import tokenize as _tk_manim, io as _io_manim
        _manim_names = frozenset((
            # Scene types
            'Scene', 'ThreeDScene', 'MovingCameraScene', 'ZoomedScene',
            'SpecialThreeDScene', 'VectorScene', 'LinearTransformationScene',
            # Mobject hierarchy
            'Mobject', 'VMobject', 'VGroup', 'Group',
            # Text + math
            'Text', 'MarkupText', 'Paragraph', 'MathTex', 'Tex', 'Title',
            'BulletedList', 'Code',
            # Shapes
            'Circle', 'Square', 'Triangle', 'Polygon', 'Rectangle',
            'RoundedRectangle', 'Line', 'DashedLine', 'Arrow', 'Vector',
            'DoubleArrow', 'Dot', 'Star', 'RegularPolygon', 'Arc',
            # Coordinate systems / graphs
            'NumberPlane', 'Axes', 'NumberLine', 'ValueTracker',
            'ComplexPlane', 'ThreeDAxes', 'Surface', 'BarChart',
            # Animations
            'Write', 'Create', 'DrawBorderThenFill', 'Unwrite', 'Uncreate',
            'FadeIn', 'FadeOut', 'Transform', 'ReplacementTransform',
            'GrowFromCenter', 'GrowFromEdge', 'GrowArrow', 'Indicate',
            'Rotate', 'Rotating', 'MoveToTarget', 'ApplyFunction',
            'LaggedStart', 'AnimationGroup', 'Succession', 'Wait',
        ))
        try:
            _names_in_code = {
                _tok.string
                for _tok in _tk_manim.generate_tokens(_io_manim.StringIO(_offlinai_code).readline)
                if _tok.type == _tk_manim.NAME
            }
            _looks_like_manim = bool(_manim_names & _names_in_code)
        except Exception:
            # Tokenize failed (e.g. syntax error in user code) — fall back
            # to the plain substring check, which is less precise but
            # avoids blocking the user's script on our detection bug.
            _looks_like_manim = any(
                _n in _offlinai_code for _n in _manim_names
            )

    if _looks_like_manim:
        try:
            exec('from manim import *', globals(), globals())
            _log("auto-injected `from manim import *` (user code references manim names)")
        except BaseException as _mi_err:
            _log(f"manim auto-import failed: {type(_mi_err).__name__}: {_mi_err}")
            print(f"[runtime] manim auto-import failed: {type(_mi_err).__name__}: {_mi_err}", flush=True)

    # ── Snapshot global names BEFORE executing user code ────────────
    # We use this to identify which Scene classes were actually DEFINED
    # by this run (not just leftover from a previous script in the same
    # long-lived interpreter). Without this, running e.g. pip_demo.py
    # after an earlier manim script would happily re-render that
    # earlier script's Scene class.
    # Snapshot CLASS IDENTITIES, not just names. The original code only
    # recorded `set(globals().keys())` and treated anything whose name was
    # already present as "stale" — but on a re-run of the same script,
    # `class MyScene(Scene):` *re-binds* the same name to a brand-new class
    # object, so the name isn't new even though the class is. That made
    # the second-and-later runs of the same script fail with
    # "<class> not found in [] — falling back to all scenes" and then
    # finding nothing to render.
    #
    # Mapping name → id() gives us the right signal: if the name's id
    # changed, the user freshly defined that class in this run.
    _globals_before_exec = set(globals().keys())
    _class_ids_before_exec = {
        _n: id(_v) for _n, _v in globals().items() if isinstance(_v, type)
    }

    # Editor "Run" parity with `python <file>` in the terminal: give the
    # script a real __file__ / sys.argv[0] / sys.path[0] (the literal is
    # substituted in from the saved file path, "" for an unsaved buffer).
    # Without this, os.path.abspath(__file__) raised NameError under Run even
    # though `python file.py` in the terminal worked.
    _cb_script_path = __CODEBENCH_SCRIPT_PATH_LITERAL__
    if _cb_script_path:
        import os as _cb_os, sys as _cb_sys
        globals()["__file__"] = _cb_script_path
        try:
            _cb_sys.argv = [_cb_script_path]
        except Exception:
            pass
        _cb_dir = _cb_os.path.dirname(_cb_script_path)
        if _cb_dir:
            # A script saved with the same name as an installed package -- e.g.
            # a Blender script saved as "bpy.py" -- must NOT shadow the real
            # site-packages module. The workspace dir reaches sys.path two ways:
            # its absolute path, and '' / '.' (which resolve to the cwd, which is
            # also the workspace). Drop EVERY such early entry, then re-add the
            # workspace at the TAIL so `import bpy` finds the bundled framework
            # while local sibling imports still resolve. Deliberate deviation
            # from `python <file>` sys.path[0] semantics: in an editor with a
            # rich bundled package set, accidental shadowing of an installed
            # package by a same-named script is far more common than intentional
            # override.
            try:
                _cb_rdir = _cb_os.path.realpath(_cb_dir)
            except Exception:
                _cb_rdir = _cb_dir
            _cb_keep = []
            for _cb_p in _cb_sys.path:
                _cb_drop = _cb_p in ("", ".", _cb_dir)
                if not _cb_drop:
                    try:
                        _cb_drop = _cb_os.path.realpath(_cb_p) == _cb_rdir
                    except Exception:
                        _cb_drop = False
                if not _cb_drop:
                    _cb_keep.append(_cb_p)
            _cb_keep.append(_cb_dir)
            _cb_sys.path[:] = _cb_keep

    # Execute user code
    _log("Executing user code...")
    exec(_offlinai_code, globals(), globals())
    _log("User code finished")

    # Headless bpy auto-preview: a desktop-style script that builds a scene but
    # never saves/renders shows nothing on iOS (there is no live viewport). If
    # bpy was imported and nothing was already emitted this run, open the
    # interactive 3D preview -- the same channel a `.blend` save / render uses.
    try:
        import sys as _cb_sys2
        if 'bpy' in _cb_sys2.modules and not __codebench_plot_path:
            import codebench_blend_view as _cb_cbv
            if _cb_cbv.autoshow():
                print("[bpy] auto-preview shown", flush=True)
    except Exception as _cb_e:
        import traceback as _cb_tb
        print("[bpy] auto-preview error: %r" % (_cb_e,), flush=True)
        _cb_tb.print_exc()

    # Auto-detect and render manim Scene subclasses if user didn't call render() manually.
    #
    # Two guards to avoid false positives:
    #   1. The user code must look like manim (import statement or
    #      `class X(Scene):` pattern). Caught by _looks_like_manim or
    #      a quick regex scan here.
    #   2. The Scene class must have been *defined or re-bound* in this
    #      run (i.e. its name wasn't in globals before we exec'd the
    #      user code).
    _user_defined_a_scene = False
    if _looks_like_manim or 'class ' in _offlinai_code and 'Scene' in _offlinai_code:
        _user_defined_a_scene = True

    if _user_defined_a_scene and not __codebench_plot_path:
        try:
            import manim as _manim_detect
            _scene_classes = []
            for _name, _obj in list(globals().items()):
                if not isinstance(_obj, type):
                    continue
                # "Defined or re-defined in this run" check — the name is
                # either brand-new (wasn't in globals pre-exec) OR its
                # bound object's id changed (rebinding via re-running
                # `class X(Scene):`). Either way it's a fresh class from
                # the current script, not a leftover from a previous run.
                _was_new_name = _name not in _globals_before_exec
                _was_rebound = (_name in _class_ids_before_exec
                                and _class_ids_before_exec[_name] != id(_obj))
                if not (_was_new_name or _was_rebound):
                    continue
                try:
                    _is_scene = issubclass(_obj, _manim_detect.Scene) and _obj is not _manim_detect.Scene
                except TypeError:
                    _is_scene = False
                if not _is_scene:
                    continue
                # Skip manim-internal names that snuck in via
                # `from manim import *` (we handle the re-export by
                # checking __module__ below).
                if (_obj.__module__ or "").startswith("manim."):
                    continue
                if _name.startswith('_'):
                    continue
                _scene_classes.append((_name, _obj))

            # ── Class-picker filter ─────────────────────────────────
            # Use the value LOCKED at wrapper entry (top of the script,
            # before user code or any other globals fiddling). The
            # original global `__codebench_target_scene` has been
            # observed empty here even when Swift set it — root cause
            # unclear. Reading from the locked-in copy is reliable.
            try:
                _picker_target = _codebench_picker_target_locked
            except NameError:
                _picker_target = ""
            if _picker_target and _picker_target != "*":
                _matched = [(n, c) for n, c in _scene_classes if n == _picker_target]
                if _matched:
                    print(f"[manim] Class picker: rendering "
                          f"'{_picker_target}' only "
                          f"(of {len(_scene_classes)} detected)",
                          flush=True)
                    _scene_classes = _matched
                else:
                    print(f"[manim] Class picker: '{_picker_target}' not "
                          f"found in {[n for n, _ in _scene_classes]} — "
                          f"falling back to all scenes",
                          flush=True)

            if _scene_classes:
                # Render every selected Scene class in definition order,
                # then stitch the outputs into a single MP4. With one
                # class selected, no stitch happens (single mp4 IS the
                # output). With many, we still produce one combined file
                # so the preview-panel contract holds (exactly one
                # `[manim rendered]` line → one video file).
                print(f"[manim] Auto-rendering {len(_scene_classes)} scene(s): "
                      f"{', '.join(n for n, _ in _scene_classes)}",
                      flush=True)

                _rendered_mp4s: list = []
                for _scene_name, _scene_cls in _scene_classes:
                    _log(f"Auto-rendering Scene: {_scene_name}")
                    print(f"[manim] → {_scene_name}...", flush=True)
                    # manim's `print_file_ready_message` sets
                    # `config["output_file"]` globally after every render.
                    # On the next scene, `SceneFileWriter.init_output_directories`
                    # sees that leftover value and reuses it as the output
                    # path — so scene #2, #3, … all overwrite scene #1's
                    # mp4. Reset through the dict setter (NOT `.output_file`
                    # — the property's `_set_dir` coerces Path-or-None weirdly,
                    # and earlier attempts used `_m` which wasn't in scope at
                    # this outer-loop nesting, silently swallowing the reset).
                    try:
                        _manim_detect.config["output_file"] = ""
                    except Exception as _re:
                        print(f"[manim] couldn't reset output_file: {_re}",
                              flush=True)
                    try:
                        _auto_scene = _scene_cls()
                        _auto_scene.render()
                        print(f"[manim] {_scene_name}.render() returned.", flush=True)
                        try:
                            _fw = getattr(_auto_scene, 'renderer', None)
                            _fw = getattr(_fw, 'file_writer', None)
                            _mp = str(getattr(_fw, 'movie_file_path', '') or '')
                            if _mp and os.path.exists(_mp) and os.path.getsize(_mp) > 500 \
                               and _mp not in _rendered_mp4s:
                                _rendered_mp4s.append(_mp)
                                print(f"[manim]   → captured {os.path.basename(_mp)} "
                                      f"({os.path.getsize(_mp)} bytes)",
                                      flush=True)
                            elif _mp in _rendered_mp4s:
                                print(f"[manim]   ! {_scene_name} wrote to "
                                      f"{os.path.basename(_mp)} which was "
                                      f"already captured — overwrite?",
                                      flush=True)
                        except Exception as _pe:
                            _log(f"couldn't locate {_scene_name} movie file: {_pe}")
                    except BaseException as _render_err:
                        import traceback as _tb
                        print(f"[manim] {_scene_name}.render() failed: "
                              f"{type(_render_err).__name__}: {_render_err}",
                              flush=True)
                        _tb.print_exc()

                    # ── Inter-scene cleanup hook ─────────────────────
                    # Manim holds mobject/camera/renderer state on the
                    # Scene instance AND in module-level caches.
                    # Without explicit teardown, each finished scene
                    # stays resident in RAM when the next starts, so
                    # a 3D-heavy scene pushes us to iOS jetsam by
                    # scene 2. Aggressive 6-step teardown + logging.
                    def _rss_mb():
                        # PHYS_FOOTPRINT in MB — what Xcode's gauge
                        # shows AND what iOS jetsam uses for kill
                        # decisions. psutil's .rss undercounts
                        # because it excludes compressed memory,
                        # IOSurface / VideoToolbox encoder buffers,
                        # and mmap'd video files — all of which DO
                        # count against our budget on Darwin. Read
                        # TASK_VM_INFO via Mach task_info and pull
                        # phys_footprint at the known offset.
                        try:
                            import ctypes as _tc
                            _libSys = _tc.CDLL("/usr/lib/libSystem.dylib")
                            # TASK_VM_INFO struct: 40 × uint64 is
                            # enough to cover up through
                            # `phys_footprint` at offset 144 bytes
                            # (18 × 8). Allocate 512 bytes to be
                            # safe across Darwin versions.
                            _buf = (_tc.c_uint64 * 64)()
                            _count = _tc.c_uint32(
                                _tc.sizeof(_buf) // 4)
                            _libSys.mach_task_self.restype = _tc.c_uint32
                            _libSys.task_info.argtypes = [
                                _tc.c_uint32,
                                _tc.c_uint32,
                                _tc.POINTER(_tc.c_uint64),
                                _tc.POINTER(_tc.c_uint32)]
                            _libSys.task_info.restype = _tc.c_int
                            _TASK_VM_INFO = 22
                            _rc = _libSys.task_info(
                                _libSys.mach_task_self(),
                                _TASK_VM_INFO,
                                _buf,
                                _tc.byref(_count))
                            if _rc != 0:
                                raise RuntimeError(f"task_info rc={_rc}")
                            # phys_footprint is the 19th uint64
                            # (index 18, 144-byte offset).
                            _phys = int(_buf[18])
                            return _phys // (1024 * 1024)
                        except Exception:
                            # Fallback to psutil's rss (undercounts
                            # but at least something) if Mach call
                            # fails.
                            try:
                                import psutil as _pu
                                return int(_pu.Process().memory_info().rss
                                           // (1024 * 1024))
                            except Exception:
                                return -1

                    def _avail_mb():
                        try:
                            import psutil as _pu
                            return int(_pu.virtual_memory().available
                                       // (1024 * 1024))
                        except Exception:
                            return -1

                    _rss_before = _rss_mb()
                    _log(f"[splt] scene '{_scene_name}' done: "
                         f"RSS={_rss_before}MB  avail={_avail_mb()}MB  "
                         f"— cleaning up")

                    # Step 1 — break the scene's big attribute refs,
                    # including the frame buffer (camera.pixel_array)
                    # which is the single biggest RAM holder (a numpy
                    # array sized WxHx4 held as long as camera lives).
                    try:
                        _sc = locals().get('_auto_scene', None)
                        if _sc is not None:
                            # Explicitly drop the camera's pixel buffer
                            # before we null out the camera itself.
                            try:
                                _cam = getattr(_sc, 'camera', None)
                                if _cam is not None:
                                    for _a in ('pixel_array',
                                               'background',
                                               'background_image',
                                               'pixel_array_to_cairo_context'):
                                        try: setattr(_cam, _a, None)
                                        except Exception: pass
                            except Exception:
                                pass
                            # Close SceneFileWriter's movie file handle
                            # — otherwise ffmpeg process state / buffer
                            # stays held even after the file is flushed.
                            try:
                                _rdr = getattr(_sc, 'renderer', None)
                                _fw = getattr(_rdr, 'file_writer', None)
                                if _fw is not None:
                                    for _a in ('writing_process',
                                               'partial_movie_file',
                                               'video_path'):
                                        try: setattr(_fw, _a, None)
                                        except Exception: pass
                            except Exception:
                                pass
                            # Drop mobjects, animations, time data.
                            for _attr in ('mobjects', 'foreground_mobjects',
                                          'moving_mobjects', 'animations',
                                          'time_progression',
                                          'section_time_progression',
                                          'updaters'):
                                try: setattr(_sc, _attr, [])
                                except Exception: pass
                            for _attr in ('renderer', 'camera',
                                          'file_writer'):
                                try: setattr(_sc, _attr, None)
                                except Exception: pass
                        _auto_scene = None
                    except Exception:
                        pass

                    # Step 2 — clear manim's module-level caches.
                    try:
                        import manim as _mx
                        _caches_cleared = 0
                        for _name in ('_tex_string_to_mob_map',
                                      '_tex_cache',
                                      '_cached_font_faces'):
                            _cache = getattr(_mx, _name, None)
                            if _cache is not None and hasattr(_cache, 'clear'):
                                try:
                                    _cache.clear()
                                    _caches_cleared += 1
                                except Exception: pass
                        # Cairo camera surface cache.
                        try:
                            from manim.camera import cairo_camera as _cc
                            for _name in dir(_cc):
                                if _name.endswith('_cache'):
                                    _c = getattr(_cc, _name, None)
                                    if hasattr(_c, 'clear'):
                                        try:
                                            _c.clear()
                                            _caches_cleared += 1
                                        except Exception: pass
                        except Exception:
                            pass
                    except Exception:
                        pass

                    # Step 3 — Python GC. Three passes because cycles
                    # with __del__ methods need multiple collections
                    # to fully resolve.
                    try:
                        import gc as _gc, sys as _sys_c
                        _collected = 0
                        for _ in range(3):
                            _collected += _gc.collect()
                        try: _sys_c._clear_type_cache()
                        except Exception: pass
                    except Exception:
                        _collected = 0

                    # Step 4 — return pages to the kernel. Python's
                    # pymalloc keeps freed memory in a per-arena pool,
                    # so even after GC iOS still sees our RSS as
                    # elevated. Darwin's `malloc_zone_pressure_relief`
                    # tells the system allocator to release unused
                    # pages — this is what Apple's own frameworks do
                    # on `didReceiveMemoryWarning`.
                    _released_bytes = 0
                    try:
                        import ctypes as _ct
                        _libc = _ct.CDLL(None)
                        if hasattr(_libc, 'malloc_zone_pressure_relief'):
                            _libc.malloc_zone_pressure_relief.argtypes = [
                                _ct.c_void_p, _ct.c_size_t]
                            _libc.malloc_zone_pressure_relief.restype = \
                                _ct.c_size_t
                            # NULL zone = all zones. 0 = unlimited goal.
                            _released_bytes = int(
                                _libc.malloc_zone_pressure_relief(
                                    None, 0))
                        elif hasattr(_libc, 'malloc_trim'):
                            _libc.malloc_trim(0)
                    except Exception:
                        pass

                    _rss_after = _rss_mb()
                    _delta = (_rss_before - _rss_after) if (
                        _rss_before > 0 and _rss_after > 0) else 0
                    _log(f"[splt]   cleanup: RSS {_rss_before}MB "
                         f"→ {_rss_after}MB  "
                         f"(freed {_delta}MB, "
                         f"gc={_collected} objs, "
                         f"malloc_relief={_released_bytes // (1024*1024)}MB)")

                    # Step 5 — pre-flight RAM check for the NEXT scene.
                    # If we'd start the next scene with less than 500 MB
                    # free, stop rendering further scenes so we don't
                    # get jetsam-killed mid-render. Better to have a
                    # partial video than a crashed app.
                    try:
                        import psutil as _psu_c
                        _avail = _psu_c.virtual_memory().available
                        if _avail < 500 * 1024 * 1024:
                            _log(f"[splt] stopping: only "
                                 f"{_avail // (1024*1024)} MB RAM free, "
                                 f"remaining scenes would risk OOM. "
                                 f"Rendered {len(_rendered_mp4s)} of "
                                 f"{len(_scene_classes)} scenes.")
                            break
                    except Exception:
                        pass

                # Stitch multiple scene MP4s into one combined file. We
                # decode every frame and re-encode into a fresh output
                # stream — slower than stream-copy, but robust to any
                # per-clip SPS/PPS/timebase drift. Earlier stream-copy
                # attempts silently dropped all but the last clip's
                # packets when the mux rejected mismatched extradata,
                # which is the "only combines the last class" bug.
                if len(_rendered_mp4s) >= 2:
                    __codebench_plot_path = _rendered_mp4s[-1]   # default fallback
                    _combined_path = os.path.join(
                        os.path.dirname(_rendered_mp4s[0]),
                        "combined_scenes.mp4",
                    )

                    def _clip_codec_signature(path):
                        # Tuple identifying a clip's codec config.
                        # Two clips can be stream-copy concatenated
                        # iff their signatures are equal. Returns
                        # None on probe failure.
                        try:
                            import av as _av_p
                            _p = _av_p.open(path)
                            _ps = _p.streams.video[0]
                            _cc = _ps.codec_context
                            sig = (
                                str(getattr(_cc, "name", "")),
                                int(getattr(_cc, "width", 0) or 0),
                                int(getattr(_cc, "height", 0) or 0),
                                str(getattr(_cc, "pix_fmt", "") or ""),
                                str(getattr(_cc, "profile", "") or ""),
                                str(getattr(_ps, "average_rate", "")
                                    or ""),
                            )
                            _p.close()
                            return sig
                        except Exception:
                            return None

                    _stream_copy_done = False
                    try:
                        import av as _av
                        # Probe every clip up front — stream-copy is
                        # only safe if EVERY clip matches the first.
                        _sigs = [_clip_codec_signature(p)
                                 for p in _rendered_mp4s]
                        _all_match = (
                            all(s is not None for s in _sigs)
                            and len(set(_sigs)) == 1
                        )
                        if _all_match:
                            _out_ct = _av.open(_combined_path, mode="w")
                            _in0 = _av.open(_rendered_mp4s[0])
                            _in0_s = _in0.streams.video[0]
                            _out_stream = _out_ct.add_stream_from_template(
                                _in0_s)
                            _in0.close()

                            _muxed = 0
                            _dropped = 0
                            _pts_offset = 0
                            _last_duration = 1

                            for _src_i, _src in enumerate(_rendered_mp4s):
                                _in_ct = _av.open(_src)
                                _in_s = _in_ct.streams.video[0]
                                _clip_last_pts = 0
                                for _pkt in _in_ct.demux(_in_s):
                                    if _pkt.dts is None:
                                        continue
                                    try:
                                        _pkt.stream = _out_stream
                                        if _pkt.pts is not None:
                                            _pkt.pts = _pkt.pts + _pts_offset
                                            _clip_last_pts = max(
                                                _clip_last_pts, _pkt.pts)
                                        if _pkt.dts is not None:
                                            _pkt.dts = _pkt.dts + _pts_offset
                                        _last_duration = (
                                            _pkt.duration or _last_duration)
                                        _out_ct.mux(_pkt)
                                        _muxed += 1
                                    except Exception:
                                        _dropped += 1
                                _pts_offset = _clip_last_pts + _last_duration
                                _in_ct.close()

                            _out_ct.close()

                            if (_muxed > 0
                                    and os.path.exists(_combined_path)
                                    and os.path.getsize(_combined_path) > 500):
                                __codebench_plot_path = _combined_path
                                print(f"[manim rendered] {_combined_path}",
                                      flush=True)
                                print(f"[manim] combined "
                                      f"{len(_rendered_mp4s)} scenes "
                                      f"({_muxed} packets, {_dropped} "
                                      f"dropped) via stream-copy",
                                      flush=True)
                                _stream_copy_done = True
                            else:
                                print(f"[manim] stream-copy yielded no "
                                      f"packets; trying re-encode "
                                      f"fallback", flush=True)
                        else:
                            # Sigs differ: either different quality
                            # presets, dimensions, codecs — can't
                            # stream-copy, must re-encode.
                            print(f"[manim] clip codec signatures "
                                  f"differ ({len(set(_sigs))} variants) "
                                  f"— using re-encode fallback",
                                  flush=True)
                    except Exception as _sce:
                        print(f"[manim] stream-copy failed "
                              f"({type(_sce).__name__}: {_sce}) — "
                              f"trying re-encode fallback",
                              flush=True)

                    # ── Re-encode fallback ─────────────────────────
                    # Needed when (a) clips have heterogeneous codec
                    # parameters or (b) stream-copy produced no output.
                    # Our bundled PyAV 17.0.1pre has a bug on FFmpeg
                    # 8.x where `avcodec_send_frame` returns EOF
                    # unexpectedly. Workaround: drain pending packets
                    # after every EOFError and retry the frame.
                    if not _stream_copy_done:
                        try:
                            import av as _av
                            # Pick output dims/rate from the LARGEST
                            # clip so nothing gets cropped. Also pick
                            # the MAX source bitrate so our re-encode
                            # doesn't quality-starve — quality loss
                            # from re-encoding h264 → h264 at an
                            # equivalent-or-higher bitrate is typically
                            # ~1-2 dB PSNR, visually imperceptible.
                            _max_w = 0
                            _max_h = 0
                            _max_rate = 15
                            _max_bitrate = 0
                            for _p in _rendered_mp4s:
                                try:
                                    _pp = _av.open(_p)
                                    _ps = _pp.streams.video[0]
                                    _max_w = max(_max_w,
                                                 _ps.codec_context.width or 0)
                                    _max_h = max(_max_h,
                                                 _ps.codec_context.height or 0)
                                    _max_rate = max(_max_rate,
                                                    float(_ps.average_rate
                                                          or 15))
                                    _bps = (getattr(_pp, "bit_rate", 0) or 0)
                                    _max_bitrate = max(_max_bitrate, _bps)
                                    _pp.close()
                                except Exception:
                                    pass
                            if _max_w == 0 or _max_h == 0:
                                raise RuntimeError("couldn't probe any clip")

                            # ── Memory guardrail ──────────────────
                            # Before touching the encoder, make sure
                                # we have enough headroom for its
                                # internal frame buffer (~15 frames).
                                # At worst-case (1080p60) that's
                                # ~100 MB. If we're already under 200 MB
                                # free, skip re-encode and emit last
                                # scene rather than risk jetsam.
                            try:
                                import psutil as _psu
                                _avail = _psu.virtual_memory().available
                                _buffer_need = (_max_w * _max_h * 3
                                                * 15)   # 15 frames RGB
                                if _avail < max(200 * 1024 * 1024,
                                                _buffer_need * 3):
                                    print(f"[manim] skipping re-encode: "
                                          f"only {_avail // (1024*1024)} "
                                          f"MB available, need headroom "
                                          f"for {_buffer_need // (1024*1024)}"
                                          f" MB of encoder buffers",
                                          flush=True)
                                    raise MemoryError("insufficient RAM")
                            except MemoryError:
                                raise
                            except Exception:
                                pass

                            _out_ct = _av.open(_combined_path, mode="w")
                            _concat_stream = _out_ct.add_stream(
                                "h264_videotoolbox", rate=int(_max_rate))
                            _concat_stream.width = _max_w
                            _concat_stream.height = _max_h
                            _concat_stream.pix_fmt = "yuv420p"
                            # Quality-preserving bitrate: match the
                            # highest source bitrate, with a floor of
                            # 3 Mbps for 480p / 6 Mbps for 720p+ /
                            # 12 Mbps for 1080p+ so upscaled content
                            # doesn't look worse than the source.
                            if _max_h >= 1080:
                                _floor = 12_000_000
                            elif _max_h >= 720:
                                _floor = 6_000_000
                            else:
                                _floor = 3_000_000
                            _concat_stream.bit_rate = max(
                                int(_max_bitrate), _floor)

                            def _drain(stream, sink):
                                # Pull every queued packet from the
                                # encoder. Tolerates the PyAV 17 /
                                # FFmpeg 8 EOFError quirk — EOFError
                                # just means "no more ready packets".
                                try:
                                    for _p in stream.encode():
                                        sink(_p)
                                except EOFError:
                                    pass
                                except Exception:
                                    pass

                            def _feed_frame(stream, frame, sink):
                                # Encode one frame, working around
                                # PyAV's over-eager EOFError by
                                # draining first and retrying once.
                                try:
                                    for _p in stream.encode(frame):
                                        sink(_p)
                                    return True
                                except EOFError:
                                    pass
                                _drain(stream, sink)
                                try:
                                    for _p in stream.encode(frame):
                                        sink(_p)
                                    return True
                                except Exception:
                                    return False

                            _encoded = 0
                            _skipped = 0
                            _pts_counter = 0
                            _mux_sink = lambda p: _out_ct.mux(p)

                            for _src_i, _src in enumerate(_rendered_mp4s):
                                try:
                                    _in_ct = _av.open(_src)
                                except Exception as _oe:
                                    print(f"[manim] couldn't open clip "
                                          f"{_src_i}: {_oe}", flush=True)
                                    continue
                                _in_s = _in_ct.streams.video[0]
                                for _frame in _in_ct.decode(_in_s):
                                    try:
                                        _arr = _frame.to_ndarray(format="rgb24")
                                        _clean = _av.VideoFrame.from_ndarray(
                                            _arr, format="rgb24")
                                        _clean.pts = _pts_counter
                                        _pts_counter += 1
                                        if _feed_frame(_concat_stream,
                                                       _clean, _mux_sink):
                                            _encoded += 1
                                        else:
                                            _skipped += 1
                                    except Exception:
                                        _skipped += 1
                                _in_ct.close()
                                # Drain between clips so encoder
                                # doesn't carry state across boundaries.
                                _drain(_concat_stream, _mux_sink)

                            # Final drain (last clip's trailing frames).
                            _drain(_concat_stream, _mux_sink)
                            _out_ct.close()

                            if (_encoded > 0
                                    and os.path.exists(_combined_path)
                                    and os.path.getsize(_combined_path) > 500):
                                __codebench_plot_path = _combined_path
                                print(f"[manim rendered] {_combined_path}",
                                      flush=True)
                                print(f"[manim] combined "
                                      f"{len(_rendered_mp4s)} scenes "
                                      f"({_encoded} frames, {_skipped} "
                                      f"skipped) via re-encode",
                                      flush=True)
                            else:
                                print(f"[manim] re-encode also yielded "
                                      f"empty video "
                                      f"({_encoded} encoded, {_skipped} "
                                      f"skipped) — emitting last scene",
                                      flush=True)
                                __codebench_plot_path = _rendered_mp4s[-1]
                                print(f"[manim rendered] "
                                      f"{_rendered_mp4s[-1]}", flush=True)
                        except Exception as _re:
                            import traceback as _rtb
                            _log(f"re-encode fallback failed: {_re}")
                            _rtb.print_exc()
                            __codebench_plot_path = _rendered_mp4s[-1]
                            print(f"[manim] concat failed both paths "
                                  f"({_re}); emitting last scene",
                                  flush=True)
                            print(f"[manim rendered] "
                                  f"{_rendered_mp4s[-1]}", flush=True)
            else:
                _log("no user-defined Scene classes in this run — skipping auto-render")
        except ImportError:
            pass
        except Exception as _ae:
            _log(f"Auto-render outer error: {_ae}")
            print(f"[manim] auto-detect outer error: {_ae}", flush=True)

    # Auto-save any unsaved matplotlib figures
    try:
        if _plt and hasattr(_plt, 'get_fignums') and _plt.get_fignums() and not __codebench_plot_path:
            _plt.show()
    except Exception:
        pass
except Exception:
    traceback.print_exc()
finally:
    sys.stdout, sys.stderr = _old_stdout, _old_stderr
__codebench_stdout = _out_stream.getvalue()
__codebench_stderr = _err_stream.getvalue()
_out_stream.close()
_err_stream.close()
# Diagnostic — log final value of __codebench_plot_path so we can tell
# from log.txt whether Swift's empty read is "Python never set it" vs
# "Swift looked at the wrong dict". Goes to NSLog (Xcode console) via
# sys.__stderr__ AND to the captured stdout, so it shows up either
# in Xcode or appended to the user's terminal output.
try:
    import sys as _diag_sys
    # Read three ways:
    #  (a) free variable      — what the auto-render assignment wrote to
    #  (b) main.__dict__[…]   — what Swift's getGlobalString reads
    #  (c) main module identity — confirms (a) and (b) point to the same dict
    _free = repr(__codebench_plot_path) if "__codebench_plot_path" in dir() or True else "<missing>"
    _md = _diag_sys.modules.get("__main__")
    _md_dict_path = repr(getattr(_md, "__codebench_plot_path", "<MISSING-FROM-MAIN>"))
    _md_id = hex(id(_md.__dict__)) if _md else "<no main>"
    _diag_msg = (
        f"[diag] free={_free}  main.dict={_md_dict_path}  "
        f"main.dict_id={_md_id}"
    )
    # __stderr__ may be the closed iOS-bundle fd (Errno 5) — keep it
    # best-effort so we don't drown the captured stdout in a red-herring
    # OSError trace at the very end of the run. We DON'T also print to
    # stdout here: stdout flows into the user-visible terminal, and
    # this diagnostic is purely for Xcode-console post-mortem when the
    # path probe came back empty. The Swift-side filter that drops
    # `[diag] …` lines didn't catch this one because it was emitted
    # outside the runTapped streaming pipeline (during runtime init),
    # so the surest way to keep it out of the terminal is just not to
    # print to stdout at all.
    try:
        _diag_sys.__stderr__.write(_diag_msg + "\\n")
        _diag_sys.__stderr__.flush()
    except OSError:
        pass
except Exception as _de:
    try:
        _diag_sys.__stderr__.write(
            f"[diag] FAILED: {type(_de).__name__}: {_de}\\n")
        _diag_sys.__stderr__.flush()
    except OSError:
        pass

# ── post-run memory cleanup ──────────────────────────────────────
# iOS Python is a long-lived process — each Run-button invocation
# accumulates objects (matplotlib figures, torch tensors, plotly
# layouts, tqdm bars). Without a fork(), nothing reaps them between
# runs and the app's RSS climbs monotonically. Release what we can.
try:
    import gc as _cb_gc
    # matplotlib: close all figures
    try:
        _cb_plt = sys.modules.get('matplotlib.pyplot')
        if _cb_plt is not None and hasattr(_cb_plt, 'close'):
            _cb_plt.close('all')
            for _n in ('_current_fig', '_axes_cache'):
                if hasattr(_cb_plt, _n): setattr(_cb_plt, _n, None)
            for _n in ('_layout_updates', '_annotations', '_shapes'):
                _a = getattr(_cb_plt, _n, None)
                if hasattr(_a, 'clear'):
                    try: _a.clear()
                    except Exception: pass
    except Exception: pass
    # torch: release cached allocator pages
    try:
        _cb_torch = sys.modules.get('torch')
        if _cb_torch is not None:
            if hasattr(_cb_torch, 'cuda') and hasattr(_cb_torch.cuda, 'empty_cache'):
                try: _cb_torch.cuda.empty_cache()
                except Exception: pass
            if hasattr(_cb_torch, 'mps') and hasattr(_cb_torch.mps, 'empty_cache'):
                try: _cb_torch.mps.empty_cache()
                except Exception: pass
    except Exception: pass
    # tqdm: close orphaned progress bars
    try:
        _cb_tqdm_mod = sys.modules.get('tqdm')
        if _cb_tqdm_mod is not None:
            _cb_tqdm_cls = getattr(_cb_tqdm_mod, 'tqdm', None)
            if _cb_tqdm_cls is not None and hasattr(_cb_tqdm_cls, '_instances'):
                for _b in list(getattr(_cb_tqdm_cls, '_instances', ())):
                    try: _b.close()
                    except Exception: pass
    except Exception: pass
    # Two GC passes — second catches cycles found in first.
    try:
        _cb_gc.collect(2)
        _cb_gc.collect(2)
    except Exception: pass
except Exception:
    pass
"""
}
