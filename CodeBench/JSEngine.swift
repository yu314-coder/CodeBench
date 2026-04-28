import Foundation
import JavaScriptCore

/// In-process JavaScript REPL backed by JavaScriptCore.framework (always
/// available on iOS, no JIT but interpreted/baseline execution is plenty
/// fast for a REPL).
///
/// The Python shell's `js` builtin sends source code through the same
/// file-IPC channel LaTeXEngine uses, JSEngine evaluates in a long-lived
/// JSContext, and writes the captured output + return value back through
/// a per-request response file:
///
///   write   $TMPDIR/latex_signals/js_eval_request.txt   (Python)
///   read   ←                                              (JSEngine)
///   eval                                                 (JSContext)
///   write   $TMPDIR/latex_signals/js_eval_resp_<id>.txt  (JSEngine)
///   read   ←                                              (Python)
///
/// Request payload (one JSON object per file, no trailing newline matters):
///
///   {"id": "<hex>", "src": "<JS source>", "reset": false}
///
/// Response payload:
///
///   {"ok": true,  "stdout": "...", "result": "<JSON-encoded value>"}
///   {"ok": false, "stdout": "...", "error":  "<message>", "stack": "..."}
///
/// Why per-request response files instead of a single shared one: lets
/// multiple concurrent js evals (e.g. python script kicking off several
/// js workers) stay decoupled. The Python side polls only its own id.
@objc class JSEngine: NSObject {

    static let shared = JSEngine()

    private var context: JSContext!
    private var stdoutBuffer: String = ""
    private var pollTimer: Timer?
    private let bootSerial = "[JSEngine]"

    private var signalDir: String {
        NSTemporaryDirectory().appending("latex_signals/")
    }

    override init() {
        super.init()
        rebuildContext()
    }

    // MARK: Lifecycle

    /// Spin up the engine and start polling for eval requests. Idempotent —
    /// safe to call from multiple init paths (AppDelegate / GameVC).
    func initialize() {
        try? FileManager.default.createDirectory(
            atPath: signalDir, withIntermediateDirectories: true)
        startSignalWatcher()
        print("\(bootSerial) initialized — JS REPL backed by JavaScriptCore (no JIT)")
    }

    /// Tear down the current JSContext and rebuild — used by `js --reset`
    /// from the Python side so users can clear accumulated globals
    /// without quitting the app.
    func reset() {
        rebuildContext()
        print("\(bootSerial) context reset — globals cleared")
    }

    private func rebuildContext() {
        let ctx = JSContext()!
        // Surface uncaught JS exceptions into our captured-stdout stream
        // so the Python side sees them in the response, not just the
        // Xcode console.
        ctx.exceptionHandler = { [weak self] _, exc in
            guard let exc = exc else { return }
            let msg = exc.toString() ?? "(unknown JS exception)"
            let stack = exc.objectForKeyedSubscript("stack")?.toString() ?? ""
            self?.stdoutBuffer +=
                "Uncaught: \(msg)\n\(stack.isEmpty ? "" : stack + "\n")"
        }
        installGlobals(ctx)
        self.context = ctx
    }

    // MARK: Globals — console, fetch, fs, setTimeout

