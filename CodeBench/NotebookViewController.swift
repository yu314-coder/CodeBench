//
//  NotebookViewController.swift
//  CodeBench
//
//  Jupyter `.ipynb` editor — cell-stacked UI with per-cell Run, output
//  capture, markdown rendering, and save back to .ipynb format.
//
//  Architecture
//  ────────────
//  • Top-level UIScrollView stacks NotebookCellView's vertically.
//  • Each NotebookCellView is either a `code` cell (Monaco-lite text
//    view + Run button + output area) or a `markdown` cell (UITextView
//    edit mode + WKWebView preview mode, toggled).
//  • Cell execution goes through the same Python runtime CodeBench
//    already uses — sends `exec_request_<id>.json` to LaTeXEngine's
//    signal dir, polls `exec_response_<id>.json` for stdout/stderr/
//    plots. Plots/HTML come back via the same codebench_inline
//    mechanism, scoped to the cell.
//  • Namespace persists across cells in one notebook open (a fresh
//    open re-seeds it).
//  • Save writes back to the original file path in nbformat v4 JSON.
//
//  Trade-offs vs full Jupyter
//  ──────────────────────────
//  Supported:
//    • Code cells (Python), markdown cells (with KaTeX math)
//    • Per-cell run, run-all, restart-kernel, cell drag-reorder
//    • Cut/copy/paste/insert/delete cells
//    • stdout, stderr, plain-text result, PNG output, HTML output
//
//  Not supported (yet):
//    • Magics (%matplotlib, %time, etc.) — falls through to error
//    • Per-cell metadata beyond what nbformat requires
//    • Widgets (ipywidgets)
//    • Server-side kernel restart UX subtleties (executions auto-stop
//      if the user closes the notebook)
//

import UIKit
import WebKit

// MARK: - Notebook data model

struct Notebook: Codable {
    var cells: [Cell]
    var metadata: [String: AnyCodable]
    var nbformat: Int
    var nbformatMinor: Int

    enum CodingKeys: String, CodingKey {
        case cells, metadata, nbformat
        case nbformatMinor = "nbformat_minor"
    }

    static func empty() -> Notebook {
        return Notebook(
            cells: [Cell(cellType: "code", source: [""], outputs: [], executionCount: nil, metadata: [:])],
            metadata: ["kernelspec": AnyCodable(["name": "python3", "display_name": "Python 3 (CodeBench)"])],
            nbformat: 4, nbformatMinor: 5)
    }
}

struct Cell: Codable {
    var cellType: String                  // "code" or "markdown"
    var source: [String]                  // lines (joined for display)
    var outputs: [CellOutput]?            // code cells only
    var executionCount: Int?              // code cells only
    var metadata: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case cellType = "cell_type"
        case source, outputs, metadata
        case executionCount = "execution_count"
    }

    var combinedSource: String { source.joined() }
}

struct CellOutput: Codable {
    var outputType: String                // "stream" | "execute_result" | "display_data" | "error"
    var text: [String]?                   // stream / error
    var name: String?                     // "stdout" | "stderr" (for stream)
    var data: [String: AnyCodable]?       // {"text/plain": [...], "image/png": "base64..."}
    var ename: String?
    var evalue: String?
    var traceback: [String]?

    enum CodingKeys: String, CodingKey {
        case outputType = "output_type"
        case text, name, data, ename, evalue, traceback
    }
}

/// Codable wrapper for arbitrary JSON values (numbers, strings, arrays,
/// objects, nulls). Lets us preserve nbformat metadata round-trips
/// without modeling every shape.
struct AnyCodable: Codable {
    let value: Any

    init(_ v: Any) { self.value = v }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull(); return }
        if let v = try? c.decode(Bool.self)    { self.value = v; return }
        if let v = try? c.decode(Int.self)     { self.value = v; return }
        if let v = try? c.decode(Double.self)  { self.value = v; return }
        if let v = try? c.decode(String.self)  { self.value = v; return }
        if let v = try? c.decode([AnyCodable].self) {
            self.value = v.map { $0.value }; return
        }
        if let v = try? c.decode([String: AnyCodable].self) {
            self.value = v.mapValues { $0.value }; return
        }
        self.value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map(AnyCodable.init))
        case let v as [String: Any]: try c.encode(v.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }
}

// MARK: - View controller

final class NotebookViewController: UIViewController, UIScrollViewDelegate {

    // MARK: Inputs

