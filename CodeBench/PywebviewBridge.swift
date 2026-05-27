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
@objc class PywebviewBridge: NSObject, WKScriptMessageHandler,
                              WKScriptMessageHandlerWithReply,
                              WKNavigationDelegate {

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

    /// Pending reply handlers, keyed by call-id. Each entry is the
    /// closure WebKit gave us via WKScriptMessageHandlerWithReply —
    /// invoking it resolves the JS-side Promise that postMessage
    /// returned. Populated by didReceive(message:replyHandler:),
    /// drained by drainApiResponses() when Python writes the
    /// response file. Lock-protected because drain runs on the timer
    /// thread and didReceive runs on the main thread.
    private var pendingReplies: [Int: (Any?, String?) -> Void] = [:]
    private let pendingLock = NSLock()
    private var nextCallId: Int = 1

    private override init() {
        super.init()
    }

    // MARK: Lifecycle

    /// Apply the bridge to a freshly-constructed `WKWebViewConfiguration`.
    /// Call from the outputWebView's lazy initializer (BEFORE the WKWebView
    /// is built) so the bootstrap script runs at document-start of every
    /// navigation, including the very first one.
    @objc static func configure(_ config: WKWebViewConfiguration) {
        // Two handlers:
        //   "pywebview"      — legacy postMessage path (no reply,
        //                       caller manages id+pending table). Kept
        //                       for events / one-way notifications.
        //   "pywebviewReply" — iOS 14+ Promise-returning handler.
        //                       JS gets a real Promise that Swift
        //                       resolves directly via replyHandler;
        //                       no second postMessage round-trip back
        //                       into JS. THIS is what eliminates the
        //                       per-call latency the user complained
        //                       about.
        config.userContentController.add(shared, name: "pywebview")
        config.userContentController.addScriptMessageHandler(
            shared, contentWorld: .page, name: "pywebviewReply")
        config.userContentController.addUserScript(bootstrapScript())

        // ── Performance knobs the bare config was missing ──────────
        //
        // The user reported pywebview pages "still slow even after
        // the polling fix." The bridge round-trip is no longer the
        // bottleneck (~12 ms now); what's left is the WebKit pipeline.
        // These knobs together reduce per-call render+JS overhead by
        // skipping work the bare config opted into by default.

        // Shared process pool — every pywebview WKWebView gets the
        // same WebContent process group. Big win for navigation: the
        // V8/JIT caches, image decoders, font cache, and HTTP cache
        // stay warm across windows + reloads. Without this, every
        // `load_html` or `load_url` from Python spins a cold pool.
        config.processPool = sharedProcessPool

        // Persistent website data store — keeps cached CSS/JS/images
        // between page loads. Default is .default() but some setups
        // accidentally use ephemeral; make it explicit.
        config.websiteDataStore = .default()

        // Media: allow inline playback without a user gesture so the
        // page can start animations/audio immediately. iOS default
        // requires a tap which delays first paint of any media-rich
        // page.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true

        // Data detectors: by default WKWebView scans every text node
        // for phone numbers, addresses, dates, links to underline
        // them. Skip it — pywebview apps render their own UI and
        // don't need automatic linkification, and the scan is per-
        // text-node (linear in DOM size on every layout).
        config.dataDetectorTypes = []

        // JavaScript content: explicit. The default .allowsContentJavaScript
        // is true, but documenting it here so a future editor doesn't
        // accidentally disable it via a stricter preferences object.
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        prefs.preferredContentMode = .recommended
        config.defaultWebpagePreferences = prefs

        // Element-level fullscreen (DOM Fullscreen API) — disabled by
        // default on iOS WKWebView. Without this, calling
        // `el.requestFullscreen()` from JS silently no-ops, which is
        // why pywebview apps' fullscreen buttons appeared dead. Public
        // API on iOS 16+; for older iOS we fall back to the private
        // KVC key WebKit has shipped for years.
        if #available(iOS 16.0, *) {
            config.preferences.isElementFullscreenEnabled = true
        } else {
            config.preferences.setValue(true, forKey: "fullScreenEnabled")
        }

        // User agent string — many sites detect "WebKit" without a
        // browser name and serve degraded mobile fallbacks. Setting
        // this to something CodeBench-flavoured but standard means
        // pages get the desktop-class HTML/CSS path.
        config.applicationNameForUserAgent = "CodeBench/1.0 Safari/605.1.15"
    }

    /// Shared process pool for every pywebview WKWebView. Sharing
    /// the pool keeps V8 JIT caches, font/image decoders, and the
    /// HTTP cache warm across windows + navigations. Cold start of
    /// a new pool (per default config) is ~150-300 ms on iPad which
    /// the user sees as lag on every `webview.load_url(...)` call.
    private static let sharedProcessPool = WKProcessPool()

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

          // Prefer the WKScriptMessageHandlerWithReply path on iOS 14+ —
          // postMessage returns a real Promise that Swift resolves
          // directly via replyHandler, no second JS round-trip needed.
          // Falls back to the legacy id+pending table on older OSes
          // where pywebviewReply isn't registered.
          var hasReply = !!(window.webkit
                             && window.webkit.messageHandlers
                             && window.webkit.messageHandlers.pywebviewReply);

          function callApi(method, args) {
            if (hasReply) {
              // Promise-returning postMessage. Swift's replyHandler
              // resolves it; if Python responds with an error string
              // Swift rejects, which surfaces as a JS Promise rejection.
              return window.webkit.messageHandlers.pywebviewReply
                          .postMessage({method: method, args: args})
                          .then(function (raw) {
                            if (typeof raw === 'string') {
                              try { return JSON.parse(raw); }
                              catch (_e) { return raw; }
                            }
                            return raw;
                          });
            }
            // Legacy path — keep as a backstop for any environment
            // where the reply handler isn't available.
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
            _hasReplyHandler: hasReply,
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

          // pywebviewready dispatch — defer until DOMContentLoaded
          // AND patch addEventListener to replay for late listeners.
          //
          // Was: dispatched synchronously here, at WKUserScript's
          // atDocumentStart phase. That fires the event BEFORE any
          // page <script> tags have parsed — including the deferred
          // ones (the ones a real-world SPA uses for app init). Pages
          // that do `window.addEventListener('pywebviewready', ...)`
          // from a deferred script never see the event because it's
          // already gone by the time addEventListener runs. Symptom:
          // Manim Studio's tab pills never get click handlers (their
          // bind code lives inside a pywebviewready listener), so
          // clicking tabs does nothing.
          //
          // Real pywebview fires this after window.onload. We match
          // that semantics PLUS handle late-registered listeners by
          // monkeypatching addEventListener to replay the event for
          // any listener added after the dispatch. One small change
          // here unblocks every pywebview-style page we host.
          window._pywebviewReadyFired = false;
          var _pywebviewFire = function () {
            if (window._pywebviewReadyFired) return;
            window._pywebviewReadyFired = true;
            try { window.dispatchEvent(new Event('pywebviewready')); }
            catch (_e) {}
          };
          var _origAdd = window.addEventListener.bind(window);
          window.addEventListener = function (type, fn, opts) {
            _origAdd(type, fn, opts);
            // Replay for late listeners — if a script registers a
            // pywebviewready handler AFTER we've already fired the
            // event (typical for deferred / module scripts), invoke
            // it once with a synthetic Event so it doesn't miss the
            // initialization signal.
            if (type === 'pywebviewready' && window._pywebviewReadyFired) {
              try { fn(new Event('pywebviewready')); }
              catch (_e) {}
            }
          };
          // Schedule the dispatch:
          //   • If still parsing the document, wait for DOMContentLoaded
          //     so deferred scripts have a chance to register listeners.
          //   • If the document is already interactive/complete (e.g.
          //     the bridge was reinjected on a navigation that already
          //     resolved), fire on the next tick.
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded',
              function () { setTimeout(_pywebviewFire, 0); });
          } else {
            setTimeout(_pywebviewFire, 0);
          }
        })();
        """
        return WKUserScript(source: src,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: false)
    }

    // MARK: WKScriptMessageHandler — JS → Swift (legacy postMessage path)

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

    // MARK: WKScriptMessageHandlerWithReply — JS → Swift (Promise-returning)
    //
    // iOS 14+. JS calls
    //     const result = await window.webkit.messageHandlers.pywebviewReply
    //                                    .postMessage({method: 'foo', args: [...]});
    // and gets a Promise that WebKit resolves directly when we invoke
    // `replyHandler`. Previous flow needed a SECOND postMessage path
    // (`window.pywebview._resolve(id, val)` via evaluateJavaScript)
    // which added 5-15 ms of pure round-trip latency per call. That
    // second leg is gone — replyHandler resolves the JS Promise
    // synchronously from native, no JS bridge re-entry needed.
    //
    // We still write the request to the file IPC channel for Python's
    // dispatcher; the difference is the RESPONSE path: instead of
    // Swift polling response files and calling _resolve() back into
    // JS, we capture the replyHandler keyed by call-id, and
    // drainApiResponses pulls the matching reply out of pendingReplies
    // and calls it directly.
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.name == "pywebviewReply" else {
            replyHandler(nil, "wrong handler name")
            return
        }
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            replyHandler(nil, "malformed message body")
            return
        }
        let args = body["args"] as? [Any] ?? []

        // Serialize args as JSON for direct in-process dispatch.
        let argsJson: String
        do {
            let data = try JSONSerialization.data(withJSONObject: args)
            argsJson = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            replyHandler(nil, "args serialize failed: \(error.localizedDescription)")
            return
        }

        // FAST PATH: dispatch directly into Python via the C API on a
        // background queue. No file IPC, no Python dispatcher polling,
        // no Swift response polling. Latency drops from ~13 ms to
        // ~1-2 ms per call (when Python isn't busy with user code).
        //
        // Background queue because PyGILState_Ensure() blocks if user
        // code holds the GIL — we must NOT do that on the main thread
        // or the WebContent process freezes during model inference,
        // long-running pip installs, etc.
        DispatchQueue.global(qos: .userInteractive).async {
            let (resultJson, errorMsg) = PythonRuntime.shared
                .dispatchJsApiInline(method: method, argsJson: argsJson)
            // Reply must run on the main thread (WKWebView contract).
            DispatchQueue.main.async {
                if let err = errorMsg {
                    replyHandler(nil, err)
                } else {
                    // Pass the JSON string back. The bootstrap JS
                    // wrapper does JSON.parse on string responses.
                    replyHandler(resultJson ?? "null", nil)
                }
            }
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
        // Record visit for the hidden browser-history viewer. Title is
        // resolved async — recordVisit upserts when updateTitle lands.
        if !url.isEmpty {
            BrowserDataStore.shared.recordVisit(url: url, title: webView.title ?? "")
            webView.evaluateJavaScript("document.title") { result, _ in
                if let t = result as? String, !t.isEmpty {
                    BrowserDataStore.shared.updateTitle(url: url, title: t)
                }
            }
        }
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

    /// WKWebView runs its rendering / JS in a separate ``WebContent``
    /// process. iOS kills that process under memory pressure — most
    /// commonly when the user slides to another app for a while and
    /// comes back. The Mach process behind ``webView`` is now dead;
    /// without intervention the view shows a blank / dark page.
    /// Post a notification so ``CodeEditorViewController`` (or any
    /// other host) can re-issue the last load. Calling
    /// ``webView.reload()`` here doesn't work for content loaded via
    /// ``loadHTMLString`` (there's no source URL to reload from) —
    /// the host needs to re-load from its own path/state.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("[PywebviewBridge] WebContent process terminated for %@ — host should reload",
              webView.url?.absoluteString ?? "<no url>")
        writeEvent(["event": "web_content_died",
                    "url": webView.url?.absoluteString ?? ""])
        NotificationCenter.default.post(
            name: Notification.Name("CodeBench.previewWebContentDied"),
            object: webView)
        forwardNavigationDelegate?
            .webViewWebContentProcessDidTerminate?(webView)
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
            guard let self = self else { return }
            // 10 ms (was 50 ms). Each tick is one stat per request
            // file (~20 stats/sec total) — negligible CPU cost. Net
            // effect: average JS API round-trip latency drops from
            // ~58 ms to ~12 ms (5× speedup on user-perceived UI lag
            // for pywebview apps that do many small API calls).
            let t = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
                self?.drainEvalRequests()
                self?.drainApiResponses()
            }
            // .common runloop mode — when the user drags the preview
            // pane resizer, scrolls the terminal, or interacts with
            // any UI element, the runloop enters .tracking which
            // pauses default-mode timers. That used to make Python
            // scripts using pywebview "freeze" mid-drag (the API
            // round-trip stalled until the user lifted their finger).
            // .common includes both .default and .tracking so the
            // poller keeps firing through every gesture phase.
            RunLoop.main.add(t, forMode: .common)
            self.pollTimer = t
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
        // Wrap so we always get a JSON-stringifiable return value AND
        // multi-statement scripts (`a(); b()`) work the same as a
        // single expression. Previous version wrapped as
        //     return (\(src))
        // which made `return (a(); b());` a syntax error → silent
        // "JavaScript exception occurred" for any pywebview script
        // with more than one statement (and even some single-
        // statement assignments where the value contained chars that
        // changed parsing). Now we encode src as a JS string literal
        // (via JSON serialization for guaranteed-correct escaping)
        // and feed it to eval(): eval handles both expression and
        // statement input, returning the value of the last expression.
        let scriptLiteral: String
        if let data = try? JSONSerialization.data(withJSONObject: src,
            options: [.fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) {
            scriptLiteral = s
        } else {
            // Extremely unlikely (src is a String, JSON-encodes fine)
            // but fall back to manual escaping just in case.
            let escaped = src
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            scriptLiteral = "\"\(escaped)\""
        }
        let wrapped = "JSON.stringify((function(){ return eval(\(scriptLiteral)); })())"
        webView.evaluateJavaScript(wrapped) { [weak self] result, error in
            if let err = error {
                self?.writeEvalResp(id: id, ok: false, result: nil,
                                    error: err.localizedDescription)
                return
            }
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

    /// Python answered a previously-issued JS api call. Two paths,
    /// keyed by call-id:
    ///
    ///   • Reply-handler path (iOS 14+, the fast path now): pop the
    ///     captured `replyHandler` from `pendingReplies` and invoke
    ///     it directly. WebKit resolves the JS-side Promise without
    ///     a second JS bridge re-entry. Roughly 5-15 ms saved per
    ///     call vs the legacy evaluateJavaScript path.
    ///
    ///   • Legacy path: inject `pywebview._resolve(id, raw)` via
    ///     `evaluateJavaScript`. Used when the JS page hit the
    ///     legacy postMessage handler (fallback for the rare case
    ///     `pywebviewReply` isn't registered, e.g. iOS 13 — though
    ///     the project's deployment target is iOS 14+).
    ///
    /// One response file per id so concurrent api calls don't trample
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
            let idStr = String(name.dropFirst("pywebview_api_resp_".count)
                                   .dropLast(".txt".count))
            let ok = (obj["ok"] as? Bool) ?? false
            let payload = ok ? (obj["result"] as? String) ?? "null"
                              : (obj["error"]  as? String) ?? "(unknown)"

            // Fast path — was this an idsfdsdf from the reply-handler
            // route? Pop the closure and invoke directly.
            if let id = Int(idStr) {
                pendingLock.lock()
                let reply = pendingReplies.removeValue(forKey: id)
                pendingLock.unlock()
                if let reply = reply {
                    if ok {
                        // Pass the raw JSON string to JS. The JS
                        // wrapper does JSON.parse so the consumer
                        // gets the typed value.
                        DispatchQueue.main.async { reply(payload, nil) }
                    } else {
                        DispatchQueue.main.async { reply(nil, payload) }
                    }
                    continue
                }
            }

            // Legacy path — inject _resolve / _reject via evaluateJS.
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