    /// Install browser-shaped globals (`console`, `fetch`, `setTimeout`)
    /// plus a small `fs`-like helper scoped to ~/Documents. We don't try
    /// to ape Node.js' module system — users who want CommonJS can use
    /// the `require` helper that resolves against ~/Documents/node_modules.
    private func installGlobals(_ ctx: JSContext) {
        // ─ console.* ─ collect into stdoutBuffer so the response carries it.
        let console = JSValue(newObjectIn: ctx)!

        let logFn: @convention(block) () -> Void = { [weak self] in
            guard let self = self,
                  let args = JSContext.currentArguments() as? [JSValue] else { return }
            let line = args.map { Self.stringify($0) }.joined(separator: " ")
            self.stdoutBuffer += line + "\n"
        }
        let errFn: @convention(block) () -> Void = { [weak self] in
            guard let self = self,
                  let args = JSContext.currentArguments() as? [JSValue] else { return }
            let line = args.map { Self.stringify($0) }.joined(separator: " ")
            // Mark with a leading marker so the Python side can color it red.
            self.stdoutBuffer += "\u{001B}[31m" + line + "\u{001B}[0m\n"
        }
        console.setObject(unsafeBitCast(logFn, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
        console.setObject(unsafeBitCast(logFn, to: AnyObject.self), forKeyedSubscript: "info" as NSString)
        console.setObject(unsafeBitCast(logFn, to: AnyObject.self), forKeyedSubscript: "debug" as NSString)
        console.setObject(unsafeBitCast(errFn, to: AnyObject.self), forKeyedSubscript: "error" as NSString)
        console.setObject(unsafeBitCast(errFn, to: AnyObject.self), forKeyedSubscript: "warn" as NSString)
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)

        // ─ setTimeout / setInterval / clear* ─ JSC has no event loop of
        // its own. We schedule on the main RunLoop, which keeps tickling
        // while our signalTimer is active. Returns a JS-visible numeric
        // handle so user code can `clearTimeout(h)`.
        var timerHandles: [Int: Timer] = [:]
        var nextHandle = 1
        let setTimeoutFn: @convention(block) (JSValue, Double) -> Int = { [weak ctx] cb, ms in
            let h = nextHandle; nextHandle += 1
            let t = Timer.scheduledTimer(withTimeInterval: max(0, ms) / 1000.0,
                                          repeats: false) { _ in
                _ = ctx?.objectForKeyedSubscript("__invokeTimer")
                            .call(withArguments: [cb])
                timerHandles.removeValue(forKey: h)
            }
            timerHandles[h] = t
            return h
        }
        let setIntervalFn: @convention(block) (JSValue, Double) -> Int = { [weak ctx] cb, ms in
            let h = nextHandle; nextHandle += 1
            let t = Timer.scheduledTimer(withTimeInterval: max(0.001, ms) / 1000.0,
                                          repeats: true) { _ in
                _ = ctx?.objectForKeyedSubscript("__invokeTimer")
                            .call(withArguments: [cb])
            }
            timerHandles[h] = t
            return h
        }
        let clearFn: @convention(block) (Int) -> Void = { h in
            timerHandles[h]?.invalidate()
            timerHandles.removeValue(forKey: h)
        }
        // tiny JS shim so cb() runs inside a try/catch — uncaught
        // throws inside async callbacks would otherwise just log to
        // Xcode and silently disappear from the user's REPL.
        ctx.evaluateScript("""
            globalThis.__invokeTimer = function(cb) {
                try { cb(); }
                catch (e) { console.error("Async error:", e && e.stack || e); }
            };
        """)
        ctx.setObject(unsafeBitCast(setTimeoutFn,  to: AnyObject.self), forKeyedSubscript: "setTimeout"  as NSString)
        ctx.setObject(unsafeBitCast(setIntervalFn, to: AnyObject.self), forKeyedSubscript: "setInterval" as NSString)
        ctx.setObject(unsafeBitCast(clearFn,       to: AnyObject.self), forKeyedSubscript: "clearTimeout" as NSString)
        ctx.setObject(unsafeBitCast(clearFn,       to: AnyObject.self), forKeyedSubscript: "clearInterval" as NSString)

        // ─ fetch (synchronous semaphore-blocked variant — JSC has no
        //   real microtask queue we can pump from here). Returns a JS
        //   object shaped like a fetch Response: { ok, status, statusText,
        //   headers, text(), json(), arrayBuffer() }. Note: this is NOT
        //   spec-compliant async fetch; it blocks the JS thread. Good
        //   enough for REPL scripting; for streaming use URLSession
        //   directly via a future bridge.
        let fetchFn: @convention(block) (String, JSValue?) -> JSValue = { [weak ctx] urlStr, opts in
            guard let ctx = ctx, let url = URL(string: urlStr) else {
                return JSValue(nullIn: JSContext.current())
            }
            var req = URLRequest(url: url)
            if let opts = opts, opts.isObject {
                if let m = opts.objectForKeyedSubscript("method")?.toString(),
                   !m.isEmpty, m != "undefined" {
                    req.httpMethod = m
                }
                if let h = opts.objectForKeyedSubscript("headers"),
                   h.isObject,
                   let dict = h.toDictionary() as? [String: Any] {
                    for (k, v) in dict {
                        req.setValue("\(v)", forHTTPHeaderField: k)
                    }
                }
                if let body = opts.objectForKeyedSubscript("body"),
                   !body.isUndefined, !body.isNull {
                    req.httpBody = body.toString()?.data(using: .utf8)
                }
            }
            let sem = DispatchSemaphore(value: 0)
            var responseBody: Data = Data()
            var statusCode: Int = 0
            var statusText: String = ""
            var headerDict: [String: String] = [:]
            var requestErr: Error?
            URLSession.shared.dataTask(with: req) { data, resp, err in
                requestErr = err
                if let http = resp as? HTTPURLResponse {
                    statusCode = http.statusCode
                    statusText = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    for (k, v) in http.allHeaderFields {
                        headerDict["\(k)"] = "\(v)"
                    }
                }
                if let d = data { responseBody = d }
                sem.signal()
            }.resume()
            sem.wait()
            let respObj = JSValue(newObjectIn: ctx)!
            respObj.setObject(requestErr == nil && (200..<400).contains(statusCode),
                              forKeyedSubscript: "ok" as NSString)
            respObj.setObject(statusCode, forKeyedSubscript: "status" as NSString)
            respObj.setObject(statusText, forKeyedSubscript: "statusText" as NSString)
            respObj.setObject(headerDict,  forKeyedSubscript: "headers" as NSString)
            if let err = requestErr {
                respObj.setObject(err.localizedDescription,
                                  forKeyedSubscript: "error" as NSString)
            }
            // .text(), .json(), .arrayBuffer() — capture the body in closures.
            let bodyText = String(data: responseBody, encoding: .utf8) ?? ""
            let textFn: @convention(block) () -> String = { bodyText }
            let jsonFn: @convention(block) () -> Any? = {
                try? JSONSerialization.jsonObject(with: responseBody, options: [])
            }
            let bufFn: @convention(block) () -> [UInt8] = {
                Array(responseBody)
            }
            respObj.setObject(unsafeBitCast(textFn, to: AnyObject.self),
                              forKeyedSubscript: "text" as NSString)
            respObj.setObject(unsafeBitCast(jsonFn, to: AnyObject.self),
                              forKeyedSubscript: "json" as NSString)
            respObj.setObject(unsafeBitCast(bufFn,  to: AnyObject.self),
                              forKeyedSubscript: "arrayBuffer" as NSString)
            return respObj
        }
        ctx.setObject(unsafeBitCast(fetchFn, to: AnyObject.self),
                      forKeyedSubscript: "fetch" as NSString)

        // ─ fs — minimal, scoped to ~/Documents. Mirrors the Node.js
        //   sync API names so existing snippets that assume Node mostly
        //   work. Path-traversal isn't restricted (the iOS sandbox
        //   already blocks anything outside the app container).
        let fs = JSValue(newObjectIn: ctx)!
        let readFile: @convention(block) (String) -> String? = { path in
            try? String(contentsOfFile: Self.resolvePath(path), encoding: .utf8)
        }
        let writeFile: @convention(block) (String, String) -> Bool = { path, content in
            do {
                let url = URL(fileURLWithPath: Self.resolvePath(path))
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch { return false }
        }
        let exists: @convention(block) (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: Self.resolvePath(path))
        }
        let readdir: @convention(block) (String) -> [String] = { path in
            (try? FileManager.default.contentsOfDirectory(atPath: Self.resolvePath(path))) ?? []
        }
        let unlink: @convention(block) (String) -> Bool = { path in
            do { try FileManager.default.removeItem(atPath: Self.resolvePath(path)); return true }
            catch { return false }
        }
        fs.setObject(unsafeBitCast(readFile,  to: AnyObject.self), forKeyedSubscript: "readFileSync"  as NSString)
        fs.setObject(unsafeBitCast(writeFile, to: AnyObject.self), forKeyedSubscript: "writeFileSync" as NSString)
        fs.setObject(unsafeBitCast(exists,    to: AnyObject.self), forKeyedSubscript: "existsSync"    as NSString)
        fs.setObject(unsafeBitCast(readdir,   to: AnyObject.self), forKeyedSubscript: "readdirSync"   as NSString)
        fs.setObject(unsafeBitCast(unlink,    to: AnyObject.self), forKeyedSubscript: "unlinkSync"    as NSString)
        ctx.setObject(fs, forKeyedSubscript: "fs" as NSString)

        // ─ Documents path constant — mirrors Node's __dirname /
        //   process.cwd() habits but pins to the writable area.
        let docs = (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? "")
        ctx.evaluateScript("""
            globalThis.__documents__ = \(JSEngine.jsString(docs));
            globalThis.process = { platform: 'ios', version: 'codebench-jsc', env: {},
                                   cwd: function () { return __documents__; } };
        """)
    }

    // MARK: Eval bridge

    private func startSignalWatcher() {
        guard pollTimer == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05,
                                                    repeats: true) { [weak self] _ in
                self?.checkForJSEvalRequest()
            }
        }
    }

    private func checkForJSEvalRequest() {
        let req = signalDir.appending("js_eval_request.txt")
        guard FileManager.default.fileExists(atPath: req),
              let raw = try? String(contentsOfFile: req, encoding: .utf8) else {
            return
        }
        try? FileManager.default.removeItem(atPath: req)
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["id"] as? String,
              let src = obj["src"] as? String else {
            return
        }
        if let r = obj["reset"] as? Bool, r { reset() }

        // Capture the per-eval stdout into a fresh buffer; restore prior
        // contents on exit so an outer Python script that batches multiple
        // evals still sees consistent ordering.
        let saved = stdoutBuffer
        stdoutBuffer = ""

        var ok = true
        var resultJSON: String = "null"
        var errorMsg: String = ""
        var errorStack: String = ""

        if let value = context.evaluateScript(src) {
            if let exc = context.exception {
                ok = false
                errorMsg = exc.toString() ?? "(unknown)"
                errorStack = exc.objectForKeyedSubscript("stack")?.toString() ?? ""
                context.exception = nil
            } else {
                resultJSON = JSEngine.jsonRepr(value)
            }
        }

        let captured = stdoutBuffer
        stdoutBuffer = saved

        let resp: [String: Any] = ok
            ? ["ok": true,  "stdout": captured, "result": resultJSON]
            : ["ok": false, "stdout": captured, "error": errorMsg, "stack": errorStack]
        let respPath = signalDir.appending("js_eval_resp_\(id).txt")
        if let respData = try? JSONSerialization.data(withJSONObject: resp) {
            let tmp = respPath + ".tmp"
            try? respData.write(to: URL(fileURLWithPath: tmp))
            try? FileManager.default.moveItem(atPath: tmp, toPath: respPath)
        }
    }

    // MARK: Helpers

    /// JSON-encode a JS value the same way `JSON.stringify(x, null, 2)`
    /// would on the JS side, but tolerant of cycles / non-serialisable
    /// types — falls back to .toString() for those.
    private static func jsonRepr(_ v: JSValue) -> String {
        if v.isUndefined { return "undefined" }
        // Use the JSContext's own JSON.stringify for fidelity.
        let ctx = v.context!
        let json = ctx.objectForKeyedSubscript("JSON")!
        let stringified = json.objectForKeyedSubscript("stringify")!
            .call(withArguments: [v as Any, NSNull(), 2])
        if let s = stringified?.toString(), s != "undefined" { return s }
        return v.toString() ?? "null"
    }

    /// Console-friendly stringification — uses JSON.stringify for objects,
    /// falls back to .toString() for primitives so `console.log(1, "x")`
    /// produces `1 x` and not `1 "x"`.
    private static func stringify(_ v: JSValue) -> String {
        if v.isString { return v.toString() ?? "" }
        if v.isNumber || v.isBoolean || v.isNull || v.isUndefined {
            return v.toString() ?? ""
        }
        return jsonRepr(v)
    }

    /// Resolve a relative path against ~/Documents. Absolute paths pass
    /// through (the iOS sandbox handles access control).
    private static func resolvePath(_ p: String) -> String {
        if p.hasPrefix("/") { return p }
        let docs = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true).first ?? ""
        return (docs as NSString).appendingPathComponent(p)
    }

    /// Quote a Swift string for safe injection into a JS literal.
    private static func jsString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let json = String(data: d, encoding: .utf8) else { return "\"\"" }
        // strip the surrounding [ ]
        return String(json.dropFirst().dropLast())
    }
}
