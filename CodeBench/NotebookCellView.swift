//
//  NotebookCellView.swift
//  CodeBench
//
//  One cell in the notebook stack. Code or markdown.
//
//   ┌────────────────────────────────────────────┐
//   │ [In: 3] ▶ ───────────── ↑ ↓ + - 🅼         │  ← Cell toolbar
//   ├────────────────────────────────────────────┤
//   │  import numpy as np                        │  ← Source UITextView
//   │  np.linspace(0, 1, 10)                     │
//   ├────────────────────────────────────────────┤
//   │ Out [3]:                                   │  ← Outputs
//   │   array([0., 0.111, …])                    │
//   │   [PNG figure]                             │
//   └────────────────────────────────────────────┘
//
//  We use a plain UITextView for source (not Monaco — that's one
//  WKWebView per cell, way too heavy). Syntax highlighting via a
//  minimal AttributedString colorizer applied on text-change.
//

import UIKit
import WebKit

final class NotebookCellView: UIView {

    // MARK: Inputs

    private(set) var cell: Cell
    private(set) var executionCount: Int?
    let index: Int

    var onRun: (() -> Void)?
    var onSourceChanged: (() -> Void)?
    var onInsertBelow: ((String) -> Void)?     // "code" or "markdown"
    var onDelete: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onToggleMarkdown: (() -> Void)?

    // MARK: UI components

    private let toolbar = UIView()
    private let execLabel = UILabel()
    private let runButton = UIButton(type: .system)
    private let source = UITextView()
    private let outputsContainer = UIStackView()
    private var markdownPreviewMode = false
    private var markdownPreviewWebView: WKWebView?
    private var sourceHeight: NSLayoutConstraint?

    // MARK: Init

    init(cell: Cell, index: Int) {
        self.cell = cell
        self.executionCount = cell.executionCount
        self.index = index
        super.init(frame: .zero)
        layer.cornerRadius = 8
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        backgroundColor = .secondarySystemBackground
        translatesAutoresizingMaskIntoConstraints = false
        setupToolbar()
        setupSource()
        setupOutputs()
        renderOutputs(cell.outputs ?? [])
        if cell.cellType == "markdown" {
            // Start in preview mode for existing markdown cells.
            DispatchQueue.main.async { [weak self] in self?.toggleMarkdownPreview() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Toolbar

    private func setupToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = .tertiarySystemBackground
        addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 34),
        ])

        execLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        execLabel.textColor = .systemPurple
        execLabel.text = formatExecLabel(executionCount)

