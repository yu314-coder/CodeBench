import Foundation
import WebKit

/// Two-way bridge between the pywebview Python shim and the in-app
/// WKWebView. Lets `webview.create_window(..., js_api=PythonObj)` and
/// `w.evaluate_js("...")` actually do what real pywebview does:
///
///   • JS → Python — pages call `pywebview.api.foo(arg)` and get a
///     real Promise that resolves with Python's return value.
///   • Python → JS — `evaluate_js("expr")` returns the actual JS value
///     (stringified via JSON.stringify) instead of always None.
///   • Window events — `pywebviewready`, `did-finish-load` get bridged
///     so Python can register on-load callbacks.
///
/// Wire-protocol — every payload is one JSON object per file, atomic
/// write via tmp + rename:
///
///   $TMPDIR/latex_signals/
///     pywebview_eval_request.txt        Python: "eval this and tell me the result"
///                                       {"id": "<hex>", "src": "..."}
///     pywebview_eval_resp_<id>.txt      Swift: "here's the result"
///                                       {"ok": true, "result": "<JSON>"} or
///                                       {"ok": false, "error": "..."}
///     pywebview_api_call.txt            Swift: "JS asked Python for X"
///                                       {"id": <int>, "method": "foo", "args": [...]}
///     pywebview_api_resp_<id>.txt       Python: "here's the answer"
///                                       {"ok": true, "result": "<JSON>"} or
///                                       {"ok": false, "error": "..."}
///     pywebview_event.txt               Swift: page-lifecycle event
///                                       {"event": "loaded", "url": "..."}
///
/// Why files instead of a Unix socket: the existing LaTeXEngine timer
/// already polls this dir at 100 ms; one extra `checkForX()` call per
/// tick costs nothing, vs. opening a socket which needs lifetime
/// management across app suspend/resume.
@objc class PywebviewBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    static let shared = PywebviewBridge()

    /// The active output WebView. Set by CodeEditorViewController when
    /// it shows a page; weak so we don't keep it alive past its VC.
    weak var webView: WKWebView?

    /// User-set delegate to forward navigation events to (so CodeEditor's
    /// existing logic — if any — keeps firing). Currently the WKWebView
    /// has no delegate, so this stays nil; documented for future-proofing.
    weak var forwardNavigationDelegate: WKNavigationDelegate?

    private var pollTimer: Timer?
    private var signalDir: String { NSTemporaryDirectory().appending("latex_signals/") }
    private let bootSerial = "[PywebviewBridge]"

    private override init() {
        super.init()
    }

    // MARK: Lifecycle

    /// Apply the bridge to a freshly-constructed `WKWebViewConfiguration`.
    /// Call from the outputWebView's lazy initializer (BEFORE the WKWebView
    /// is built) so the bootstrap script runs at document-start of every
    /// navigation, including the very first one.
    @objc static func configure(_ config: WKWebViewConfiguration) {
        config.userContentController.add(shared, name: "pywebview")
        config.userContentController.addUserScript(bootstrapScript())
    }

    /// Called by CodeEditorViewController when the outputWebView shows
    /// pywebview content (so the bridge has a target for evaluate_js
    /// calls). Idempotent — safe to call on every show.
    @objc func bind(_ webView: WKWebView) {
        self.webView = webView
        // Take over navigation events to publish lifecycle to Python.
        // If something else already owns the delegate, stash it so we
        // can forward; current usage has nil, documented so future
        // editors don't get bitten.
        if let existing = webView.navigationDelegate, existing !== self {
            forwardNavigationDelegate = existing
        }
        webView.navigationDelegate = self
        startPolling()
    }

    /// Stop polling. Call from CodeEditorViewController.deinit if you
    /// want to be tidy — on app exit the timer dies anyway.
    @objc func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Bootstrap JS

    /// User-script source injected at document-start of every navigation.
    /// Defines `window.pywebview.api` as a Proxy that turns ANY property
    /// access into an async function that round-trips through Swift to
    /// Python. The Promise resolves when Swift calls `_resolve(id, val)`
    /// after Python responds.
    ///
    /// Idempotent: re-injection (e.g. iframe reload) checks `_installed`
    /// so we don't double-define the `api` object.
    private static func bootstrapScript() -> WKUserScript {
        let src = """
        (function () {
          if (window.pywebview && window.pywebview._installed) return;
          var nextId = 1;
          var pending = Object.create(null);

          function callApi(method, args) {
            return new Promise(function (resolve, reject) {
              var id = nextId++;
              pending[id] = { resolve: resolve, reject: reject };
              try {
                window.webkit.messageHandlers.pywebview.postMessage({
                  type: 'api_call', id: id, method: method, args: args
                });
              } catch (e) {
                delete pending[id];
                reject(e);
              }
            });
          }

          // Real pywebview's `api` is a plain object whose attributes
          // were set by Python via the js_api binding. We don't know
          // what methods Python registered, so we use a Proxy that
          // returns a callable for ANY property name. The actual
          // dispatch happens Python-side: missing methods come back
          // as a structured error.
          var apiProxy = new Proxy({}, {
            get: function (_t, name) {
              if (typeof name !== 'string') return undefined;
              // Hide internal symbols from naive enumeration.
              if (name === 'then' || name === 'toJSON') return undefined;
              return function () { return callApi(name, [].slice.call(arguments)); };
            }
          });

          window.pywebview = {
            api: apiProxy,
            token: '\(UUID().uuidString.prefix(16))',
            platform: 'codebench-ios',
            _installed: true,
            _pending: pending,
            _resolve: function (id, raw) {
              var p = pending[id]; if (!p) return;
              delete pending[id];
              try { p.resolve(JSON.parse(raw)); }
              catch (_e) { p.resolve(raw); }
            },
            _reject: function (id, err) {
              var p = pending[id]; if (!p) return;
              delete pending[id];
              p.reject(new Error(String(err)));
            }
          };

          // pywebviewready fires after the bridge is wired so user code
          // can `window.addEventListener('pywebviewready', ...)` to
          // know it's safe to call api methods.
          try { window.dispatchEvent(new Event('pywebviewready')); }
          catch (_e) {}
        })();
        """
        return WKUserScript(source: src,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: false)
    }

    // MARK: WKScriptMessageHandler — JS → Swift

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "pywebview" else { return }
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }
        switch type {
        case "api_call":
            handleApiCall(body)
        default:
            // Unknown types come from a future user-script extension;
            // log to Xcode console so we can see them while developing,
            // don't fail the page.
            print("\(bootSerial) unknown message type: \(type)")
        }
    }

    /// JS asked Python to run a registered js_api method. Forward to the
    /// Python shim by writing a request file; Python's dispatcher thread
    /// picks it up, calls the method, writes pywebview_api_resp_<id>.txt.
    private func handleApiCall(_ body: [String: Any]) {
        guard let id = body["id"] as? Int,
              let method = body["method"] as? String else {
            return
        }
        let args = body["args"] as? [Any] ?? []
        let payload: [String: Any] = ["id": id, "method": method, "args": args]
        let req = signalDir.appending("pywebview_api_call.txt")
        // Append-or-create — multiple concurrent api calls each write
        // one JSON line to the SAME file, Python reads-and-truncates
        // atomically. (Versus per-call files, which would race the
        // Python side's directory enumeration order.)
        let line: String
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            line = (String(data: data, encoding: .utf8) ?? "") + "\n"
        } catch {
            print("\(bootSerial) api_call serialize failed: \(error)"); return
        }
        if let h = FileHandle(forWritingAtPath: req)
            ?? createAndOpen(req)
        {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        }
    }

    private func createAndOpen(_ path: String) -> FileHandle? {
        try? FileManager.default.createDirectory(
            atPath: signalDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    // MARK: WKNavigationDelegate — page lifecycle

    func webView(_ webView: WKWebView, didFinish nav: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        writeEvent(["event": "loaded", "url": url])
        forwardNavigationDelegate?.webView?(webView, didFinish: nav)
    }

    func webView(_ webView: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
        writeEvent(["event": "load_error",
                    "url": webView.url?.absoluteString ?? "",
                    "error": error.localizedDescription])
        forwardNavigationDelegate?.webView?(webView, didFail: nav, withError: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
        writeEvent(["event": "load_error",
                    "url": webView.url?.absoluteString ?? "",
                    "error": error.localizedDescription])
        forwardNavigationDelegate?.webView?(webView, didFailProvisionalNavigation: nav, withError: error)
    }

    private func writeEvent(_ payload: [String: Any]) {
        let path = signalDir.appending("pywebview_event.txt")
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let line = (String(data: data, encoding: .utf8) ?? "") + "\n"
        if let h = FileHandle(forWritingAtPath: path)
            ?? createAndOpen(path)
        {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        }
    }

    // MARK: Eval pump — Python → JS

    private func startPolling() {
        guard pollTimer == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05,
                                                    repeats: true) { [weak self] _ in
                self?.drainEvalRequests()
                self?.drainApiResponses()
            }
        }
    }

    /// Python wants to evaluate JS in the live WebView and get the result.
    /// Read every queued request, evaluate against the bound webView,
    /// write the response with the same id.
    private func drainEvalRequests() {
        let req = signalDir.appending("pywebview_eval_request.txt")
        guard FileManager.default.fileExists(atPath: req),
              let raw = try? String(contentsOfFile: req, encoding: .utf8) else {
            return
        }
        try? FileManager.default.removeItem(atPath: req)
        // One JSON object per line — multiple Python threads / scripts
        // can pile up requests and we drain them all in arrival order.
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = obj["id"] as? String,
                  let src = obj["src"] as? String else {
                continue
            }
            evaluateAndRespond(id: id, src: src)
        }
    }

    private func evaluateAndRespond(id: String, src: String) {
        guard let webView = self.webView else {
            writeEvalResp(id: id, ok: false, result: nil,
                          error: "no webView bound — pywebview window not visible yet")
            return
        }
        // evaluateJavaScript completion is on the main thread; that's
        // where our timer fires anyway, so no thread juggling needed.
        // Wrap in JSON.stringify so we get a stable serialization for
        // arbitrary return types (objects, arrays, dates, etc).
        let wrapped = "JSON.stringify((function(){ return (\(src)); })())"
        webView.evaluateJavaScript(wrapped) { [weak self] result, error in
            if let err = error {
                self?.writeEvalResp(id: id, ok: false, result: nil,
                                    error: err.localizedDescription)
                return
            }
            // result is either a String (JSON) or NSNull when the
            // callback returned undefined (which JSON.stringify maps
            // to undefined → JS treats as null in our wrapper).
            let resultStr = result as? String ?? "null"
            self?.writeEvalResp(id: id, ok: true, result: resultStr, error: nil)
        }
    }

    private func writeEvalResp(id: String, ok: Bool, result: String?, error: String?) {
        let path = signalDir.appending("pywebview_eval_resp_\(id).txt")
        var payload: [String: Any] = ["ok": ok]
        if ok { payload["result"] = result ?? "null" }
        else  { payload["error"]  = error ?? "(unknown)" }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let tmp = path + ".tmp"
        try? data.write(to: URL(fileURLWithPath: tmp))
        try? FileManager.default.moveItem(atPath: tmp, toPath: path)
    }

    /// Python answered a previously-issued JS api call. Resolve (or
    /// reject) the JS Promise by injecting `pywebview._resolve(id, raw)`.
    /// One file per response so concurrent api calls don't trample
    /// each other's payloads.
    private func drainApiResponses() {
        guard let entries = try? FileManager.default
                .contentsOfDirectory(atPath: signalDir) else { return }
        for name in entries
            where name.hasPrefix("pywebview_api_resp_") && name.hasSuffix(".txt")
        {
            let path = signalDir.appending(name)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                try? FileManager.default.removeItem(atPath: path)
                continue
            }
            try? FileManager.default.removeItem(atPath: path)
            // Re-construct the id from the filename so we don't depend
            // on the Python side echoing it back inside the payload.
            let idStr = String(name.dropFirst("pywebview_api_resp_".count)
                                   .dropLast(".txt".count))
            let ok = (obj["ok"] as? Bool) ?? false
            let payload = ok ? (obj["result"] as? String) ?? "null"
                              : (obj["error"]  as? String) ?? "(unknown)"
            // Bracket the payload as a JS string-literal — let the page-
            // side `_resolve` JSON.parse it back into the real value.
            let escaped = jsString(payload)
            let js: String
            if ok {
                js = "window.pywebview && window.pywebview._resolve(\(idStr), \(escaped));"
            } else {
                js = "window.pywebview && window.pywebview._reject(\(idStr), \(escaped));"
            }
            self.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}
