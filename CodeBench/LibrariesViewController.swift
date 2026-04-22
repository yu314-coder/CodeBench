import UIKit

/// Libraries tab — combines three things in one place:
///   1. **Installed**  — the list of Python packages currently shipped
///                       (app_packages/site-packages) + user-installed
///                       (Documents/site-packages) with version numbers.
///   2. **Docs**       — LibraryDocsViewController's reference material.
///   3. **Install**    — PackageManagerViewController's pip install UI.
///
/// Replaces the previous separate Docs and Packages tabs.
final class LibrariesViewController: UIViewController {

    // Segmented control at top
    private let segmentedControl = UISegmentedControl(items: ["Installed", "Docs", "Install"])

    // Three container views
    private let installedContainer = UIView()
    private let docsContainer      = UIView()
    private let installContainer   = UIView()

    // Child VCs (lazy — docs + install)
    private var docsController:    LibraryDocsViewController?
    private var installController: PackageManagerViewController?

    // Installed list
    private let installedList = InstalledLibsViewController()

    // Delegate forwarded from LibraryDocsViewController — hosted screens can
    // use this to pipe example code into the editor, just like before.
    weak var docsDelegate: LibraryDocsDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.075, green: 0.078, blue: 0.090, alpha: 1.0) // #131417
        buildUI()
        showSegment(0)
    }

    private func buildUI() {
        // Segmented control (dark-theme styled)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.backgroundColor = UIColor(white: 0.13, alpha: 1)
        segmentedControl.selectedSegmentTintColor = UIColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0)
        segmentedControl.setTitleTextAttributes(
            [.foregroundColor: UIColor(white: 0.6, alpha: 1), .font: UIFont.systemFont(ofSize: 13, weight: .semibold)],
            for: .normal)
        segmentedControl.setTitleTextAttributes(
            [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 13, weight: .semibold)],
            for: .selected)
        segmentedControl.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        view.addSubview(segmentedControl)

        // Containers
        installedContainer.translatesAutoresizingMaskIntoConstraints = false
        docsContainer.translatesAutoresizingMaskIntoConstraints = false
        installContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(installedContainer)
        view.addSubview(docsContainer)
        view.addSubview(installContainer)

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            segmentedControl.heightAnchor.constraint(equalToConstant: 34),
        ])
        for c in [installedContainer, docsContainer, installContainer] {
            NSLayoutConstraint.activate([
                c.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 10),
                c.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                c.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                c.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        // Embed the "Installed" VC eagerly (cheap — just a table)
        addChild(installedList)
        installedList.view.translatesAutoresizingMaskIntoConstraints = false
        installedContainer.addSubview(installedList.view)
        NSLayoutConstraint.activate([
            installedList.view.topAnchor.constraint(equalTo: installedContainer.topAnchor),
            installedList.view.leadingAnchor.constraint(equalTo: installedContainer.leadingAnchor),
            installedList.view.trailingAnchor.constraint(equalTo: installedContainer.trailingAnchor),
            installedList.view.bottomAnchor.constraint(equalTo: installedContainer.bottomAnchor),
        ])
        installedList.didMove(toParent: self)
    }

    @objc private func segmentChanged() {
        showSegment(segmentedControl.selectedSegmentIndex)
    }

    private func showSegment(_ index: Int) {
        installedContainer.isHidden = index != 0
        docsContainer.isHidden      = index != 1
        installContainer.isHidden   = index != 2

        // Lazily build Docs
        if index == 1 && docsController == nil {
            let dc = LibraryDocsViewController()
            dc.delegate = docsDelegate
            dc.isCompactMode = false
            addChild(dc)
            dc.view.translatesAutoresizingMaskIntoConstraints = false
            docsContainer.addSubview(dc.view)
            NSLayoutConstraint.activate([
                dc.view.topAnchor.constraint(equalTo: docsContainer.topAnchor),
                dc.view.leadingAnchor.constraint(equalTo: docsContainer.leadingAnchor),
                dc.view.trailingAnchor.constraint(equalTo: docsContainer.trailingAnchor),
                dc.view.bottomAnchor.constraint(equalTo: docsContainer.bottomAnchor),
            ])
            dc.didMove(toParent: self)
            docsController = dc
        }

        // Lazily build Install
        if index == 2 && installController == nil {
            let ic = PackageManagerViewController()
            addChild(ic)
            ic.view.translatesAutoresizingMaskIntoConstraints = false
            installContainer.addSubview(ic.view)
            NSLayoutConstraint.activate([
                ic.view.topAnchor.constraint(equalTo: installContainer.topAnchor),
                ic.view.leadingAnchor.constraint(equalTo: installContainer.leadingAnchor),
                ic.view.trailingAnchor.constraint(equalTo: installContainer.trailingAnchor),
                ic.view.bottomAnchor.constraint(equalTo: installContainer.bottomAnchor),
            ])
            ic.didMove(toParent: self)
            installController = ic
            // Refresh installed list after a successful install so the user can
            // see new packages without having to switch tabs and come back.
            ic.onDidFinishInstall = { [weak self] in
                DispatchQueue.main.async { self?.installedList.refresh() }
            }
        }
    }
}