        runButton.setImage(UIImage(systemName: "play.fill")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 13)), for: .normal)
        runButton.tintColor = .systemGreen
        runButton.accessibilityLabel = "Run cell"
        runButton.addTarget(self, action: #selector(runTap), for: .touchUpInside)

        let up = makeIconBtn("arrow.up", "Move up", #selector(moveUpTap))
        let dn = makeIconBtn("arrow.down", "Move down", #selector(moveDownTap))
        let add = makeIconBtn("plus", "Insert cell below", #selector(insertBelowTap))
        let del = makeIconBtn("trash", "Delete cell", #selector(delTap))
        del.tintColor = .systemRed
        let mdToggle = makeIconBtn(cell.cellType == "markdown" ? "doc.text" : "function",
                                   cell.cellType == "markdown" ? "Toggle preview" : "Code cell",
                                   #selector(mdToggleTap))

        let stk = UIStackView(arrangedSubviews: [execLabel, runButton,
                                                  UIView(),
                                                  up, dn, add, del, mdToggle])
        stk.axis = .horizontal; stk.spacing = 6; stk.alignment = .center
        stk.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stk)
        NSLayoutConstraint.activate([
            stk.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            stk.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            stk.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stk.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])
    }

    private func makeIconBtn(_ icon: String, _ label: String, _ selector: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: icon)?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 12)), for: .normal)
        b.tintColor = .label
        b.accessibilityLabel = label
        b.addTarget(self, action: selector, for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    // MARK: Source

    private func setupSource() {
        source.translatesAutoresizingMaskIntoConstraints = false
        source.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        source.textColor = .label
        source.backgroundColor = .clear
        source.text = cell.combinedSource
        source.isScrollEnabled = false   // expand to content
        source.autocorrectionType = .no
        source.autocapitalizationType = .none
        source.smartDashesType = .no
        source.smartQuotesType = .no
        source.delegate = self
        source.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        addSubview(source)
        NSLayoutConstraint.activate([
            source.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            source.leadingAnchor.constraint(equalTo: leadingAnchor),
            source.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applySyntaxHighlight()
    }

    // MARK: Outputs

    private func setupOutputs() {
        outputsContainer.axis = .vertical
        outputsContainer.spacing = 6
        outputsContainer.translatesAutoresizingMaskIntoConstraints = false
        outputsContainer.isLayoutMarginsRelativeArrangement = true
        outputsContainer.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 10, right: 12)
        addSubview(outputsContainer)
        NSLayoutConstraint.activate([
            outputsContainer.topAnchor.constraint(equalTo: source.bottomAnchor),
            outputsContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outputsContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outputsContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func renderOutputs(_ outputs: [CellOutput]) {
        outputsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for out in outputs {
            switch out.outputType {
            case "stream", "execute_result":
                let lbl = UILabel()
                lbl.numberOfLines = 0
                lbl.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                if let texts = out.text {
                    lbl.text = texts.joined()
                } else if let plain = (out.data?["text/plain"]?.value as? [Any])?
                            .compactMap({ $0 as? String }).joined() {
                    lbl.text = plain
                }
                lbl.textColor = (out.name == "stderr") ? .systemRed : .label
                outputsContainer.addArrangedSubview(lbl)
            case "display_data":
                if let imgB64 = out.data?["image/png"]?.value as? String,
                   let data = Data(base64Encoded: imgB64),
                   let img = UIImage(data: data) {
                    let iv = UIImageView(image: img)
                    iv.contentMode = .scaleAspectFit
                    iv.translatesAutoresizingMaskIntoConstraints = false
                    iv.heightAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
                    outputsContainer.addArrangedSubview(iv)
                } else if let htmlArr = (out.data?["text/html"]?.value as? [Any])?
                            .compactMap({ $0 as? String }) {
                    // Inline HTML rendering — small WKWebView per cell.
                    let wv = WKWebView(frame: .zero)
                    wv.translatesAutoresizingMaskIntoConstraints = false
                    wv.heightAnchor.constraint(equalToConstant: 300).isActive = true
                    wv.loadHTMLString(htmlArr.joined(), baseURL: nil)
                    outputsContainer.addArrangedSubview(wv)
                }
            case "error":
                let lbl = UILabel()
                lbl.numberOfLines = 0
                lbl.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                lbl.textColor = .systemRed
                var t = ""
                if let n = out.ename, let v = out.evalue {
                    t = "\(n): \(v)\n"
                }
                if let tb = out.traceback { t += tb.joined(separator: "\n") }
                lbl.text = t
                outputsContainer.addArrangedSubview(lbl)
            default:
                break
            }
        }
    }

    func setOutputs(_ outputs: [CellOutput]) {
        self.cell = Cell(cellType: cell.cellType, source: cell.source,
                         outputs: outputs, executionCount: executionCount,
                         metadata: cell.metadata)
        renderOutputs(outputs)
    }

    func setExecutionCount(_ n: Int?) {
        executionCount = n
        execLabel.text = formatExecLabel(n)
    }

    func setBusy(_ busy: Bool) {
        runButton.isEnabled = !busy
        runButton.tintColor = busy ? .systemGray : .systemGreen
        if busy {
            execLabel.text = "[*]"
            execLabel.textColor = .systemOrange
        } else {
            execLabel.text = formatExecLabel(executionCount)
            execLabel.textColor = .systemPurple
        }
    }

    func currentSource() -> String {
        if markdownPreviewMode, let _ = markdownPreviewWebView {
            // Source still lives in `source.text` even when preview shows
            return source.text ?? ""
        }
        return source.text ?? ""
    }

    func toggleMarkdownPreview() {
        guard cell.cellType == "markdown" else { return }
        if markdownPreviewMode {
            markdownPreviewWebView?.removeFromSuperview()
            markdownPreviewWebView = nil
            source.isHidden = false
            markdownPreviewMode = false
        } else {
            let wv = WKWebView(frame: .zero)
            wv.translatesAutoresizingMaskIntoConstraints = false
            wv.backgroundColor = .secondarySystemBackground
            wv.isOpaque = false
            // Tap-to-edit gesture
            let tap = UITapGestureRecognizer(target: self, action: #selector(mdEditTap))
            wv.addGestureRecognizer(tap)
            let html = simpleMarkdownToHTML(currentSource())
            wv.loadHTMLString(html, baseURL: nil)
            insertSubview(wv, aboveSubview: source)
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: source.topAnchor),
                wv.leadingAnchor.constraint(equalTo: source.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: source.trailingAnchor),
                wv.bottomAnchor.constraint(equalTo: source.bottomAnchor),
            ])
            source.isHidden = true
            markdownPreviewWebView = wv
            markdownPreviewMode = true
        }
    }

    @objc private func mdEditTap() {
        if markdownPreviewMode { toggleMarkdownPreview() }
        source.becomeFirstResponder()
    }

    // MARK: Toolbar actions

    @objc private func runTap()         { onRun?() }
    @objc private func moveUpTap()      { onMoveUp?() }
    @objc private func moveDownTap()    { onMoveDown?() }
    @objc private func insertBelowTap() {
        let alert = UIAlertController(title: "Insert cell", message: nil,
                                      preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Code", style: .default) { _ in
            self.onInsertBelow?("code")
        })
        alert.addAction(UIAlertAction(title: "Markdown", style: .default) { _ in
            self.onInsertBelow?("markdown")
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = self
            pop.sourceRect = toolbar.bounds
        }
        // Walk up to a presenter
        var responder: UIResponder? = self
        while responder != nil, !(responder is UIViewController) {
            responder = responder?.next
        }
        (responder as? UIViewController)?.present(alert, animated: true)
    }
    @objc private func delTap()         { onDelete?() }
    @objc private func mdToggleTap()    { onToggleMarkdown?() }

    // MARK: - Helpers

    private func formatExecLabel(_ n: Int?) -> String {
        if cell.cellType == "markdown" { return "[Md]" }
        return n.map { "[\($0)]" } ?? "[ ]"
    }

    private func applySyntaxHighlight() {
        // Cheap regex-based highlighter — keywords, strings, comments.
        guard cell.cellType == "code" else { return }
        let attr = NSMutableAttributedString(string: source.text)
        let full = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.font, value: source.font!, range: full)
        attr.addAttribute(.foregroundColor, value: UIColor.label, range: full)
        let pyKeywords = ["def", "class", "if", "elif", "else", "for", "while",
                          "in", "return", "import", "from", "as", "try", "except",
                          "finally", "with", "lambda", "yield", "raise", "True",
                          "False", "None", "and", "or", "not", "is", "pass",
                          "break", "continue", "global", "nonlocal"]
        for kw in pyKeywords {
            let pattern = "\\b\(kw)\\b"
            if let re = try? NSRegularExpression(pattern: pattern) {
                re.enumerateMatches(in: source.text, range: full) { m, _, _ in
                    if let r = m?.range {
                        attr.addAttribute(.foregroundColor,
                                          value: UIColor.systemPurple, range: r)
                    }
                }
            }
        }
        // Strings
        if let re = try? NSRegularExpression(pattern: "\"[^\"]*\"|'[^']*'") {
            re.enumerateMatches(in: source.text, range: full) { m, _, _ in
                if let r = m?.range {
                    attr.addAttribute(.foregroundColor,
                                      value: UIColor.systemOrange, range: r)
                }
            }
        }
        // Comments
        if let re = try? NSRegularExpression(pattern: "#[^\n]*") {
            re.enumerateMatches(in: source.text, range: full) { m, _, _ in
                if let r = m?.range {
                    attr.addAttribute(.foregroundColor,
                                      value: UIColor.systemGray, range: r)
                }
            }
        }
        let prevSel = source.selectedRange
        source.attributedText = attr
        source.selectedRange = prevSel
    }

    private func simpleMarkdownToHTML(_ md: String) -> String {
        // Very thin renderer — # H1, ## H2, * bullet, **bold**, `code`.
        // For full markdown the user should still use the `md` builtin.
        var out = md
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(
            of: "(?m)^### (.*)$", with: "<h3>$1</h3>",
            options: .regularExpression)
        out = out.replacingOccurrences(
            of: "(?m)^## (.*)$", with: "<h2>$1</h2>",
            options: .regularExpression)
        out = out.replacingOccurrences(
            of: "(?m)^# (.*)$", with: "<h1>$1</h1>",
            options: .regularExpression)
        out = out.replacingOccurrences(
            of: "\\*\\*([^*]+)\\*\\*", with: "<strong>$1</strong>",
            options: .regularExpression)
        out = out.replacingOccurrences(
            of: "\\*([^*]+)\\*", with: "<em>$1</em>",
            options: .regularExpression)
        out = out.replacingOccurrences(
            of: "`([^`]+)`", with: "<code>$1</code>",
            options: .regularExpression)
        out = out.replacingOccurrences(of: "\n", with: "<br>")
        return """
        <!doctype html><html><head><meta charset='utf-8'>
        <style>
            body { font:14px/1.5 -apple-system; padding:12px;
                   color:#f0f0f5; background:transparent; }
            h1, h2, h3 { color:#a855f7; }
            code { background:#1f1f2e; padding:1px 5px; border-radius:3px;
                   font-family:'SF Mono', monospace; font-size:13px; color:#fbbf24; }
        </style></head><body>\(out)</body></html>
        """
    }
}

// MARK: - UITextViewDelegate

extension NotebookCellView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        applySyntaxHighlight()
        onSourceChanged?()
    }
}
