import UIKit
import WebKit

/// A WKWebView-hosted Monaco editor with Python IntelliSense.
/// Bridges to Swift via WKScriptMessageHandler for text-change notifications
/// and `resolveRequest` queries that hit the Python daemon for docstrings/signatures.
final class MonacoEditorView: UIView {

    // MARK: - Public API

    /// Fired whenever the editor's text changes (debounced by Monaco, ~150ms).
    var onTextChanged: ((String) -> Void)?
    /// Fired when the editor finishes loading and is ready to accept code.
    var onEditorReady: (() -> Void)?
    /// The most recent text the editor reported (mirror, to avoid async gets on the hot path).
    private(set) var currentText: String = ""

    // MARK: - Internals

    let webView: WKWebView
    private var isReady = false
    private var pendingSetCode: (code: String, language: String)?

    override init(frame: CGRect) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        let ucc = WKUserContentController()
        config.userContentController = ucc
        // Allow WebGL/workers for Monaco
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.098, green: 0.102, blue: 0.114, alpha: 1)

        ucc.add(self, name: "editor")
        setupView()
        loadEditor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setupView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        // KEEP the outer scrollView enabled — touch/pointer events flow
        // through it to Monaco's internal DOM scrollHandler. Disabling
        // it was silently swallowing two-finger-pan / wheel-scroll /
        // cursor-drag events on Mac Catalyst and iPad, so Monaco could
        // never see them. The body has `overflow: hidden` so the
        // scrollView itself never actually scrolls — Monaco's internal
        // div does. Directional locks stay off so horizontal pan
        // (wide lines) works too.
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.delaysContentTouches = false  // selection gestures fire instantly
        webView.scrollView.canCancelContentTouches = false
        // Allow long-press / drag text selection — WKWebView treats
        // selection gestures through its scrollView by default; we
        // don't need to do anything special here, but make damn sure
        // nothing we set later accidentally gates it.
        webView.allowsLinkPreview = false       // don't steal long-press
        webView.isUserInteractionEnabled = true

        // Inspectable in debug builds so you can Safari-inspect Monaco
        // (right-click → Inspect Element) — invaluable for diagnosing
        // selection/scroll misbehaviour. No-op on release.
        #if DEBUG
        if #available(iOS 16.4, macCatalyst 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func loadEditor() {
        guard let url = Bundle.main.url(forResource: "editor", withExtension: "html") else {
            print("[MonacoEditor] editor.html not found in bundle")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // MARK: - JS → Swift commands

    /// Replace the editor's code and set the language mode.
    func setCode(_ code: String, language: String = "python") {
        guard isReady else {
            pendingSetCode = (code, language)
            return
        }
        let escaped = escapeForTemplate(code)
        webView.evaluateJavaScript("window.__editor.setCode(`\(escaped)`, '\(language)')")
        currentText = code
    }

    /// Insert (replace current selection with) a code block. Used for "Apply to Editor".
    func insertCode(_ code: String) {
        guard isReady else { return }
        let escaped = escapeForTemplate(code)
        webView.evaluateJavaScript("window.__editor.insertCode(`\(escaped)`)")
    }

    /// Get the current text asynchronously.
    func getText(completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("window.__editor.getText()") { [weak self] result, _ in
            let text = result as? String ?? self?.currentText ?? ""
            completion(text)
        }
    }

    /// Push the Python symbol index to JS for completions on `np.`, `plt.`, etc.
    func pushSymbolIndex() {
        guard isReady else { return }
        // Build: { modules: { "numpy": { "array": 3, ...}, ... } }
        var payload: [String: [String: Int]] = [:]
        for (mod, kindMap) in PythonSymbolIndex.shared.moduleKinds {
            var m: [String: Int] = [:]
            for (name, kind) in kindMap { m[name] = kind.rawValue }
            payload[mod] = m
        }
        let wrapper: [String: Any] = ["modules": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__editor.setSymbolIndex(\(json))")
    }

    // MARK: - Helpers

    /// Escape for JS template literal: backslash, backtick, `${`, and carriage returns.
    private func escapeForTemplate(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }
}

// MARK: - WKScriptMessageHandler

extension MonacoEditorView: WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "editor",
              let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }

        switch kind {
        case "ready":
            isReady = true
            onEditorReady?()
            // Apply any setCode queued before ready
            if let pending = pendingSetCode {
                pendingSetCode = nil
                setCode(pending.code, language: pending.language)
            }
            // Push symbol index now that JS is ready
            pushSymbolIndex()

        case "textChanged":
            if let text = body["text"] as? String {
                currentText = text
                onTextChanged?(text)
            }

        case "resolveRequest":
            handleResolveRequest(body)

        case "clipboardCopy":
            // Monaco sent selected text on Cmd+C/Cmd+X. Write to the
            // system pasteboard so it's available to other apps + the
            // iOS share sheet. Cut's buffer-side removal happens on
            // the JS side before this message arrives.
            if let text = body["text"] as? String, !text.isEmpty {
                UIPasteboard.general.string = text
            }

        case "clipboardPasteRequest":
            // Monaco wants to paste. Read the pasteboard and send the
            // text back via window.__editor.pasteFromClipboard(text).
            let text = UIPasteboard.general.string ?? ""
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            webView.evaluateJavaScript("window.__editor.pasteFromClipboard(`\(escaped)`)")

        default:
            break
        }
    }

    private func handleResolveRequest(_ body: [String: Any]) {
        guard let id = body["id"] as? String,
              let qualifier = body["qualifier"] as? String,
              let name = body["name"] as? String else { return }
        let item = CompletionItem(label: name, kind: .function, detail: qualifier, module: qualifier)
        IntelliSenseEngine.shared.resolve(item) { [weak self] resolved in
            let sig = (resolved.signature ?? "")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            let doc = (resolved.documentation ?? "")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            let js = "window.__editor.resolveResponse('\(id)', `\(sig)`, `\(doc)`)"
            self?.webView.evaluateJavaScript(js)
        }
    }
}
