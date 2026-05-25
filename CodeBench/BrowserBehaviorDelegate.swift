import UIKit
import WebKit

/// Minimal real-browser behavior for WKWebViews used as preview panes.
///
/// Scope deliberately narrow after a round of debugging where every
/// navigationDelegate method I added broke clicks in some subtle way
/// (Mac Catalyst especially — see https://developer.apple.com/forums/thread/659421).
///
/// What this implements:
///
///   1. `alert(msg)` / `confirm(msg)` / `prompt(msg, default)` — silently
///      no-op without a uiDelegate. We surface them as UIAlertController
///      dialogs so the page behaves the way authors expected.
///   2. `<a target="_blank">` and `window.open(url)` — return nil from
///      createWebViewWith and the link does nothing. We hand the URL to
///      UIApplication.open(_:) so Safari (or whichever default browser)
///      opens it. Matches the Mail / Messages / Notes embedded-preview
///      behavior.
///
/// What this DOES NOT do (intentional, after multiple breakage rounds):
///   - decidePolicyForNavigationAction (WKWebView's default .allow is
///     correct for the inline preview case)
///   - decidePolicyForNavigationResponse (used to trigger downloads,
///     but the MIME detection produced false positives that broke font
///     and ad-iframe loads, which in turn broke link click detection)
///   - WKDownloadDelegate plumbing (downloads stay native — files end
///     up in Safari via the createWebViewWith → UIApplication.open path)
final class BrowserBehaviorDelegate: NSObject, WKUIDelegate {
    /// View controller used to present alerts.
    weak var host: UIViewController?

    init(host: UIViewController) {
        self.host = host
    }

    // MARK: - target="_blank" / window.open → system browser

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        NSLog("[browser] createWebViewWith → opening externally: %@",
              url?.absoluteString ?? "<nil>")
        if let url = url, UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:])
        }
        return nil
    }

    // MARK: - alert / confirm / prompt → UIAlertController

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        present(alertWithMessage: message, title: alertTitle(for: frame),
                actions: [.cancel(title: "OK") { completionHandler() }])
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        present(alertWithMessage: message, title: alertTitle(for: frame),
                actions: [
                    .cancel(title: "Cancel") { completionHandler(false) },
                    .default(title: "OK")    { completionHandler(true) },
                ])
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let host = host else { completionHandler(nil); return }
        let alert = UIAlertController(title: alertTitle(for: frame),
                                      message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completionHandler(nil)
        })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text ?? defaultText)
        })
        host.present(alert, animated: true)
    }

    // MARK: - Alert helper

    private struct AlertAction {
        let title: String
        let style: UIAlertAction.Style
        let handler: () -> Void
        static func cancel(title: String, _ h: @escaping () -> Void) -> AlertAction {
            .init(title: title, style: .cancel, handler: h)
        }
        static func `default`(title: String, _ h: @escaping () -> Void) -> AlertAction {
            .init(title: title, style: .default, handler: h)
        }
    }

    private func present(alertWithMessage message: String, title: String,
                         actions: [AlertAction]) {
        guard let host = host else {
            actions.first?.handler(); return
        }
        DispatchQueue.main.async {
            let ac = UIAlertController(title: title, message: message,
                                       preferredStyle: .alert)
            for a in actions {
                ac.addAction(UIAlertAction(title: a.title, style: a.style) { _ in
                    a.handler()
                })
            }
            host.present(ac, animated: true)
        }
    }

    private func alertTitle(for frame: WKFrameInfo) -> String {
        return frame.request.url?.host ?? "Page"
    }
}

extension WKWebView {
    /// Attach uiDelegate ONLY (no navigationDelegate). The host VC must
    /// retain the returned helper — WKWebView holds delegates weakly.
    ///
    /// We deliberately do NOT set navigationDelegate. Doing so caused
    /// click breakage in multiple ways (Mac Catalyst quirks + interaction
    /// with PywebviewBridge's own navigationDelegate). The WKWebView
    /// default navigation behavior + PywebviewBridge handle navigation;
    /// we just handle the UI dialogs that have no default at all.
    @discardableResult
    func attachBrowserBehavior(host: UIViewController) -> BrowserBehaviorDelegate {
        let helper = BrowserBehaviorDelegate(host: host)
        self.uiDelegate = helper
        self.allowsBackForwardNavigationGestures = true
        NSLog("[browser] attached uiDelegate to %p (host=%@) — v4 build 2026-05-25",
              webView_pointer_for_log(self), String(describing: type(of: host)))
        return helper
    }
}

private func webView_pointer_for_log(_ wv: WKWebView) -> UnsafeRawPointer {
    return Unmanaged.passUnretained(wv).toOpaque()
}