    private let fileURL: URL
    private var notebook: Notebook
    private var cellViews: [NotebookCellView] = []
    private var nextExecCount: Int = 1
    private let stack = UIStackView()
    private let scroll = UIScrollView()

    // Track in-flight cell executions so the Save button can warn /
    // wait, and so closing the notebook can cleanly cancel them.
    private var inFlightCount = 0

    /// Per-notebook signal dir scope so concurrent notebooks don't
    /// step on each other.
    private let executionScope = UUID().uuidString.prefix(8)

    // MARK: Init

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let nb = try? JSONDecoder().decode(Notebook.self, from: data) {
            self.notebook = nb
        } else {
            self.notebook = Notebook.empty()
        }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = fileURL.lastPathComponent
        view.backgroundColor = .systemBackground
        setupToolbar()
        setupLayout()
        buildCellViews()
    }

    /// True when the VC was added as a child to host its view inline
    /// inside `CodeEditorViewController.editorContainer`. When false,
    /// it was presented as a modal sheet (legacy code path). The
    /// embedded form draws its own toolbar inline instead of relying
    /// on the host's UINavigationBar.
    private var isEmbedded: Bool { return parent != nil && !(parent is UINavigationController) }

    // MARK: Toolbar

    private func setupToolbar() {
        // Embedded: draw a thin inline toolbar at the top of the view
        // (no UINavigationController in this scope). Modal: use the
        // nav bar of the surrounding UINavigationController.
        if isEmbedded {
            setupInlineToolbar()
        } else {
            let runAll = UIBarButtonItem(image: UIImage(systemName: "play.fill"),
                                         style: .plain, target: self, action: #selector(runAllTapped))
            let restart = UIBarButtonItem(image: UIImage(systemName: "arrow.counterclockwise"),
                                          style: .plain, target: self, action: #selector(restartKernelTapped))
            let save = UIBarButtonItem(barButtonSystemItem: .save,
                                       target: self, action: #selector(saveTapped))
            let close = UIBarButtonItem(barButtonSystemItem: .done,
                                        target: self, action: #selector(closeTapped))
            navigationItem.rightBarButtonItems = [close, save]
            navigationItem.leftBarButtonItems = [runAll, restart]
        }
    }

    /// Inline toolbar drawn at the top of the notebook view when
    /// embedded inside another VC (no UINavigationController). Hosts
    /// Run All / Restart Kernel / Save buttons and an unsaved-changes
    /// dot. No Close — closing means opening a different file.
    private var inlineToolbar: UIView?
    private var inlineModifiedDot: UIView?
    private func setupInlineToolbar() {
        let bar = UIView()
        bar.backgroundColor = UIColor(white: 0.12, alpha: 1)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = fileURL.lastPathComponent
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .label

        let modDot = UIView()
        modDot.backgroundColor = .systemOrange
        modDot.layer.cornerRadius = 4
        modDot.translatesAutoresizingMaskIntoConstraints = false
        modDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        modDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        modDot.isHidden = true
        self.inlineModifiedDot = modDot

        let runAll = makeInlineBtn("play.fill", "Run All", #selector(runAllTapped))
        runAll.tintColor = .systemGreen
        let restart = makeInlineBtn("arrow.counterclockwise", "Restart kernel", #selector(restartKernelTapped))
        restart.tintColor = .systemOrange
        let save = makeInlineBtn("square.and.arrow.down", "Save", #selector(saveTapped))
        save.tintColor = .systemBlue

        let leftStack = UIStackView(arrangedSubviews: [title, modDot])
        leftStack.axis = .horizontal; leftStack.spacing = 6; leftStack.alignment = .center
        let rightStack = UIStackView(arrangedSubviews: [runAll, restart, save])
        rightStack.axis = .horizontal; rightStack.spacing = 12; rightStack.alignment = .center

        let row = UIStackView(arrangedSubviews: [leftStack, UIView(), rightStack])
        row.axis = .horizontal; row.alignment = .center; row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: bar.topAnchor),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
        ])
        self.inlineToolbar = bar
    }
    private func makeInlineBtn(_ icon: String, _ label: String, _ selector: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: icon)?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)), for: .normal)
        b.accessibilityLabel = label
        b.addTarget(self, action: selector, for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    @objc private func closeTapped() {
        if hasUnsavedChanges {
            let alert = UIAlertController(title: "Save changes?",
                                          message: "This notebook has unsaved changes.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Save & Close", style: .default) { _ in
                self.saveTapped(); self.dismiss(animated: true)
            })
            alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { _ in
                self.dismiss(animated: true)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func saveTapped() {
        // Pull current source from each cell view back into the model.
        for (i, cv) in cellViews.enumerated() where i < notebook.cells.count {
            let src = cv.currentSource()
            notebook.cells[i].source = src
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .map { (idx, line) in
                    // nbformat: each line gets its own "\n" except the last
                    idx == src.split(separator: "\n", omittingEmptySubsequences: false).count - 1
                        ? String(line) : String(line) + "\n"
                }
        }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(notebook)
            try data.write(to: fileURL, options: .atomic)
            hasUnsavedChanges = false
            navigationItem.title = fileURL.lastPathComponent
        } catch {
            let alert = UIAlertController(title: "Save failed",
                                          message: error.localizedDescription,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    private var hasUnsavedChanges = false {
        didSet {
            navigationItem.title = hasUnsavedChanges
                ? "● " + fileURL.lastPathComponent
                : fileURL.lastPathComponent
            // When embedded, the inline modified-dot mirrors the
            // navigationItem.title indicator from the modal path.
            inlineModifiedDot?.isHidden = !hasUnsavedChanges
        }
    }

    @objc private func runAllTapped() {
        for cv in cellViews where cv.cell.cellType == "code" {
            runCell(cv)
        }
    }

    @objc private func restartKernelTapped() {
        // Signal the Python side to clear the notebook namespace.
        // Falls back gracefully if no kernel daemon is running.
        let path = NSTemporaryDirectory()
            .appending("latex_signals/notebook_restart_\(executionScope).txt")
        try? "1".write(toFile: path, atomically: true, encoding: .utf8)
        // Reset execution counts in UI
        for cv in cellViews where cv.cell.cellType == "code" {
            cv.setExecutionCount(nil)
            cv.setOutputs([])
        }
        for i in notebook.cells.indices {
            notebook.cells[i].outputs = []
            notebook.cells[i].executionCount = nil
        }
        nextExecCount = 1
    }

    // MARK: Layout

    private func setupLayout() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        // Embedded: scroll starts below the inline toolbar (36pt).
        // Modal:    scroll starts at the safe-area top.
        let topAnchor: NSLayoutYAxisAnchor =
            (inlineToolbar?.bottomAnchor) ?? view.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 80, right: 14)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    // MARK: Cell build

    private func buildCellViews() {
        cellViews.forEach { $0.removeFromSuperview() }
        cellViews.removeAll()
        for (i, cell) in notebook.cells.enumerated() {
            let cv = NotebookCellView(cell: cell, index: i)
            cv.onRun       = { [weak self] in self?.runCell(cv) }
            cv.onSourceChanged = { [weak self] in self?.hasUnsavedChanges = true }
            cv.onInsertBelow = { [weak self] kind in self?.insertCell(after: cv, kind: kind) }
            cv.onDelete    = { [weak self] in self?.deleteCell(cv) }
            cv.onMoveUp    = { [weak self] in self?.moveCell(cv, by: -1) }
            cv.onMoveDown  = { [weak self] in self?.moveCell(cv, by:  1) }
            cv.onToggleMarkdown = { [weak self] in self?.toggleMarkdownPreview(cv) }
            cellViews.append(cv)
            stack.addArrangedSubview(cv)
        }
    }

    private func insertCell(after cv: NotebookCellView, kind: String) {
        guard let idx = cellViews.firstIndex(of: cv) else { return }
        let newCell = Cell(cellType: kind, source: [""], outputs: [],
                           executionCount: nil, metadata: [:])
        notebook.cells.insert(newCell, at: idx + 1)
        hasUnsavedChanges = true
        buildCellViews()
    }

    private func deleteCell(_ cv: NotebookCellView) {
        guard let idx = cellViews.firstIndex(of: cv),
              notebook.cells.count > 1 else { return }
        notebook.cells.remove(at: idx)
        hasUnsavedChanges = true
        buildCellViews()
    }

    private func moveCell(_ cv: NotebookCellView, by delta: Int) {
        guard let idx = cellViews.firstIndex(of: cv) else { return }
        let new = idx + delta
        guard new >= 0, new < notebook.cells.count else { return }
        notebook.cells.swapAt(idx, new)
        hasUnsavedChanges = true
        buildCellViews()
    }

    private func toggleMarkdownPreview(_ cv: NotebookCellView) {
        cv.toggleMarkdownPreview()
    }

    // MARK: Cell execution

    private func runCell(_ cv: NotebookCellView) {
        guard cv.cell.cellType == "code" else {
            // Markdown cells: just re-render the preview
            cv.toggleMarkdownPreview(); return
        }
        let src = cv.currentSource()
        let execId = "\(executionScope)_\(nextExecCount)"
        let count = nextExecCount
        nextExecCount += 1
        cv.setExecutionCount(count)
        cv.setOutputs([])
        cv.setBusy(true)
        inFlightCount += 1

        // Ship request: code, exec_id, notebook scope
        let sigDir = NSTemporaryDirectory().appending("latex_signals/")
        try? FileManager.default.createDirectory(atPath: sigDir,
                                                 withIntermediateDirectories: true)
        let req: [String: Any] = [
            "exec_id": execId,
            "scope":   executionScope,
            "code":    src,
        ]
        let reqPath = sigDir + "notebook_exec_request_\(execId).json"
        let respPath = sigDir + "notebook_exec_response_\(execId).json"
        guard let data = try? JSONSerialization.data(withJSONObject: req) else { return }
        try? data.write(to: URL(fileURLWithPath: reqPath))

        // Poll for response (60 s budget)
        let deadline = Date().addingTimeInterval(60)
        func tick() {
            if FileManager.default.fileExists(atPath: respPath),
               let respData = try? Data(contentsOf: URL(fileURLWithPath: respPath)),
               let resp = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] {
                try? FileManager.default.removeItem(atPath: respPath)
                self.handleExecResponse(cv, resp: resp)
                cv.setBusy(false)
                self.inFlightCount = max(0, self.inFlightCount - 1)
                return
            }
            if Date() > deadline {
                cv.setOutputs([CellOutput(
                    outputType: "error", text: nil, name: nil, data: nil,
                    ename: "TimeoutError",
                    evalue: "cell execution exceeded 60 s",
                    traceback: nil)])
                cv.setBusy(false)
                self.inFlightCount = max(0, self.inFlightCount - 1)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: tick)
        }
        tick()
    }

    private func handleExecResponse(_ cv: NotebookCellView, resp: [String: Any]) {
        var outputs: [CellOutput] = []
        if let stdout = resp["stdout"] as? String, !stdout.isEmpty {
            outputs.append(CellOutput(outputType: "stream", text: [stdout],
                                      name: "stdout", data: nil, ename: nil,
                                      evalue: nil, traceback: nil))
        }
        if let stderr = resp["stderr"] as? String, !stderr.isEmpty {
            outputs.append(CellOutput(outputType: "stream", text: [stderr],
                                      name: "stderr", data: nil, ename: nil,
                                      evalue: nil, traceback: nil))
        }
        if let result = resp["result"] as? String, !result.isEmpty {
            outputs.append(CellOutput(outputType: "execute_result",
                                      text: nil, name: nil,
                                      data: ["text/plain": AnyCodable([result])],
                                      ename: nil, evalue: nil, traceback: nil))
        }
        if let imageB64 = resp["image_b64"] as? String, !imageB64.isEmpty {
            outputs.append(CellOutput(outputType: "display_data",
                                      text: nil, name: nil,
                                      data: ["image/png": AnyCodable(imageB64)],
                                      ename: nil, evalue: nil, traceback: nil))
        }
        if let html = resp["html"] as? String, !html.isEmpty {
            outputs.append(CellOutput(outputType: "display_data",
                                      text: nil, name: nil,
                                      data: ["text/html": AnyCodable([html])],
                                      ename: nil, evalue: nil, traceback: nil))
        }
        if let err = resp["error"] as? [String: Any] {
            outputs.append(CellOutput(outputType: "error",
                                      text: nil, name: nil, data: nil,
                                      ename: err["ename"] as? String,
                                      evalue: err["evalue"] as? String,
                                      traceback: err["traceback"] as? [String]))
        }
        cv.setOutputs(outputs)
        // Mirror into model so save catches it
        if let idx = cellViews.firstIndex(of: cv), idx < notebook.cells.count {
            notebook.cells[idx].outputs = outputs
            notebook.cells[idx].executionCount = cv.executionCount
            hasUnsavedChanges = true
        }
    }

    // MARK: - Static presentation

    static func present(from presenter: UIViewController, fileURL: URL) {
        let vc = NotebookViewController(fileURL: fileURL)
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        presenter.present(nav, animated: true)
    }
}
