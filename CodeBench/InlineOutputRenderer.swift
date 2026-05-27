//
//  InlineOutputRenderer.swift
//  CodeBench
//
//  Accumulates inline rich-output cells (matplotlib figures, pandas
//  DataFrame HTML, plotly figures, PIL images) into a single scrolling
//  HTML page that the existing outputWebView displays.
//
//  Behaviour:
//    • First inline output of a run → loads the page shell with that
//      cell already present, baseURL = inline_output_dir so img/src
//      paths to disk-resident PNGs resolve.
//    • Subsequent cells → evaluateJavaScript appends to the shell
//      (no full reload, so scroll position is preserved).
//    • New script run → clear() is called, the next cell triggers a
//      fresh page load.
//
//  The HTML shell is minimal: dark theme matching the editor, monospace
//  caption, image-fit-width. No external CSS / fonts.
//

import Foundation
import WebKit

final class InlineOutputRenderer {

    /// The webview to render into. Held weakly so the renderer can
    /// outlive view-controller swaps.
    weak var webView: WKWebView?

    /// True once the current page shell has been loaded; reset by clear().
    private var pageLoaded = false

    /// In-memory cell HTML, kept so we can rebuild the page from
    /// scratch if the webview is recreated (e.g. process-died).
    private var cellsHTML: [String] = []

    /// Buffered cells queued before the webView became ready.
    private var pendingCells: [String] = []

    init(webView: WKWebView? = nil) {
        self.webView = webView
    }

    /// Drop everything — call between script runs.
    func clear() {
        cellsHTML.removeAll()
        pendingCells.removeAll()
        pageLoaded = false
        // Don't reload the webView immediately — wait for the next
        // append() so we don't flash an empty page during the
        // "between scripts" moment.
    }

    /// True if at least one cell has been appended since the last clear().
    var hasContent: Bool { return !cellsHTML.isEmpty }

    // MARK: - Append API

    /// Append a PNG image cell (with optional caption beneath it).
    func appendImage(path: String, caption: String) {
        let escapedPath = path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? path
        let captionHTML = caption.isEmpty ? "" :
            "<div class='cap'>\(htmlEscape(caption))</div>"
        let cell = """
        <div class='cell img-cell'>
            <img src='file://\(escapedPath)' alt='\(htmlEscape(caption))'>
            \(captionHTML)
        </div>
        """
        appendCell(cell)
    }

    /// Append an HTML-rendered cell (pandas DataFrame, plotly, etc.).
    /// The HTML is rendered as-is — the Python side is trusted (it's
    /// running in the same security context as the editor).
    func appendHTML(body: String, caption: String) {
        let captionHTML = caption.isEmpty ? "" :
            "<div class='cap'>\(htmlEscape(caption))</div>"
        let cell = """
        <div class='cell html-cell'>
            <div class='html-body'>\(body)</div>
            \(captionHTML)
        </div>
        """
        appendCell(cell)
    }

    // MARK: - Internal append

    private func appendCell(_ html: String) {
        cellsHTML.append(html)
        guard let webView = webView else {
            pendingCells.append(html); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.pageLoaded {
                self.loadShell(initialCell: html)
            } else {
                self.jsAppend(html)
            }
        }
    }

    private func loadShell(initialCell: String) {
        guard let webView = webView else { return }
        let shell = pageShell(initialBody: initialCell)
        // Use baseURL = the inline image dir so <img src='file://...'>
        // referencing PNGs in /tmp/codebench_inline_images/ can resolve.
        let imgDir = NSTemporaryDirectory().appending("codebench_inline_images")
        let baseURL = URL(fileURLWithPath: imgDir)
        webView.loadHTMLString(shell, baseURL: baseURL)
        pageLoaded = true
        // Drain any pendings (other cells written while the page was loading).
        let queued = pendingCells
        pendingCells.removeAll()
        // The page needs a moment to load before evaluateJavaScript will
        // resolve against its DOM; schedule the drain after a short delay.
        if !queued.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                for c in queued {
                    self?.jsAppend(c)
                }
            }
        }
    }

    private func jsAppend(_ html: String) {
        guard let webView = webView else { return }
        // Use a JSON-encoded payload to safely round-trip arbitrary
        // HTML through the JS string boundary (avoids escaping bugs
        // for quotes, backticks, backslashes, etc.).
        let payload: [String: Any] = ["html": html]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = """
        (function() {
            var o = \(json);
            var s = document.getElementById('inline-stream');
            if (!s) return;
            s.insertAdjacentHTML('beforeend', o.html);
            // Smooth scroll to the bottom so the user sees the new cell.
            window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' });
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func htmlEscape(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func pageShell(initialBody: String) -> String {
        return """
        <!doctype html>
        <html><head><meta charset='utf-8'>
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>
            html, body {
                margin: 0; padding: 0;
                background: #0a0a0f; color: #f0f0f5;
                font-family: -apple-system, SF Pro, sans-serif;
                font-size: 13px;
            }
            #inline-stream {
                padding: 12px 14px 80px;
                display: flex; flex-direction: column; gap: 18px;
            }
            .cell {
                background: #12121a;
                border: 1px solid #1f1f2e;
                border-radius: 8px;
                padding: 10px;
                overflow: auto;
            }
            .cell img {
                display: block;
                max-width: 100%;
                height: auto;
                margin: 0 auto;
                background: white;
                border-radius: 4px;
            }
            .html-body { color: #e0e0eb; }
            .html-body table {
                border-collapse: collapse;
                font-family: 'SF Mono', Menlo, monospace;
                font-size: 11px;
            }
            .html-body th, .html-body td {
                border: 1px solid #2a2a42;
                padding: 4px 8px;
                text-align: left;
            }
            .html-body th { background: #1a1a28; color: #a855f7; }
            .html-body tr:nth-child(even) td { background: #0f0f17; }
            .cap {
                margin-top: 8px;
                font: 11px/1.4 -apple-system, sans-serif;
                color: #a8a8b8;
                text-align: center;
                font-style: italic;
            }
        </style>
        </head><body>
        <div id='inline-stream'>
            \(initialBody)
        </div>
        </body></html>
        """
    }
}
