import UIKit

// MARK: - ⌘/ keyboard shortcut sheet
//
// One unified list of every key binding in the app — bound to ⌘/ on
// the editor's responder chain. When the user taps ⌘/, this sheet
// appears explaining what every shortcut does, grouped by area.

final class KeyboardShortcutsViewController: UIViewController, UITableViewDataSource {
    private struct Section { let title: String; let rows: [(combo: String, desc: String)] }

    private let sections: [Section] = [
        Section(title: "Editor", rows: [
            ("⌘S",      "Save file"),
            ("⌘R",      "Run script"),
            ("⌘.",      "Stop running script"),
            ("⌘P",      "Quick open file"),
            ("⌘F",      "Find in file"),
            ("⌘⌥F",    "Find & replace"),
            ("⌘/",      "Toggle line comment"),
            ("⌘D",      "Add next selection (multi-cursor)"),
            ("⌘⇧K",    "Delete line"),
            ("⌥↑ / ↓",  "Move line up / down"),
        ]),
        Section(title: "Terminal", rows: [
            ("⌃C",      "Interrupt running task"),
            ("⌃D",      "Send EOF"),
            ("⌃L",      "Clear screen"),
            ("↑ / ↓",   "Command history"),
            ("⇥",       "Tab completion"),
        ]),
        Section(title: "Navigation", rows: [
            ("⌘1 / ⌘2 / ⌘3", "Switch to Editor / Terminal / Output"),
            ("⌘⌥←",   "Previous file"),
            ("⌘⌥→",   "Next file"),
            ("⌘W",      "Close current file"),
        ]),
        Section(title: "Hidden", rows: [
            ("5× tap Settings title", "Browser history"),
            ("3-finger 3× tap System tab", "Reopen last URL in browser"),
        ]),
    ]

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let bg = UIColor(red: 0.098, green: 0.102, blue: 0.114, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Keyboard shortcuts"
        view.backgroundColor = bg
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done))
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.backgroundColor = bg
        table.register(UITableViewCell.self, forCellReuseIdentifier: "kb")
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    @objc private func done() { dismiss(animated: true) }

    func numberOfSections(in t: UITableView) -> Int { sections.count }
    func tableView(_ t: UITableView, titleForHeaderInSection s: Int) -> String? { sections[s].title }
    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { sections[s].rows.count }
    func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = t.dequeueReusableCell(withIdentifier: "kb", for: ip)
        let r = sections[ip.section].rows[ip.row]
        var cfg = UIListContentConfiguration.valueCell()
        cfg.text = r.desc
        cfg.secondaryText = r.combo
        cfg.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        c.contentConfiguration = cfg
        return c
    }
}

// MARK: - Session restore
//
// Tracks the last-opened workspace + file + cursor position +
// terminal scrollback so the next app launch puts the user back
// where they were. UserDefaults-backed (small payloads only — the
// scrollback is capped to 8 KB).

enum SessionRestore {
    private static let d = UserDefaults.standard

    static var lastWorkspace: URL? {
        get { d.url(forKey: "session.lastWorkspace") }
        set { d.set(newValue, forKey: "session.lastWorkspace") }
    }
    static var lastOpenFile: URL? {
        get { d.url(forKey: "session.lastOpenFile") }
        set { d.set(newValue, forKey: "session.lastOpenFile") }
    }
    static var lastCursorLine: Int {
        get { d.integer(forKey: "session.lastCursorLine") }
        set { d.set(newValue, forKey: "session.lastCursorLine") }
    }
    static var lastCursorColumn: Int {
        get { d.integer(forKey: "session.lastCursorColumn") }
        set { d.set(newValue, forKey: "session.lastCursorColumn") }
    }
    static var lastTerminalScrollback: String {
        get { d.string(forKey: "session.lastTerminalScrollback") ?? "" }
        set {
            // Cap at 8 KB — long scrollbacks bloat UserDefaults and slow launch.
            let capped = newValue.count > 8192 ? String(newValue.suffix(8192)) : newValue
            d.set(capped, forKey: "session.lastTerminalScrollback")
        }
    }
}

// MARK: - Workspace switcher
//
// Multiple project roots, switchable from anywhere. A workspace is
// just a directory URL bookmarked via UIBarButtonItem in the file
// browser. The most recent N are tracked; switching swaps
// `lastWorkspace` and posts a notification so VCs can re-scan.

enum WorkspaceRegistry {
    static let didSwitch = Notification.Name("CodeBenchWorkspaceDidSwitch")
    private static let d = UserDefaults.standard
    private static let key = "workspace.recents"

    static func recents() -> [URL] {
        guard let raw = d.array(forKey: key) as? [String] else { return [] }
        return raw.compactMap { URL(string: $0) }
    }

    static func add(_ url: URL) {
        var list = recents()
        list.removeAll { $0 == url }
        list.insert(url, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        d.set(list.map { $0.absoluteString }, forKey: key)
    }

    static func switchTo(_ url: URL) {
        SessionRestore.lastWorkspace = url
        add(url)
        NotificationCenter.default.post(name: didSwitch, object: url)
    }

    /// Present an action sheet listing recent workspaces. Tapping
    /// one fires `WorkspaceRegistry.didSwitch` so the editor can
    /// reload the file tree.
    static func presentPicker(from vc: UIViewController, anchor: UIView? = nil) {
        let list = recents()
        let alert = UIAlertController(title: "Workspaces",
                                      message: list.isEmpty ? "No recent workspaces." : nil,
                                      preferredStyle: .actionSheet)
        for u in list {
            alert.addAction(UIAlertAction(title: u.lastPathComponent,
                                          style: .default) { _ in
                WorkspaceRegistry.switchTo(u)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = alert.popoverPresentationController, let a = anchor {
            pop.sourceView = a
            pop.sourceRect = a.bounds
        }
        vc.present(alert, animated: true)
    }
}
