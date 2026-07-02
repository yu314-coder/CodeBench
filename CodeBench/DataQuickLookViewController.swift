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
import PDFKit

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
        case "md", "markdown", "mdown", "mkd", "mdwn":
            renderMarkdown()
        case "pdf":
            renderPDF()
        case "html", "htm", "xhtml", "svg":
            renderWebFile()
        default:
            // Never dump a binary file's bytes as "text" — that's what made
            // a PDF (or any binary) show as random characters. Detect binary
            // and show a readable hex view instead.
            if isProbablyBinary() {
                renderHexDump()
            } else {
                renderText(language: ext)
            }
        }
    }

    // MARK: - PDF (PDFKit)

    private func renderPDF() {
        guard let doc = PDFDocument(url: fileURL) else {
            renderError("Could not open PDF."); return
        }
        let pdfView = PDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.document = doc
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .black
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - HTML / SVG (rendered, not source) — load the file directly

    private func renderWebFile() {
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
        // loadFileURL renders HTML/SVG and grants read access to sibling
        // assets (css/js/images) in the same directory.
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    // MARK: - Binary detection + hex view

    /// Heuristic: a NUL byte, or >10% control chars in the first 8 KB → binary.
    /// (Valid UTF-8 text — incl. multibyte — passes; PDFs/images/.so/.zip fail.)
    private func isProbablyBinary() -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? fh.close() }
        let sample = fh.readData(ofLength: 8192)
        if sample.isEmpty { return false }
        if sample.contains(0) { return true }
        var control = 0
        for b in sample where b < 9 || (b > 13 && b < 32) { control += 1 }
        return Double(control) / Double(sample.count) > 0.10
    }

    /// Classic offset / hex / ASCII dump of the first 64 KB — useful for
    /// .bin/.so/.pyc/.gguf/etc. instead of a screenful of garbage text.
    private func renderHexDump() {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else {
            renderError("Could not read file."); return
        }
        defer { try? fh.close() }
        let cap = 64 * 1024
        let bytes = [UInt8](fh.readData(ofLength: cap))
        let total = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? bytes.count
        var rows = ""
        var off = 0
        while off < bytes.count {
            let end = min(off + 16, bytes.count)
            let chunk = bytes[off..<end]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let asc = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            rows += "<tr><td class='off'>\(String(format: "%08x", off))</td><td class='hex'>\(hex)</td><td class='asc'>\(htmlEscape(asc))</td></tr>"
            off += 16
        }
        let note = total > bytes.count
            ? "<div class='meta'>binary · showing first \(bytes.count) of \(total) bytes</div>"
            : "<div class='meta'>binary · \(total) bytes</div>"
        let html = """
        <!doctype html><html><head><meta charset='utf-8'>
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>
            body { margin:0; padding:14px; background:#0a0a0f; color:#f0f0f5;
                   font:11px/1.45 'SF Mono', Menlo, monospace; }
            .meta { color:#a8a8b8; margin-bottom:10px; font-size:11px;
                    font-family:-apple-system, sans-serif; }
            table { border-collapse:collapse; }
            td { padding:1px 10px 1px 0; white-space:pre; vertical-align:top; }
            .off { color:#6b6b80; }
            .hex { color:#c9c9e0; }
            .asc { color:#a855f7; }
        </style></head><body>\(note)<table><tbody>\(rows)</tbody></table></body></html>
        """
        mountHTML(html)
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
            :root { color-scheme: light dark; }
            html, body { margin:0; padding:0; background:#ffffff; color:#1f2328;
                         -webkit-text-size-adjust:100%; }
            pre { margin:0; padding:16px; font:13px/1.55 'SF Mono', Menlo, monospace;
                  white-space:pre; tab-size:4; word-wrap:break-word; }
            /* Syntax sugar — JSON keys + values (light defaults; dark overrides below) */
            .key { color:#8250df; }
            .str { color:#0a3069; }
            .num { color:#0550ae; }
            .bool, .null { color:#cf222e; }
            @media (prefers-color-scheme: dark) {
                html, body { background:#0d1117; color:#e6edf3; }
                .key { color:#a855f7; } .str { color:#fbbf24; }
                .num { color:#34d399; } .bool, .null { color:#06b6d4; }
            }
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

    // MARK: - Markdown (rendered, not raw source)

    private func renderMarkdown() {
        guard let raw = try? readCapped(bytes: 5 * 1024 * 1024) else {
            renderError("Could not read file."); return
        }
        let body = Self.markdownToHTML(raw)
        let html = """
        <!doctype html><html><head><meta charset='utf-8'>
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>\(Self.markdownCSS)</style></head>
        <body><article class='md'>\(body)</article></body></html>
        """
        mountHTML(html)
    }

    /// Compact, dependency-free Markdown → HTML for the quick-look. Handles
    /// fenced code blocks, ATX headings, hr, blockquotes, ordered/unordered
    /// lists, GFM tables, paragraphs, and inline bold/italic/code/strike/
    /// links/images. (Validated against the swift toolchain before shipping.)
    static func markdownToHTML(_ md: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        func rx(_ s: String, _ pat: String, _ tmpl: String) -> String {
            guard let re = try? NSRegularExpression(pattern: pat) else { return s }
            return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tmpl)
        }
        func inl(_ s: String) -> String {
            var t = s
            t = rx(t, "!\\[([^\\]]*)\\]\\(([^)\\s]+)[^)]*\\)", "<img alt=\"$1\" src=\"$2\">")
            t = rx(t, "\\[([^\\]]+)\\]\\(([^)\\s]+)[^)]*\\)", "<a href=\"$2\">$1</a>")
            t = rx(t, "`([^`]+)`", "<code>$1</code>")
            t = rx(t, "\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>")
            t = rx(t, "__([^_]+)__", "<strong>$1</strong>")
            t = rx(t, "(^|[^*\\w])\\*([^*\\n]+)\\*", "$1<em>$2</em>")
            t = rx(t, "~~([^~]+)~~", "<del>$1</del>")
            return t
        }
        let lines = md.components(separatedBy: "\n")
        var out = ""; var i = 0; var listOpen = false; var listTag = "ul"
        func closeList() { if listOpen { out += "</\(listTag)>"; listOpen = false } }
        func isSpecial(_ t: String) -> Bool {
            return t.isEmpty || t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```")
                || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ")
                || t == "---" || t == "***" || t == "___"
                || (t.range(of: "^\\d+\\. ", options: .regularExpression) != nil) || t.contains("|")
        }
        func cells(_ s: String) -> [String] {
            var x = s.trimmingCharacters(in: .whitespaces)
            if x.hasPrefix("|") { x.removeFirst() }; if x.hasSuffix("|") { x.removeLast() }
            return x.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                closeList(); let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code = ""; i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code += esc(lines[i]) + "\n"; i += 1
                }
                i += 1; let cls = lang.isEmpty ? "" : " class=\"language-\(esc(lang))\""
                out += "<pre><code\(cls)>\(code)</code></pre>"; continue
            }
            if t.isEmpty { closeList(); i += 1; continue }
            if t.hasPrefix("#") {
                let h = t.prefix(while: { $0 == "#" }).count
                if h >= 1 && h <= 6 {
                    closeList(); let txt = String(t.dropFirst(h)).trimmingCharacters(in: .whitespaces)
                    out += "<h\(h)>\(inl(esc(txt)))</h\(h)>"; i += 1; continue
                }
            }
            if t == "---" || t == "***" || t == "___" { closeList(); out += "<hr>"; i += 1; continue }
            if t.hasPrefix(">") {
                closeList(); var q = ""
                while i < lines.count {
                    let tt = lines[i].trimmingCharacters(in: .whitespaces)
                    if !tt.hasPrefix(">") { break }
                    q += inl(esc(String(tt.dropFirst()).trimmingCharacters(in: .whitespaces))) + " "; i += 1
                }
                out += "<blockquote>\(q)</blockquote>"; continue
            }
            if t.contains("|"), i + 1 < lines.count,
               lines[i+1].range(of: "^\\s*\\|?[\\s:|-]+\\|?\\s*$", options: .regularExpression) != nil,
               lines[i+1].contains("-") {
                closeList(); let header = cells(lines[i])
                out += "<table><thead><tr>"
                for c in header { out += "<th>\(inl(esc(c)))</th>" }
                out += "</tr></thead><tbody>"; i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    if row.isEmpty || !row.contains("|") { break }
                    out += "<tr>"; for c in cells(lines[i]) { out += "<td>\(inl(esc(c)))</td>" }
                    out += "</tr>"; i += 1
                }
                out += "</tbody></table>"; continue
            }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                if !listOpen || listTag != "ul" { closeList(); out += "<ul>"; listOpen = true; listTag = "ul" }
                out += "<li>\(inl(esc(String(t.dropFirst(2)))))</li>"; i += 1; continue
            }
            if let r = t.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                if !listOpen || listTag != "ol" { closeList(); out += "<ol>"; listOpen = true; listTag = "ol" }
                out += "<li>\(inl(esc(String(t[r.upperBound...]))))</li>"; i += 1; continue
            }
            closeList(); var p = inl(esc(t)); i += 1
            while i < lines.count {
                let tt = lines[i].trimmingCharacters(in: .whitespaces)
                if isSpecial(tt) { break }
                p += " " + inl(esc(tt)); i += 1
            }
            out += "<p>\(p)</p>"
        }
        closeList(); return out
    }

    static let markdownCSS = """
    :root { color-scheme: light dark; }
    html,body{ margin:0; padding:0; }
    body{ font:16px/1.65 -apple-system,'SF Pro Text',system-ui,sans-serif;
          background:#ffffff; color:#1f2328; -webkit-text-size-adjust:100%; }
    .md{ max-width:780px; margin:0 auto; padding:22px 20px 80px; word-wrap:break-word; }
    .md h1,.md h2,.md h3,.md h4{ font-weight:700; line-height:1.25; margin:1.3em 0 .5em; }
    .md h1{ font-size:1.85em; border-bottom:1px solid #d0d7de; padding-bottom:.3em; }
    .md h2{ font-size:1.45em; border-bottom:1px solid #d0d7de; padding-bottom:.3em; }
    .md h3{ font-size:1.2em; } .md h4{ font-size:1em; }
    .md p{ margin:.7em 0; }
    .md a{ color:#0969da; text-decoration:none; } .md a:hover{ text-decoration:underline; }
    .md code{ font:13.5px/1.4 'SF Mono',Menlo,monospace; background:rgba(135,131,120,.18);
              padding:.15em .35em; border-radius:5px; }
    .md pre{ background:#f6f8fa; padding:14px; border-radius:8px; overflow:auto; }
    .md pre code{ background:none; padding:0; font-size:13px; line-height:1.5; }
    .md ul,.md ol{ margin:.6em 0; padding-left:1.7em; } .md li{ margin:.25em 0; }
    .md blockquote{ margin:.8em 0; padding:.2em 1em; color:#59636e; border-left:4px solid #d0d7de; }
    .md hr{ border:0; height:1px; background:#d0d7de; margin:1.6em 0; }
    .md table{ border-collapse:collapse; margin:.8em 0; display:block; overflow:auto; }
    .md th,.md td{ border:1px solid #d0d7de; padding:6px 13px; }
    .md th{ background:#f6f8fa; font-weight:600; } .md tr:nth-child(2n) td{ background:#f6f8fa; }
    .md img{ max-width:100%; }
    @media (prefers-color-scheme: dark){
      body{ background:#0d1117; color:#e6edf3; }
      .md h1,.md h2{ border-color:#30363d; }
      .md a{ color:#4493f8; }
      .md code{ background:rgba(110,118,129,.4); }
      .md pre{ background:#161b22; }
      .md blockquote{ color:#9198a1; border-color:#30363d; }
      .md hr{ background:#30363d; }
      .md th,.md td{ border-color:#30363d; } .md th{ background:#161b22; }
      .md tr:nth-child(2n) td{ background:#161b22; }
    }
    """

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
