//
//  DebuggerUI.swift
//  CodeBench
//
//  Visual debugger UI driven by the Python-side `codebench_debug`
//  module. Polls `debug_state.json` for updates (file/line/locals/
//  stack), shows a floating toolbar with Continue/Step Over/Step
//  Into/Step Out/Stop, and a slide-in variable inspector panel.
//
//  Signal protocol (mirrors codebench_debug.py):
//    debug_state.json    — Python writes after every stop. Swift reads.
//    debug_command.txt   — Swift writes. Python reads.
//    debug_eval_result.txt — Python writes (in response to "eval:expr").
//
//  Tied into MonacoEditorView via `setDebugCurrentLine(line)` to paint
//  a golden arrow in the gutter.
//
//  Used by CodeEditorViewController (one instance per editor VC).
//

import Foundation
import UIKit

final class DebuggerUI {

    // MARK: - State

    struct DebugState: Codable {
        let file: String?
        let line: Int?
        let function: String?
        let stack: [Frame]?
        let locals: [String: String]?
        let globals: [String: String]?
        let status: String?       // "running" | "stopped" | "done"
        let exceptionMsg: String?
        let returnValue: String?

        struct Frame: Codable {
            let file: String
            let line: Int
            let function: String
            enum CodingKeys: String, CodingKey {
                case file
                case line
                case function = "func"
            }
        }

        enum CodingKeys: String, CodingKey {
            case file, line, stack, locals, globals, status
            case function = "func"
            case exceptionMsg = "exception"
            case returnValue = "return_value"
        }
    }

    weak var presenter: UIViewController?
    weak var monacoView: MonacoEditorView?

    // MARK: - UI

    private var toolbar: UIView?
    private var inspectorPanel: UIView?
    private var inspectorTable: UITableView?
    private var stackLabel: UILabel?

    /// Locals/globals being displayed, flat list for the table.
    private var inspectorRows: [(String, String, Bool)] = []   // (name, value, isGlobal)

    /// Last known state — used to suppress UI updates when nothing
    /// actually changed (file/line is the dedupe key).
    private var lastStateKey: String = ""

    // MARK: - Watcher

    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1
    private let watchQueue = DispatchQueue(label: "codebench.debug.watch", qos: .userInitiated)

    private var signalDir: String {
        NSTemporaryDirectory().appending("latex_signals/")
    }
    private var statePath: String  { signalDir + "debug_state.json" }
    private var cmdPath: String    { signalDir + "debug_command.txt" }
    private var evalRespPath: String { signalDir + "debug_eval_result.txt" }

    // MARK: - Init / lifecycle

    init(presenter: UIViewController, monaco: MonacoEditorView) {
        self.presenter = presenter
        self.monacoView = monaco
        try? FileManager.default.createDirectory(atPath: signalDir,
                                                 withIntermediateDirectories: true)
    }

    deinit { stop() }

