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

    private enum RuntimeError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let value):
                return value
            }
        }
    }

    private let queue = DispatchQueue(label: "offlinai.python.runtime")
    private let queueKey = DispatchSpecificKey<Void>()
    private var pathsConfigured = false
    private var toolOutputDirectoryURL: URL?
    private var environmentConfigured = false
    private let fileInputMode: Int32 = 257 // Py_file_input
    private var gilReleasedForThreads = false

    private init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    func execute(code: String) -> ExecutionResult {
        return execute(code: code, onOutput: nil)
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
            import threading, traceback, sys
            def _offlinai_start_repl():
                try:
                    import offlinai_shell
                    offlinai_shell.repl()
                except Exception:
                    traceback.print_exc()
                    sys.stderr.flush()
            _t = threading.Thread(target=_offlinai_start_repl, name='offlinai-repl', daemon=True)
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
_offlinai_lib_status = []
for _name in \(pythonArrayLiteral(filtered)):
    try:
        _mod = importlib.import_module(_name)
        _file = getattr(_mod, "__file__", "")
        _shim = not bool(_file)
        _offlinai_lib_status.append({
            "name": _name,
            "state": "shim" if _shim else "installed",
            "detail": _file if _file else "built-in compatibility layer"
        })
    except Exception as _exc:
        _offlinai_lib_status.append({
            "name": _name,
            "state": "missing",
            "detail": f"{type(_exc).__name__}: {_exc}"
        })
print("__OFFLINAI_LIB_STATUS__=" + json.dumps(_offlinai_lib_status))
"""

        let result = execute(code: script)
        let output = result.output
        guard let markerRange = output.range(of: "__OFFLINAI_LIB_STATUS__=") else {
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
            try setGlobalString(encoded, key: "__offlinai_code_b64", globals: globals)
            try setGlobalString(toolDir.path, key: "__offlinai_tool_dir", globals: globals)

            // Pass manim quality settings
            let manimQuality = UserDefaults.standard.integer(forKey: "manim_quality") // 0=low, 1=med, 2=high
            let manimFPS = UserDefaults.standard.integer(forKey: "manim_fps")
            try setGlobalString(String(manimQuality), key: "__offlinai_manim_quality", globals: globals)
            try setGlobalString(String(manimFPS > 0 ? manimFPS : 24), key: "__offlinai_manim_fps", globals: globals)

            print("[python] [\(elapsed())] Running wrapper script (code: \(trimmed.count) chars)...")
            try runStatements(Self.executionWrapperScript, filename: "<offlinai-python-tool>")
            print("[python] [\(elapsed())] Wrapper script completed")

            print("[python] [\(elapsed())] Reading stdout...")
            let stdoutRaw = getGlobalString("__offlinai_stdout", globals: globals)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = sanitizeToolStdout(stdoutRaw)
            let stderr = getGlobalString("__offlinai_stderr", globals: globals)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let imagePath = getGlobalString("__offlinai_plot_path", globals: globals)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("[python] [\(elapsed())] stdout=\(stdout.prefix(100)), stderr=\(stderr.prefix(200)), image=\(imagePath.prefix(80))")

            var finalImagePath: String?
            if !imagePath.isEmpty, FileManager.default.fileExists(atPath: imagePath) {
                finalImagePath = imagePath
            }

            let plotOnlyStdout = Self.isPlotOnlyOutput(stdout, imagePath: finalImagePath)
            var sections: [String] = []
            if !stdout.isEmpty && !plotOnlyStdout {
                sections.append(stdout)
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

        // User-installable site-packages: Documents/site-packages is writable, so the
        // Packages tab installs pip wheels here. Ensure it exists + is on sys.path.
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let userSitePath = documentsURL?.appendingPathComponent("site-packages", isDirectory: true).path ?? ""
        if !userSitePath.isEmpty {
            try? FileManager.default.createDirectory(atPath: userSitePath, withIntermediateDirectories: true)
        }

        let script = """
import os, sys
for _p in [\(pythonQuoted(versionPath)), \(pythonQuoted(dynloadPath)), \(pythonQuoted(sitePackagesPath)), \(pythonQuoted(userSitePath))]:
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
        // User-installable site-packages in Documents (writable on iOS)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let userSitePath = documentsURL?.appendingPathComponent("site-packages", isDirectory: true).path ?? ""
        if !userSitePath.isEmpty {
            try? FileManager.default.createDirectory(atPath: userSitePath, withIntermediateDirectories: true)
        }
        let pythonPath = [versionPath, dynloadPath, sitePackagesPath, userSitePath]
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        let toolDir = try ensureToolOutputDirectory().path

        setenv("PYTHONHOME", pythonRoot, 1)
        setenv("PYTHONPATH", pythonPath, 1)
        setenv("PYTHONNOUSERSITE", "1", 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("MPLCONFIGDIR", toolDir, 1)

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
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw RuntimeError.message("Unable to resolve documents directory for Python tool output.")
        }
        let outputURL = documentsURL.appendingPathComponent("ToolOutputs", isDirectory: true)
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
__offlinai_stdout = ""
__offlinai_stderr = ""
__offlinai_plot_path = ""
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
_offlinai_code = base64.b64decode(__offlinai_code_b64.encode("utf-8")).decode("utf-8", "replace")
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
    for _p in sys.path:
        if _p and "CodeBench.app" in _p:
            # Trim everything after CodeBench.app to get bundle root.
            _root = _p.split("CodeBench.app", 1)[0] + "CodeBench.app"
            _candidates.append(_os_stub.path.join(_root, "Frameworks", "libfortran_io_stubs.dylib"))
            break
    # (2) Fallbacks
    _candidates += [
        "@rpath/libfortran_io_stubs.dylib",
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

_stream_dir = globals().get('__offlinai_tool_dir', '')
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
    __offlinai_plotly_css = (
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

    def __offlinai_save_plotly_html(_fig, _path):
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
                _html = _html.replace("<head>", "<head>" + __offlinai_plotly_css, 1)
            else:
                _html = __offlinai_plotly_css + _html
            with open(_path, "w", encoding="utf-8") as _f:
                _f.write(_html)
        except Exception as _e:
            _log(f"css splice failed: {_e}")

    # Hook matplotlib.pyplot.show to capture chart output
    if _plt and hasattr(_plt, '_show_hook'):
        def _offlinai_mpl_show(fig_obj=None):
            global __offlinai_plot_path
            os.makedirs(__offlinai_tool_dir, exist_ok=True)
            if fig_obj is not None and hasattr(fig_obj, 'write_html'):
                _path = os.path.join(__offlinai_tool_dir, f"chart_{uuid.uuid4().hex[:8]}.html")
                _real_fig = getattr(fig_obj, '_fig', fig_obj)
                __offlinai_save_plotly_html(_real_fig, _path)
                __offlinai_plot_path = _path
                _log(f"chart saved: {_path}")
                print(f"[plot saved] {_path}")
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
                global __offlinai_plot_path
                os.makedirs(__offlinai_tool_dir, exist_ok=True)
                _path = os.path.join(__offlinai_tool_dir, f"chart_{uuid.uuid4().hex[:8]}.html")
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
                __offlinai_save_plotly_html(self, _path)
                __offlinai_plot_path = _path
                _log(f"plotly chart saved: {_path}")
                print(f"[plot saved] {_path}")
            _Figure.show = _offlinai_plotly_show
    except (ImportError, AttributeError) as _plotly_hook_err:
        _log(f"plotly hook skipped: {type(_plotly_hook_err).__name__}: {_plotly_hook_err}")
    except Exception as _plotly_hook_err:
        _log(f"plotly hook crashed ({type(_plotly_hook_err).__name__}): skipping")

    # Configure manim for iOS (if available)
    try:
        import manim
        _manim_run_id = uuid.uuid4().hex[:8]
        _manim_media = os.path.join(__offlinai_tool_dir, f"manim_{_manim_run_id}")
        os.makedirs(_manim_media, exist_ok=True)
        manim.config.media_dir = _manim_media
        manim.config.renderer = "cairo"
        manim.config.format = "mp4"
        manim.config.write_to_movie = True
        manim.config.save_last_frame = False
        manim.config.preview = False
        manim.config.show_in_file_browser = False
        manim.config.disable_caching = True
        manim.config.verbosity = "WARNING"
        # MUST use standard quality presets — custom pixel values break frame_rate!
        # Manim's quality presets set pixel_width, pixel_height, AND frame_rate together.
        _mq = int(globals().get('__offlinai_manim_quality', '0') or '0')
        _quality_map = {0: 'low_quality', 1: 'medium_quality', 2: 'high_quality'}
        manim.config.quality = _quality_map.get(_mq, 'low_quality')
        _log(f"manim quality={manim.config.quality} res={manim.config.pixel_width}x{manim.config.pixel_height} fps={manim.config.frame_rate}")

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
            if _bundle_root:
                for _rel in ("katex/fonts", "Frameworks/katex/fonts"):
                    _cand_dir = os.path.join(_bundle_root, _rel)
                    if os.path.isdir(_cand_dir):
                        _font_dir = _cand_dir
                        _ttf = os.path.join(_cand_dir, "KaTeX_Main-Regular.ttf")
                        if os.path.exists(_ttf):
                            _font_path = _ttf
                        break
            _log(f"[manim-font] font_dir={_font_dir} font_path={_font_path}")

            if _font_dir:
                # Write a minimal fonts.conf that adds our dir to the search
                # path and sets KaTeX_Main as both 'sans-serif' and 'serif'
                # so Pango's default families all resolve.
                _fc_file = os.path.join(__offlinai_tool_dir, "fonts.conf")
                _alias = "<family>KaTeX_Main</family>"
                _lines = [
                    "<fontconfig>",
                    "  <dir>" + _font_dir + "</dir>",
                    "  <cachedir>" + __offlinai_tool_dir + "/fontcache</cachedir>",
                    "  <alias><family>serif</family><prefer>" + _alias + "</prefer></alias>",
                    "  <alias><family>sans-serif</family><prefer>" + _alias + "</prefer></alias>",
                    "  <alias><family>sans</family><prefer>" + _alias + "</prefer></alias>",
                    "  <alias><family>monospace</family><prefer>" + _alias + "</prefer></alias>",
                    "  <alias><family>Times</family><prefer>" + _alias + "</prefer></alias>",
                    "</fontconfig>",
                    "",
                ]
                _fc_content = chr(10).join(_lines)
                os.makedirs(f"{__offlinai_tool_dir}/fontcache", exist_ok=True)
                with open(_fc_file, "w") as _fcf:
                    _fcf.write(_fc_content)
                os.environ["FONTCONFIG_FILE"] = _fc_file
                os.environ["FONTCONFIG_PATH"] = __offlinai_tool_dir
                _log(f"[manim-font] wrote {_fc_file}")

            # Also register the specific TTF with manimpango (direct path)
            try:
                import manimpango as _mp
                if _font_path and hasattr(_mp, "register_font"):
                    _ok = _mp.register_font(_font_path)
                    _log(f"[manim-font] register_font = {_ok}")
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
            _collected_frames = []  # shared frame buffer

            def _capture_write_frame(self_fw, frame_or_renderer, num_frames=1):
                # Intercept write_frame to collect PIL frames for GIF
                try:
                    if isinstance(frame_or_renderer, np.ndarray):
                        frame = frame_or_renderer
                    elif hasattr(frame_or_renderer, 'get_frame'):
                        frame = frame_or_renderer.get_frame()
                    else:
                        frame = None
                    if frame is not None and frame.size > 0:
                        from PIL import Image as _PILImage
                        # frame is RGBA uint8 numpy array
                        if frame.shape[-1] == 4:
                            img = _PILImage.fromarray(frame, 'RGBA').convert('RGB')
                        else:
                            img = _PILImage.fromarray(frame, 'RGB')
                        # Sample every few frames to keep GIF small
                        _collected_frames.append(img)
                except Exception:
                    pass
                # Still call original (for save_last_frame PNG)
                try:
                    _orig_write_frame(self_fw, frame_or_renderer, num_frames)
                except Exception:
                    pass

            SceneFileWriter.write_frame = _capture_write_frame

            def _offlinai_manim_render(self, *args, **kwargs):
                global __offlinai_plot_path
                import manim as _m
                _m.config.renderer = "cairo"
                _m.config.format = "mp4"
                _m.config.write_to_movie = True
                _m.config.save_last_frame = False
                _m.config.preview = False
                _m.config.disable_caching = True
                # Log Pango status (older torch_ios-shimmed manimpango exposed
                # `_pango_available`; the real manimpango doesn't, so guard).
                import manimpango as _mp
                _pango_ok = getattr(_mp, "_pango_available", True)
                if _pango_ok:
                    print("[manim] Pango: native rendering available")
                else:
                    print(f"[manim] Pango: stub mode ({getattr(_mp, '_pango_error', 'unknown')})")

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
                    if _bundle_root:
                        for _rel in ("Frameworks/katex/fonts/KaTeX_Main-Regular.ttf",
                                     "katex/fonts/KaTeX_Main-Regular.ttf"):
                            _cand = _os_f.path.join(_bundle_root, _rel)
                            if _os_f.path.exists(_cand):
                                _font_path = _cand
                                break
                    if _font_path and hasattr(_mp, "register_font"):
                        _mp.register_font(_font_path)
                        print(f"[manim] registered font {_font_path}", flush=True)
                        # Make sure Text uses it by default
                        _m.config.font = "KaTeX_Main"
                    else:
                        print(f"[manim] WARN: no bundled font found (root={_bundle_root})", flush=True)
                except Exception as _fe:
                    print(f"[manim] font registration failed: {type(_fe).__name__}: {_fe}", flush=True)
                _m.config.from_animation_number = 0
                _m.config.upto_animation_number = -1
                # Re-apply quality preset to ensure correct frame_rate
                _q = int(globals().get('__offlinai_manim_quality', '0') or '0')
                _qmap = {0: 'low_quality', 1: 'medium_quality', 2: 'high_quality'}
                _m.config.quality = _qmap.get(_q, 'low_quality')
                _collected_frames.clear()
                _orig_render(self, *args, **kwargs)
                print(f"[manim-debug] frames_written={len(_collected_frames)} skip={getattr(self.renderer, 'skip_animations', '?')} sections_skip={getattr(self.renderer.file_writer.sections[-1], 'skip_animations', '?') if hasattr(self.renderer, 'file_writer') and self.renderer.file_writer.sections else '?'}")
                try:
                    fw = self.renderer.file_writer
                    _log(f"fw attrs: movie={hasattr(fw,'movie_file_path')}, image={hasattr(fw,'image_file_path')}")
                    if hasattr(fw, 'movie_file_path'):
                        _log(f"movie_file_path={fw.movie_file_path}")
                    # 1. Check for mp4 video (PyAV + ffmpeg)
                    movie_path = str(fw.movie_file_path) if hasattr(fw, 'movie_file_path') and fw.movie_file_path else None
                    if movie_path and os.path.exists(movie_path) and os.path.getsize(movie_path) > 500:
                        __offlinai_plot_path = movie_path
                        _log(f"manim MP4: {movie_path} ({os.path.getsize(movie_path)} bytes)")
                        print(f"[manim rendered] {movie_path}")
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
                            __offlinai_plot_path = gif_path
                            _log(f"manim GIF: {gif_path} ({len(frames)} frames)")
                            print(f"[manim rendered] {gif_path}")
                            _collected_frames.clear()
                            return
                    # 3. Fallback: static PNG
                    img_path = str(fw.image_file_path) if hasattr(fw, 'image_file_path') and fw.image_file_path else None
                    if img_path and os.path.exists(img_path):
                        __offlinai_plot_path = img_path
                        _log(f"manim PNG: {img_path}")
                        print(f"[manim rendered] {img_path}")
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
                            __offlinai_plot_path = latest
                            _log(f"manim found: {latest}")
                            print(f"[manim rendered] {latest}")
                except Exception as e:
                    _log(f"manim output error: {e}")
                _collected_frames.clear()

            manim.Scene.render = _offlinai_manim_render
            manim.Scene._offlinai_patched = True
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
    _globals_before_exec = set(globals().keys())

    # Execute user code
    _log("Executing user code...")
    exec(_offlinai_code, globals(), globals())
    _log("User code finished")

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

    if _user_defined_a_scene and not __offlinai_plot_path:
        try:
            import manim as _manim_detect
            _scene_classes = []
            _new_names = set(globals().keys()) - _globals_before_exec
            for _name, _obj in list(globals().items()):
                if _name not in _new_names:
                    continue  # stale class from a previous run — skip
                if not isinstance(_obj, type):
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

            if _scene_classes:
                # Render the LAST defined Scene class (most likely the user's)
                _scene_name, _scene_cls = _scene_classes[-1]
                _log(f"Auto-rendering Scene: {_scene_name}")
                print(f"[manim] Auto-rendering {_scene_name}...", flush=True)
                try:
                    _auto_scene = _scene_cls()
                    _auto_scene.render()
                    print(f"[manim] {_scene_name}.render() returned.", flush=True)
                except BaseException as _render_err:
                    import traceback as _tb
                    print(f"[manim] render() failed: {type(_render_err).__name__}: {_render_err}", flush=True)
                    _tb.print_exc()
            else:
                _log("no user-defined Scene classes in this run — skipping auto-render")
        except ImportError:
            pass
        except Exception as _ae:
            _log(f"Auto-render outer error: {_ae}")
            print(f"[manim] auto-detect outer error: {_ae}", flush=True)

    # Auto-save any unsaved matplotlib figures
    try:
        if _plt and hasattr(_plt, 'get_fignums') and _plt.get_fignums() and not __offlinai_plot_path:
            _plt.show()
    except Exception:
        pass
except Exception:
    traceback.print_exc()
finally:
    sys.stdout, sys.stderr = _old_stdout, _old_stderr
__offlinai_stdout = _out_stream.getvalue()
__offlinai_stderr = _err_stream.getvalue()
_out_stream.close()
_err_stream.close()
"""
}
