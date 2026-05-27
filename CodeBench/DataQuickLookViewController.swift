//
//  DataQuickLookViewController.swift
//  CodeBench
//
//  Long-press a file in the file browser → "Quick Look" modal that
//  renders the file's content in the right format for its type:
//
//    • .csv  / .tsv         → table grid via WKWebView (pandas-style)
//    • .json / .yaml / .toml → syntax-highlighted pretty-print
//    • .png  / .jpg / etc   → UIImageView with pinch zoom
//    • .npy  / .npz         → table grid via numpy (loaded in-process)
//    • anything else        → plain text fallback
//
//  Renders entirely via UIKit + WKWebView for the table/pretty-print
//  cases — no Python round-trip needed for CSV/JSON/images. NumPy
//  arrays do hop into Python because reading .npy headers in Swift
//  would be a separate parser; we already have numpy bundled.
//
//  Capped at 5000 rows × 100 cols for tables and 5 MB for text /
//  pretty-printed JSON, so opening a 2 GB CSV doesn't kill the app.
//

import UIKit
import WebKit

final class DataQuickLookViewController: UIViewController {

    // MARK: - Inputs

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = fileURL.lastPathComponent
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(closeTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            style: .plain, target: self, action: #selector(shareTapped))
        renderForType()
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func shareTapped() {
        let av = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        av.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
        present(av, animated: true)
    }

    // MARK: - Format dispatch

    private func renderForType() {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "csv", "tsv":
            renderCSV(separator: (ext == "tsv") ? "\t" : ",")
        case "json":
            renderJSON()
        case "yaml", "yml":
            renderYAML()
        case "toml":
            renderText(language: "toml")
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff":
            renderImage()
        case "npy", "npz":
            renderNumPy()
        default:
            renderText(language: ext)
        }
    }

    // MARK: - CSV