// MARK: - InstalledLibsViewController
//
// Lists every Python package visible to sys.path, grouped by source
// ("Bundled" = app_packages/site-packages, "User" = Documents/site-packages).
// Version numbers come from the package's *.dist-info/METADATA file.
final class InstalledLibsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchBar = UISearchBar()
    private let emptyLabel = UILabel()
    private let refreshControl = UIRefreshControl()

    struct Pkg {
        let name: String
        let version: String
        let origin: String  // "Bundled" | "User" | "Stdlib"
    }

    private var allPackages: [Pkg] = []
    private var filtered: [Pkg] = []
    private var isLoading = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // Search bar
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.placeholder = "Search installed packages"
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.backgroundColor = .clear
        searchBar.tintColor = .systemBlue
        if let field = searchBar.value(forKey: "searchField") as? UITextField {
            field.textColor = UIColor(white: 0.95, alpha: 1)
            field.backgroundColor = UIColor(white: 0.15, alpha: 1)
            field.attributedPlaceholder = NSAttributedString(
                string: "Search installed packages",
                attributes: [.foregroundColor: UIColor(white: 0.55, alpha: 1)])
        }
        view.addSubview(searchBar)

        // Table
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.separatorInsetReference = .fromCellEdges
        refreshControl.tintColor = UIColor(white: 0.65, alpha: 1)
        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)

        // Empty label
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.text = "Loading…"
        emptyLabel.textColor = UIColor(white: 0.55, alpha: 1)
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),

            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        refresh()
    }

    @objc private func pullToRefresh() { refresh() }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        emptyLabel.text = "Loading…"
        emptyLabel.isHidden = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pkgs = Self.scanInstalledPackages()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.allPackages = pkgs
                self.filtered = pkgs
                self.tableView.reloadData()
                self.isLoading = false
                self.refreshControl.endRefreshing()
                self.emptyLabel.isHidden = !pkgs.isEmpty
                if pkgs.isEmpty { self.emptyLabel.text = "No packages found." }
            }
        }
    }

    /// Scan every site-packages dir on sys.path and collect *.dist-info/METADATA
    /// + top-level package names. Runs on a background queue.
    private static func scanInstalledPackages() -> [Pkg] {
        let fm = FileManager.default
        let bundleSite = Bundle.main.bundleURL
            .appendingPathComponent("app_packages/site-packages", isDirectory: true).path
        let userSite = fm.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("site-packages", isDirectory: true).path

        var pkgs: [Pkg] = []

        func scan(_ path: String, origin: String) {
            guard fm.fileExists(atPath: path),
                  let entries = try? fm.contentsOfDirectory(atPath: path) else { return }

            // 1. Read *.dist-info/METADATA for authoritative name + version
            var haveName: Set<String> = []
            for entry in entries where entry.hasSuffix(".dist-info") {
                let metaPath = (path as NSString).appendingPathComponent("\(entry)/METADATA")
                if let meta = try? String(contentsOfFile: metaPath, encoding: .utf8) {
                    var name = ""
                    var version = ""
                    for line in meta.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true) {
                        let l = String(line)
                        if name.isEmpty, l.hasPrefix("Name: ") {
                            name = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if version.isEmpty, l.hasPrefix("Version: ") {
                            version = String(l.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                        }
                        if !name.isEmpty && !version.isEmpty { break }
                    }
                    if !name.isEmpty {
                        pkgs.append(Pkg(name: name, version: version.isEmpty ? "?" : version, origin: origin))
                        haveName.insert(name.lowercased())
                    }
                }
            }

            // 2. Also add top-level importable dirs that don't have a dist-info
            //    (common for hand-shipped packages like PIL, numpy, etc.)
            for entry in entries {
                let full = (path as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: full, isDirectory: &isDir)
                guard isDir.boolValue, !entry.hasPrefix("_") && !entry.hasPrefix(".") else { continue }
                if entry.hasSuffix(".dist-info") || entry.hasSuffix(".egg-info") { continue }
                // Must contain an __init__.py or a *.so to count as a package
                let hasInit = fm.fileExists(atPath: (full as NSString).appendingPathComponent("__init__.py"))
                let hasSO = (try? fm.contentsOfDirectory(atPath: full))?.contains(where: { $0.hasSuffix(".so") }) ?? false
                guard hasInit || hasSO else { continue }
                if haveName.contains(entry.lowercased()) { continue }
                pkgs.append(Pkg(name: entry, version: "-", origin: origin))
            }
        }

        scan(bundleSite, origin: "Bundled")
        if let userSite = userSite { scan(userSite, origin: "User") }

        // Sort by origin (User first — what the user installed is more interesting),
        // then alphabetical.
        pkgs.sort {
            if $0.origin != $1.origin { return $0.origin > $1.origin }  // "User" > "Bundled" alphabetically
            return $0.name.lowercased() < $1.name.lowercased()
        }
        return pkgs
    }

    // MARK: - UITableView
    func numberOfSections(in tv: UITableView) -> Int { 1 }

    func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int { filtered.count }

    func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? {
        return "\(filtered.count) package\(filtered.count == 1 ? "" : "s")"
    }

    func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: ip)
        let pkg = filtered[ip.row]
        cell.backgroundColor = UIColor(white: 0.12, alpha: 1)
        cell.selectionStyle = .none

        var cfg = cell.defaultContentConfiguration()
        cfg.text = pkg.name
        cfg.textProperties.color = UIColor(white: 0.95, alpha: 1)
        cfg.textProperties.font = .systemFont(ofSize: 15, weight: .semibold)
        cfg.secondaryText = "\(pkg.version) · \(pkg.origin)"
        cfg.secondaryTextProperties.color = pkg.origin == "User"
            ? UIColor(red: 0.4, green: 0.8, blue: 0.4, alpha: 1)
            : UIColor(white: 0.55, alpha: 1)
        cfg.secondaryTextProperties.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        cell.contentConfiguration = cfg
        return cell
    }

    // MARK: - Search
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            filtered = allPackages
        } else {
            filtered = allPackages.filter { $0.name.lowercased().contains(q) }
        }
        tableView.reloadData()
    }
}
