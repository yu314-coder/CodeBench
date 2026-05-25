import UIKit
import WebKit
import UniformTypeIdentifiers

/// Adds real-browser behavior to a WKWebView that would otherwise silently
/// drop everything Safari handles by default.
///
/// What WKWebView does NOT do out of the box (all break Dash / Streamlit /
/// pywebview pages that worked fine on desktop):
///
///   1. `<a target="_blank">` and `window.open(url)` — return nil from
///      createWebViewWith and the link does nothing. We instead load the
///      requested URL in the same web view (no new-tab UX in a preview
///      pane is fine — just don't break navigation).
///   2. `alert(msg)` / `confirm(msg)` / `prompt(msg, default)` — silently
///      no-op. We surface them as UIAlertController dialogs so the page
///      behaves the way authors expected.
///   3. File downloads (`<a download>`, Content-Disposition: attachment,
///      navigation to a binary MIME). We accept the download via
///      WKDownloadDelegate (iOS 14.5+), save to `$TMPDIR/cb-downloads/`,
///      then present a UIDocumentInteractionController so the user can
///      Share/Open-In.
///   4. External-scheme URLs (mailto:, tel:, sms:, itms:, etc.) — WKWebView
///      tries to load them as http and fails. We hand them to UIApplication
///      .open(_:) so the system app handles them.
///
/// Usage:
///   let helper = BrowserBehaviorDelegate(host: someViewController)
///   webView.uiDelegate = helper
///   webView.navigationDelegate = helper
///   // Retain `helper` for the lifetime of the web view — WKWebView's
///   // delegate properties are weak. The host controller is the natural
///   // owner. See attachBrowserBehavior(...) below.
final class BrowserBehaviorDelegate: NSObject, WKUIDelegate,
                                     WKNavigationDelegate,
                                     WKDownloadDelegate,
                                     UIDocumentInteractionControllerDelegate {
    /// View controller used to present alerts / share sheets.
    weak var host: UIViewController?

    /// Hold strong refs to downloads so they don't get released while in flight.
    private var inFlightDownloads: [WKDownload: URL] = [:]
    private var docInteraction: UIDocumentInteractionController?

    init(host: UIViewController) {
        self.host = host
    }

    // MARK: - WKUIDelegate: target="_blank" / window.open

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Default WKWebView returns nil → link silently does nothing.
        // For a preview pane there's no second view to send it to, so
        // load the requested URL in this same web view.
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // MARK: - WKUIDelegate: alert / confirm / prompt

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

    // MARK: - WKNavigationDelegate: external schemes + downloads

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        // mailto:, tel:, sms:, itms-apps:, maps:, etc. — hand to system.
        if let scheme = url.scheme?.lowercased(),
           !["http", "https", "file", "about", "blob", "data",
             "ws", "wss"].contains(scheme),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:])
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Detect downloads: explicit Content-Disposition: attachment OR
        // a non-renderable MIME type. WKWebView can't display .csv, .zip,
        // .pdf reliably, so route them through the download path so the
        // user can save/share them.
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let cd = (httpResponse.allHeaderFields["Content-Disposition"]
                      as? String ?? "").lowercased()
            let mime = httpResponse.mimeType?.lowercased() ?? ""
            let renderableMime = mime.hasPrefix("text/") ||
                                 mime.hasPrefix("image/") ||
                                 mime.hasPrefix("video/") ||
                                 mime.hasPrefix("audio/") ||
                                 mime.contains("html") ||
                                 mime.contains("xml") ||
                                 mime.contains("json") ||
                                 mime.contains("javascript") ||
                                 mime.contains("css") ||
                                 mime == "application/pdf"  // WKWebView renders PDF
            let wantsDownload = cd.contains("attachment") ||
                                !navigationResponse.canShowMIMEType ||
                                (!renderableMime && !mime.isEmpty)
            if wantsDownload {
                decisionHandler(.download)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dlDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cb-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dlDir,
                                                 withIntermediateDirectories: true)
        // Avoid collision with prior download of same name
        var dest = dlDir.appendingPathComponent(suggestedFilename)
        var i = 1
        let stem = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            let name = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            dest = dlDir.appendingPathComponent(name)
            i += 1
        }
        inFlightDownloads[download] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = inFlightDownloads.removeValue(forKey: download),
              let host = host else { return }
        DispatchQueue.main.async {
            let dic = UIDocumentInteractionController(url: url)
            dic.delegate = self
            self.docInteraction = dic
            // Try Quick-Look first; fall back to share sheet if that fails.
            if !dic.presentPreview(animated: true) {
                dic.presentOptionsMenu(from: host.view.bounds,
                                       in: host.view, animated: true)
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error,
                  resumeData: Data?) {
        inFlightDownloads.removeValue(forKey: download)
        DispatchQueue.main.async {
            self.present(alertWithMessage:
                "Download failed: \(error.localizedDescription)",
                         title: "Download error",
                         actions: [.cancel(title: "OK") {}])
        }
    }

    func documentInteractionControllerViewControllerForPreview(
        _ controller: UIDocumentInteractionController
    ) -> UIViewController {
        return host ?? UIViewController()
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
            // No host → just fire the first action so we don't deadlock
            // the page (it's waiting on completionHandler).
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
    /// Convenience: attach a BrowserBehaviorDelegate as both ui+navigation
    /// delegate. Returns the helper so the caller can retain it (WKWebView
    /// holds delegates weakly, so the helper would otherwise vanish).
    @discardableResult
    func attachBrowserBehavior(host: UIViewController) -> BrowserBehaviorDelegate {
        let helper = BrowserBehaviorDelegate(host: host)
        self.uiDelegate = helper
        self.navigationDelegate = helper
        self.allowsBackForwardNavigationGestures = true
        return helper
    }
}