    /// Start watching `debug_state.json`. Called once at VC setup —
    /// the actual UI only materialises when a debug session starts
    /// (status = running / stopped).
    func start() {
        guard watcher == nil else { return }
        // Make sure the file exists so kqueue can attach.
        if !FileManager.default.fileExists(atPath: statePath) {
            FileManager.default.createFile(atPath: statePath, contents: Data())
        }
        let fd = open(statePath, O_EVTONLY)
        guard fd >= 0 else { return }
        watcherFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: watchQueue)
        src.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.readState() }
        }
        src.setCancelHandler { [weak self] in
            if let self, self.watcherFD >= 0 {
                close(self.watcherFD); self.watcherFD = -1
            }
        }
        src.resume()
        watcher = src
        // Drain immediately in case state already exists.
        DispatchQueue.main.async { [weak self] in self?.readState() }
    }

    func stop() {
        watcher?.cancel(); watcher = nil
        hideUI()
    }

    // MARK: - State reading

    private func readState() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              !data.isEmpty else { return }
        guard let state = try? JSONDecoder().decode(DebugState.self, from: data) else {
            // File may be mid-write; ignore.
            return
        }
        applyState(state)
    }

    private func applyState(_ state: DebugState) {
        let key = "\(state.status ?? "")|\(state.file ?? "")|\(state.line ?? 0)"
        if key == lastStateKey { return }
        lastStateKey = key

        switch state.status {
        case "running":
            showToolbarIfNeeded()
            updateToolbar(status: "running", message: nil)
            paintCurrentLine(nil)
        case "stopped":
            showToolbarIfNeeded()
            let msg = state.exceptionMsg.map { "⚠️ " + $0 } ??
                      state.returnValue.map { "↩︎ " + $0 } ?? nil
            updateToolbar(status: "stopped", message: msg)
            paintCurrentLine(state.line)
            buildInspectorRows(state)
            inspectorTable?.reloadData()
            updateStackLabel(state.stack ?? [])
        case "done":
            hideUI()
        default:
            break
        }
    }

    // MARK: - Toolbar

    private func showToolbarIfNeeded() {
        guard toolbar == nil, let host = presenter?.view else { return }
        let bar = UIView()
        bar.backgroundColor = UIColor(white: 0.10, alpha: 0.96)
        bar.layer.cornerRadius = 14
        bar.layer.borderWidth = 1
        bar.layer.borderColor = UIColor.systemPurple.withAlphaComponent(0.4).cgColor
        bar.layer.shadowColor = UIColor.black.cgColor
        bar.layer.shadowOpacity = 0.5
        bar.layer.shadowRadius = 12
        bar.layer.shadowOffset = CGSize(width: 0, height: 4)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let buttons: [(String, String, Selector)] = [
            ("play.fill",        "Continue",  #selector(cmdContinue)),
            ("arrow.right",      "Step Over", #selector(cmdNext)),
            ("arrow.turn.down.right", "Step Into", #selector(cmdStep)),
            ("arrow.turn.up.right",   "Step Out",  #selector(cmdReturn)),
            ("stop.fill",        "Stop",      #selector(cmdQuit)),
        ]
        let actionHost = ActionForwarder(target: self)
        actionForwarder = actionHost

        var arranged: [UIView] = []
        for (icon, hint, sel) in buttons {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: icon)?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
            b.tintColor = .white
            b.accessibilityLabel = hint
            b.addTarget(actionHost, action: sel, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            b.heightAnchor.constraint(equalToConstant: 40).isActive = true
            arranged.append(b)
        }
        let inspectBtn = UIButton(type: .system)
        inspectBtn.setImage(UIImage(systemName: "list.bullet.rectangle")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        inspectBtn.tintColor = .systemCyan
        inspectBtn.accessibilityLabel = "Variable inspector"
        inspectBtn.addTarget(actionHost, action: #selector(ActionForwarder.toggleInspector),
                             for: .touchUpInside)
        inspectBtn.widthAnchor.constraint(equalToConstant: 40).isActive = true
        arranged.append(inspectBtn)

        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .horizontal; stack.spacing = 4; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
        ])

        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.centerXAnchor.constraint(equalTo: host.centerXAnchor),
        ])

        self.toolbar = bar
        // Subtle entrance animation
        bar.alpha = 0; bar.transform = CGAffineTransform(translationX: 0, y: -20)
        UIView.animate(withDuration: 0.25) {
            bar.alpha = 1; bar.transform = .identity
        }
    }

    private func updateToolbar(status: String, message: String?) {
        // Visual cue: golden border when stopped, dim when running.
        toolbar?.layer.borderColor = (status == "stopped" ?
                                      UIColor.systemYellow :
                                      UIColor.systemGreen).withAlphaComponent(0.55).cgColor
    }

    private func hideUI() {
        toolbar?.removeFromSuperview(); toolbar = nil
        hideInspector()
        paintCurrentLine(nil)
        lastStateKey = ""
    }

    // MARK: - Inspector panel

    private func toggleInspector() {
        if inspectorPanel != nil { hideInspector() } else { showInspector() }
    }

    private func showInspector() {
        guard let host = presenter?.view else { return }
        let panel = UIView()
        panel.backgroundColor = UIColor(white: 0.07, alpha: 0.97)
        panel.layer.cornerRadius = 12
        panel.layer.borderWidth = 1
        panel.layer.borderColor = UIColor.systemPurple.withAlphaComponent(0.3).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "Variables"
        title.font = .systemFont(ofSize: 13, weight: .bold)
        title.textColor = .systemCyan

        let stackLabelLocal = UILabel()
        stackLabelLocal.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        stackLabelLocal.textColor = .secondaryLabel
        stackLabelLocal.numberOfLines = 4
        self.stackLabel = stackLabelLocal

        let table = UITableView(frame: .zero, style: .plain)
        table.dataSource = self
        table.delegate = self
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorColor = UIColor(white: 0.2, alpha: 0.5)
        table.rowHeight = 32
        table.register(UITableViewCell.self, forCellReuseIdentifier: "var")
        self.inspectorTable = table

        let header = UIStackView(arrangedSubviews: [title, stackLabelLocal])
        header.axis = .vertical; header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        let container = UIStackView(arrangedSubviews: [header, table])
        container.axis = .vertical; container.spacing = 10
        container.isLayoutMarginsRelativeArrangement = true
        container.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        container.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: panel.topAnchor),
            container.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 60),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            panel.widthAnchor.constraint(equalToConstant: 320),
            panel.heightAnchor.constraint(equalToConstant: 380),
        ])
        self.inspectorPanel = panel

        panel.transform = CGAffineTransform(translationX: 340, y: 0)
        UIView.animate(withDuration: 0.25) { panel.transform = .identity }
        table.reloadData()
    }

    private func hideInspector() {
        guard let panel = inspectorPanel else { return }
        UIView.animate(withDuration: 0.2,
                       animations: { panel.transform = CGAffineTransform(translationX: 340, y: 0) },
                       completion: { _ in panel.removeFromSuperview() })
        inspectorPanel = nil
        inspectorTable = nil
        stackLabel = nil
    }

    private func buildInspectorRows(_ state: DebugState) {
        var rows: [(String, String, Bool)] = []
        for (k, v) in (state.locals ?? [:]).sorted(by: { $0.key < $1.key }) {
            rows.append((k, v, false))
        }
        for (k, v) in (state.globals ?? [:]).sorted(by: { $0.key < $1.key }) {
            rows.append((k, v, true))
        }
        self.inspectorRows = rows
    }

    private func updateStackLabel(_ stack: [DebugState.Frame]) {
        let summary = stack.prefix(3).map {
            "\($0.function)  \(($0.file as NSString).lastPathComponent):\($0.line)"
        }.joined(separator: "\n")
        stackLabel?.text = summary
    }

    // MARK: - Gutter highlight

    private func paintCurrentLine(_ line: Int?) {
        guard let view = monacoView else { return }
        view.setDebugCurrentLine(line)
    }

    // MARK: - Command write

    @objc fileprivate func cmdContinue() { writeCommand("continue") }
    @objc fileprivate func cmdStep()     { writeCommand("step") }
    @objc fileprivate func cmdNext()     { writeCommand("next") }
    @objc fileprivate func cmdReturn()   { writeCommand("return") }
    @objc fileprivate func cmdQuit()     { writeCommand("quit") }

    private func writeCommand(_ cmd: String) {
        let tmp = cmdPath + ".tmp"
        try? cmd.write(toFile: tmp, atomically: true, encoding: .utf8)
        try? FileManager.default.moveItem(atPath: tmp, toPath: cmdPath)
    }

    // MARK: - ActionForwarder

    private var actionForwarder: ActionForwarder?

    @objc fileprivate final class ActionForwarder: NSObject {
        weak var target: DebuggerUI?
        init(target: DebuggerUI) { self.target = target }
        @objc func cmdContinue() { target?.cmdContinue() }
        @objc func cmdStep()     { target?.cmdStep() }
        @objc func cmdNext()     { target?.cmdNext() }
        @objc func cmdReturn()   { target?.cmdReturn() }
        @objc func cmdQuit()     { target?.cmdQuit() }
        @objc func toggleInspector() { target?.toggleInspector() }
    }
}

// MARK: - Table data source

extension DebuggerUI: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ t: UITableView, titleForHeaderInSection s: Int) -> String? {
        s == 0 ? "Locals" : "Globals"
    }

    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int {
        let locals = inspectorRows.filter { !$0.2 }.count
        let globals = inspectorRows.filter { $0.2 }.count
        return s == 0 ? locals : globals
    }

    func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = t.dequeueReusableCell(withIdentifier: "var", for: ip)
        let isGlobal = ip.section == 1
        let filtered = inspectorRows.filter { $0.2 == isGlobal }
        guard ip.row < filtered.count else { return cell }
        let (name, value, _) = filtered[ip.row]
        var content = cell.defaultContentConfiguration()
        content.text = name
        content.secondaryText = value
        content.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        content.textProperties.color = isGlobal ? .systemTeal : .systemGreen
        content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        content.secondaryTextProperties.color = .label
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingTail
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        return cell
    }
}