    private func renderCSV(separator: Character) {
        let maxBytes = 8 * 1024 * 1024   // 8 MB read cap
        let maxRows = 5000
        let maxCols = 100
        guard let raw = try? readCapped(bytes: maxBytes) else {
            renderError("Could not read file."); return
        }
        // Simple parser — handles quoted fields with commas/newlines.
        // (CSV "standard" RFC 4180. Doesn't handle exotic embedded
        // quotes; for that, recommend pandas.)
        let rows = parseCSV(raw, separator: separator, maxRows: maxRows)
        guard !rows.isEmpty else { renderError("Empty file."); return }
        let header = rows[0]
        let body = Array(rows.dropFirst().prefix(maxRows))
        let cols = min(max(header.count, body.first?.count ?? 0), maxCols)

        var html = """
        <!doctype html><html><head><meta charset='utf-8'>
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>
            body { margin:0; padding:14px; background:#0a0a0f; color:#f0f0f5;
                   font:13px/1.5 -apple-system, SF Pro, sans-serif; }
            .meta { color:#a8a8b8; margin-bottom:10px; font-size:11px; }
            table { border-collapse:collapse; font-family:'SF Mono', Menlo, monospace; font-size:11px; }
            th, td { border:1px solid #2a2a42; padding:4px 8px; text-align:left;
                     max-width:200px; overflow:hidden; text-overflow:ellipsis;
                     white-space:nowrap; }
            th { background:#1a1a28; color:#a855f7; position:sticky; top:0; }
            tr:nth-child(even) td { background:#12121a; }
            tr:hover td { background:#1f1f2e; }
            .rownum { color:#6b6b80; text-align:right; }
        </style></head><body>
        <div class='meta'>\(body.count) rows × \(cols) cols</div>
        <table><thead><tr>
        <th class='rownum'>#</th>
        """
        for c in header.prefix(cols) {
            html += "<th>\(htmlEscape(c))</th>"
        }
        html += "</tr></thead><tbody>"
        for (i, row) in body.enumerated() {
            html += "<tr><td class='rownum'>\(i+1)</td>"
            for c in row.prefix(cols) {
                html += "<td>\(htmlEscape(c))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table></body></html>"
        mountHTML(html)
    }

    // MARK: - JSON

    private func renderJSON() {
        let maxBytes = 5 * 1024 * 1024
        guard let raw = try? readCapped(bytes: maxBytes) else {
            renderError("Could not read file."); return
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data,
                                                          options: [.fragmentsAllowed]) else {
            renderError("Invalid JSON."); return
        }
        guard let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let str = String(data: pretty, encoding: .utf8) else {
            renderError("Could not pretty-print."); return
        }
        renderText(str, language: "json")
    }

    private func renderYAML() {
        // YAML pretty-printing without yaml lib in-Swift — just
        // render the source verbatim with syntax highlighting via
        // a minimal regex-based highlighter on the JS side.
        guard let raw = try? readCapped(bytes: 5 * 1024 * 1024) else {
            renderError("Could not read file."); return
        }
        renderText(raw, language: "yaml")
    }

    // MARK: - Image

    private func renderImage() {
        guard let img = UIImage(contentsOfFile: fileURL.path) else {
            renderError("Could not decode image."); return
        }
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.maximumZoomScale = 6
        scroll.minimumZoomScale = 1
        scroll.delegate = self
        scroll.backgroundColor = .black

        let iv = UIImageView(image: img)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false

        scroll.addSubview(iv)
        view.addSubview(scroll)
        zoomedImage = iv

        // Caption with image dims
        let caption = UILabel()
        caption.text = "\(Int(img.size.width)) × \(Int(img.size.height)) px · \(fileURL.lastPathComponent)"
        caption.font = .systemFont(ofSize: 11, weight: .regular)
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        caption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(caption)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -8),
            iv.topAnchor.constraint(equalTo: scroll.topAnchor),
            iv.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            iv.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            iv.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            iv.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            caption.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }
    private var zoomedImage: UIImageView?

    // MARK: - NumPy

    private func renderNumPy() {
        // Shell out to Python via the same signal protocol used for AI.
        // Drop a `numpy_quicklook_request.txt` with the file path,
        // Python reads numpy.load(), writes back HTML to
        // `numpy_quicklook_response.html`. Cheap and avoids a Swift
        // .npy parser.
        let sig = NSTemporaryDirectory().appending("latex_signals/")
        try? FileManager.default.createDirectory(atPath: sig,
                                                 withIntermediateDirectories: true)
        let reqPath = sig + "numpy_quicklook_request.txt"
        let respPath = sig + "numpy_quicklook_response.html"
        try? FileManager.default.removeItem(atPath: respPath)
        try? fileURL.path.write(toFile: reqPath, atomically: true, encoding: .utf8)

        // Loading spinner while we wait
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        // Poll for the response (2 s timeout)
        let deadline = Date().addingTimeInterval(5)
        func tick() {
            if FileManager.default.fileExists(atPath: respPath),
               let html = try? String(contentsOfFile: respPath, encoding: .utf8) {
                spinner.removeFromSuperview()
                try? FileManager.default.removeItem(atPath: respPath)
                self.mountHTML(html)
                return
            }
            if Date() > deadline {
                spinner.removeFromSuperview()
                self.renderError("NumPy quick-look timed out. Make sure a Python session is active.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: tick)
        }
        tick()
    }

    // MARK: - Text fallback (with simple language hint for color)

    private func renderText(_ text: String? = nil, language: String) {
        let raw: String
        if let text = text { raw = text }
        else {
            guard let r = try? readCapped(bytes: 5 * 1024 * 1024) else {
                renderError("Could not read file."); return
            }
            raw = r
        }
        let escaped = htmlEscape(raw)
        let html = """
        <!doctype html><html><head><meta charset='utf-8'>
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>
            html, body { margin:0; padding:0; background:#0a0a0f; color:#f0f0f5; }
            pre { margin:0; padding:14px; font:13px/1.5 'SF Mono', Menlo, monospace;
                  white-space:pre; tab-size:4; word-wrap:break-word; }
            /* Tiny syntax sugar — JSON keys + numbers */
            .key { color:#a855f7; }
            .str { color:#fbbf24; }
            .num { color:#34d399; }
            .bool, .null { color:#06b6d4; }
        </style></head><body>
        <pre id='content'>\(escaped)</pre>
        <script>
        (function(){
            var el = document.getElementById('content');
            var lang = '\(language)';
            if (lang !== 'json') return;
            // Tiny in-place JSON highlighter — regex replace.
            var t = el.innerHTML;
            t = t.replace(/("(?:\\\\.|[^"])*")\\s*:/g,'<span class="key">$1</span>:');
            t = t.replace(/:\\s*("(?:\\\\.|[^"])*")/g,': <span class="str">$1</span>');
            t = t.replace(/:\\s*(-?\\d+(?:\\.\\d+)?)/g,': <span class="num">$1</span>');
            t = t.replace(/:\\s*(true|false)/g,': <span class="bool">$1</span>');
            t = t.replace(/:\\s*(null)/g,': <span class="null">$1</span>');
            el.innerHTML = t;
        })();
        </script>
        </body></html>
        """
        mountHTML(html)
    }

    // MARK: - WebView mount

    private func mountHTML(_ html: String) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.backgroundColor = .systemBackground
        webView.isOpaque = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Error

    private func renderError(_ msg: String) {
        let lbl = UILabel()
        lbl.text = "⚠️ " + msg
        lbl.textColor = .secondaryLabel
        lbl.font = .systemFont(ofSize: 14)
        lbl.textAlignment = .center
        lbl.numberOfLines = 0
        lbl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            lbl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            lbl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - File reading + CSV parsing

    private func readCapped(bytes: Int) throws -> String {
        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }
        let data = fh.readData(ofLength: bytes)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private func parseCSV(_ text: String, separator: Character, maxRows: Int) -> [[String]] {
        var rows: [[String]] = []
        var cur: [String] = []
        var field = ""
        var inQuotes = false
        var iter = text.makeIterator()
        while let c = iter.next() {
            if inQuotes {
                if c == "\"" {
                    // Peek next: "" → literal quote
                    field.append(c)
                    // Simple: don't bother with lookahead, accept "" as one quote
                    inQuotes = false
                } else { field.append(c) }
            } else {
                if c == "\"" { inQuotes = true }
                else if c == separator { cur.append(field); field = "" }
                else if c == "\n" || c == "\r\n" {
                    cur.append(field); field = ""
                    rows.append(cur); cur.removeAll()
                    if rows.count > maxRows { break }
                } else { field.append(c) }
            }
        }
        if !field.isEmpty || !cur.isEmpty {
            cur.append(field); rows.append(cur)
        }
        return rows
    }

    private func htmlEscape(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Convenience presentation

    static func present(from presenter: UIViewController, fileURL: URL) {
        let vc = DataQuickLookViewController(fileURL: fileURL)
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(nav, animated: true)
    }
}

// MARK: - Image zoom

extension DataQuickLookViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomedImage }
}
