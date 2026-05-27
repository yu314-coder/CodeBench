import UIKit
import WebKit

/// Spinning up a fresh WKWebView takes 150–400 ms on iPad — almost
/// entirely WebContent process launch + JS context init. Doing it
/// lazily on the first preview means the user waits half a second
/// staring at a blank pane. We instead create one WKWebView at app
/// startup, off the critical path, and hand it over when the
/// preview pane needs one.
///
/// The pool only keeps ONE warm instance — more would waste RAM
/// for very little additional speedup. The pool refills itself
/// asynchronously after each take().
final class WebViewWarmupPool {
    static let shared = WebViewWarmupPool()

    private var warm: WKWebView?
    private let queue = DispatchQueue(label: "WebViewWarmupPool", qos: .utility)

    private init() {}

    /// Call once from app launch. Idempotent — subsequent calls
    /// are no-ops unless the pool is empty.
    func warmUp() {
        queue.async { [weak self] in
            DispatchQueue.main.async { self?.refill() }
        }
    }

    /// Return the warm WebView (or create a fresh one if the pool
    /// is empty). Always asynchronously refills the pool afterward
    /// so the next caller gets a hot instance too.
    func take(configure: ((WKWebViewConfiguration) -> Void)? = nil) -> WKWebView {
        let wv: WKWebView
        if let warm = warm {
            self.warm = nil
            wv = warm
        } else {
            let cfg = WKWebViewConfiguration()
            cfg.allowsInlineMediaPlayback = true
            configure?(cfg)
            wv = WKWebView(frame: .zero, configuration: cfg)
        }
        DispatchQueue.main.async { [weak self] in self?.refill() }
        return wv
    }

    private func refill() {
        guard warm == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let wv = WKWebView(frame: .zero, configuration: cfg)
        // Prime by loading a trivial blank HTML — this forces the
        // WebContent process to fully spin up so the first real
        // load is instant. The about:blank trick alone doesn't
        // start the JS context.
        wv.loadHTMLString("<html><body></body></html>", baseURL: nil)
        warm = wv
    }
}
