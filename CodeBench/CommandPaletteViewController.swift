import UIKit

/// VS Code–style command palette. Modal sheet with a search field
/// at top + a fuzzy-matched list of files (`~/Documents/Workspace`
/// recursively) and built-in commands underneath. Tap a row to
/// execute. Cmd+P opens it; Esc / cancel closes it.
///
/// Two item types:
///   • `.file(URL)` — opens the file in the editor (delegate fires
///     openExternalFile so CodeEditor sees it the same way as a
///     file-browser tap)
///   • `.command(name, action)` — runs an arbitrary closure
final class CommandPaletteViewController: UIViewController {

    enum Item {
        case file(URL)
        case command(name: String, subtitle: String, icon: String, action: () -> Void)

        var displayText: String {
            switch self {
            case .file(let url):    return url.lastPathComponent
            case .command(let n, _, _, _): return n
            }
        }
        var subtitle: String {
            switch self {
            case .file(let url):
                let docs = AppPaths.workspaceURL.path + "/"
                return url.path.replacingOccurrences(of: docs, with: "")
            case .command(_, let s, _, _): return s
            }
        }
        var icon: String {
            switch self {
            case .file(let url):
                let ext = url.pathExtension.lowercased()
                switch ext {
                case "py", "pyi": return "doc.text"
                case "tex", "ltx": return "function"
                case "c", "cpp", "h", "hpp", "cc", "cxx": return "chevron.left.forwardslash.chevron.right"
                case "f", "f90", "f95", "for": return "function"
                case "json", "yaml", "yml", "toml": return "doc.zipper"
                case "html", "htm", "css", "js": return "globe"
                default: return "doc"
                }
            case .command(_, _, let icon, _): return icon
            }
        }
    }

    private let searchField = UITextField()
    private let tableView = UITableView()
    private var allItems: [Item] = []
    private var filtered: [Item] = []

    private let bgColor       = UIColor(red: 0.10, green: 0.105, blue: 0.12, alpha: 1)
    private let surfaceColor  = UIColor(red: 0.13, green: 0.135, blue: 0.155, alpha: 1)
    private let textColor     = UIColor(white: 0.95, alpha: 1)
    private let dimColor      = UIColor(white: 0.55, alpha: 1)
    private let accentColor   = UIColor(red: 0.40, green: 0.59, blue: 0.93, alpha: 1)

    init(items: [Item]) {
        self.allItems = items
        self.filtered = items
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        // iOS 15+ sheet styling for an in-context palette feel.
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
        preferredContentSize = CGSize(width: 540, height: 480)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        searchField.becomeFirstResponder()
    }

    private func setupUI() {
        // Header — search field + close
        let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)))
        searchIcon.tintColor = dimColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "Type to search files and commands…"
        searchField.font = UIFont.systemFont(ofSize: 16, weight: .regular).rounded
        searchField.textColor = textColor
        searchField.attributedPlaceholder = NSAttributedString(
            string: "Type to search files and commands…",
            attributes: [.foregroundColor: dimColor])
        searchField.borderStyle = .none
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.smartDashesType = .no
        searchField.smartQuotesType = .no
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchField.delegate = self

        let header = UIView()
        header.backgroundColor = surfaceColor
        header.layer.cornerRadius = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(searchIcon)
        header.addSubview(searchField)
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            searchField.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),
        ])

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .singleLine
        tableView.separatorColor = UIColor(white: 0.18, alpha: 1)
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 56, bottom: 0, right: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 52
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        view.addSubview(header)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 50),

            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func searchChanged() {
        let q = (searchField.text ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            filtered = allItems
        } else {
            // Subsequence match — every char in q must appear in
            // order in the candidate (the standard fuzzy-match the
            // user expects from VS Code / Sublime). Items with the
            // earliest first-match position rank higher.
            filtered = allItems
                .compactMap { item -> (Item, Int)? in
                    let candidate = item.displayText.lowercased()
                    var qi = q.startIndex
                    var firstMatch: String.Index?
                    for ci in candidate.indices {
                        if qi < q.endIndex && candidate[ci] == q[qi] {
                            if firstMatch == nil { firstMatch = ci }
                            qi = q.index(after: qi)
                            if qi == q.endIndex { break }
                        }
                    }
                    guard qi == q.endIndex,
                          let firstMatch else { return nil }
                    let pos = candidate.distance(from: candidate.startIndex, to: firstMatch)
                    return (item, pos)
                }
                .sorted { $0.1 < $1.1 }
                .map { $0.0 }
        }
        tableView.reloadData()
    }
}

extension CommandPaletteViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // Enter activates the first result.
        if let first = filtered.first {
            execute(first)
        }
        return true
    }
}

extension CommandPaletteViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
        filtered.count
    }
    func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: ip)
        let item = filtered[ip.row]
        cell.backgroundColor = .clear
        cell.selectionStyle = .default
        let bg = UIView(); bg.backgroundColor = accentColor.withAlphaComponent(0.18)
        cell.selectedBackgroundView = bg

        var cfg = cell.defaultContentConfiguration()
        cfg.text = item.displayText
        cfg.textProperties.color = textColor
        cfg.textProperties.font = UIFont.systemFont(ofSize: 15, weight: .medium).rounded
        cfg.secondaryText = item.subtitle
        cfg.secondaryTextProperties.color = dimColor
        cfg.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cfg.image = UIImage(systemName: item.icon,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        cfg.imageProperties.tintColor = accentColor
        cfg.imageToTextPadding = 12
        cell.contentConfiguration = cfg
        return cell
    }
    func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        execute(filtered[ip.row])
    }

    private func execute(_ item: Item) {
        dismiss(animated: true) {
            switch item {
            case .file(let url):
                NotificationCenter.default.post(name: .openExternalFile, object: url)
            case .command(_, _, _, let action):
                action()
            }
        }
    }
}
