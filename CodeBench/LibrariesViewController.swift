import UIKit

/// Libraries tab — live view of every Python package the running
/// interpreter can see, grouped into:
///   • Pip installed                            (user's Documents/site-packages)
///   • Bundled — Machine Learning               (torch, transformers, peft, …)
///   • Bundled — Scientific Computing           (numpy, scipy, sympy, …)
///   • Bundled — Visualization                  (matplotlib, plotly, seaborn)
///   • Bundled — Animation & Math               (manim, manimpango, …)
///   • Bundled — Media (image/video/audio/docs) (PIL, av, cairo, pypdf, …)
///   • Bundled — LaTeX
///   • Bundled — Web & Network                  (requests, httpx, bs4, …)
///   • Bundled — Data Formats
///   • Bundled — CLI / Terminal UI              (rich, click, textual, …)
///   • Bundled — Testing & Dev Tools            (pytest, black, mypy, …)
///   • Bundled — Templating / Utility
///   • Bundled — Package Management             (pip, setuptools, wheel)
///   • Bundled — CodeBench helpers              (_torch_metal_bridge, _cb_*)
///   • Bundled — Other
///
/// Each section shows its rows in alphabetical order with version
/// strings parsed from `dist-info/METADATA`. Tap a row → action sheet
/// to view docs on PyPI or copy `import <name>` to clipboard.
final class LibrariesViewController: UIViewController {

    private let installedList = InstalledLibsViewController()

    // Delegate kept for source-compat with sites still passing one in
    // (GameViewController). Currently unused — InstalledLibsViewController
    // surfaces docs via Safari rather than piping example code into
    // the editor.
    weak var docsDelegate: LibraryDocsDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.075, green: 0.078, blue: 0.090, alpha: 1.0) // #131417
        buildUI()
    }

    private func buildUI() {
        addChild(installedList)
        installedList.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(installedList.view)
        NSLayoutConstraint.activate([
            installedList.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            installedList.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            installedList.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            installedList.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        installedList.didMove(toParent: self)
    }
}

// MARK: - InstalledLibsViewController

final class InstalledLibsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchBar = UISearchBar()
    private let emptyLabel = UILabel()
    private let refreshControl = UIRefreshControl()

    struct Pkg {
        let name: String
        let version: String
        let origin: String  // "Bundled" | "User"
    }

    struct Section {
        let title: String
        let rows: [Pkg]
    }

    private var allPackages: [Pkg] = []
    private var sections: [Section] = []   // current display (post-filter)
    private var isLoading = false

    // ─── Category map ──────────────────────────────────────────────
    // Bundled packages get sorted into one of these buckets. Anything
    // not listed lands in "Other". Names are matched case-insensitively
    // against the package's normalized identifier (lowercased + "-"→"_").
    // Order of the keys here determines display order.
    private static let CATEGORY_ORDER: [String] = [
        "Machine Learning",
        "Scientific Computing",
        "Visualization",
        "Animation & Math",
        "Media (image / video / audio / docs)",
        "LaTeX",
        "Web & Network",
        "Data Formats",
        "CLI / Terminal UI",
        "Testing & Dev Tools",
        "Templating / Utility",
        "Package Management",
        "CodeBench helpers",
        "Other",
    ]

    private static let CATEGORY_MAP: [String: String] = [
        // Machine Learning
        "torch":             "Machine Learning",
        "transformers":      "Machine Learning",
        "accelerate":        "Machine Learning",
        "peft":              "Machine Learning",
        "tokenizers":        "Machine Learning",
        "safetensors":       "Machine Learning",
        "huggingface_hub":   "Machine Learning",
        "sklearn":           "Machine Learning",
        "torchgen":          "Machine Learning",

        // Scientific Computing
        "numpy":             "Scientific Computing",
        "scipy":             "Scientific Computing",
        "sympy":             "Scientific Computing",
        "mpmath":            "Scientific Computing",
        "networkx":          "Scientific Computing",

        // Visualization
        "matplotlib":        "Visualization",
        "plotly":            "Visualization",
        "_plotly_utils":     "Visualization",
        "seaborn":           "Visualization",
        "mpl_toolkits":      "Visualization",
        "narwhals":          "Visualization",
        "fonttools":         "Visualization",

        // Animation & Math
        "manim":             "Animation & Math",
        "manimpango":        "Animation & Math",
        "mapbox_earcut":     "Animation & Math",
        "isosurfaces":       "Animation & Math",
        "moderngl":          "Animation & Math",
        "moderngl_window":   "Animation & Math",
        "screeninfo":        "Animation & Math",
        "svgelements":       "Animation & Math",
        "pathops":           "Animation & Math",

        // Media
        "pil":               "Media (image / video / audio / docs)",
        "pillow":            "Media (image / video / audio / docs)",
        "av":                "Media (image / video / audio / docs)",
        "cairo":             "Media (image / video / audio / docs)",
        "cairocffi":         "Media (image / video / audio / docs)",
        "cairosvg":          "Media (image / video / audio / docs)",
        "pydub":             "Media (image / video / audio / docs)",
        "audioop":           "Media (image / video / audio / docs)",
        "pypdf":             "Media (image / video / audio / docs)",
        "fpdf":              "Media (image / video / audio / docs)",
        "reportlab":         "Media (image / video / audio / docs)",
        "openpyxl":          "Media (image / video / audio / docs)",
        "xlsxwriter":        "Media (image / video / audio / docs)",
        "et_xmlfile":        "Media (image / video / audio / docs)",

        // LaTeX
        "offlinai_latex":    "LaTeX",

        // Web & Network
        "requests":          "Web & Network",
        "urllib3":           "Web & Network",
        "httpx":             "Web & Network",
        "anyio":             "Web & Network",
        "sniffio":           "Web & Network",
        "charset_normalizer":"Web & Network",
        "certifi":           "Web & Network",
        "idna":              "Web & Network",
        "bs4":               "Web & Network",
        "beautifulsoup4":    "Web & Network",
        "soupsieve":         "Web & Network",
        "defusedxml":        "Web & Network",
        "jwt":               "Web & Network",
        "pyjwt":             "Web & Network",
        "webview":           "Web & Network",
        "pywebview":         "Web & Network",

        // Data Formats
        "yaml":              "Data Formats",
        "pyyaml":            "Data Formats",
        "jsonschema":        "Data Formats",
        "jsonschema_specifications": "Data Formats",
        "referencing":       "Data Formats",
        "rpds":              "Data Formats",
        "fsspec":            "Data Formats",
        "filelock":          "Data Formats",

        // CLI / Terminal UI
        "rich":              "CLI / Terminal UI",
        "click":             "CLI / Terminal UI",
        "typer":             "CLI / Terminal UI",
        "cloup":             "CLI / Terminal UI",
        "shellingham":       "CLI / Terminal UI",
        "textual":           "CLI / Terminal UI",
        "tqdm":              "CLI / Terminal UI",
        "colorama":          "CLI / Terminal UI",
        "markdown_it":       "CLI / Terminal UI",
        "markdown_it_py":    "CLI / Terminal UI",
        "mdurl":             "CLI / Terminal UI",
        "pygments":          "CLI / Terminal UI",

        // Testing & Dev Tools
        "pytest":            "Testing & Dev Tools",
        "_pytest":           "Testing & Dev Tools",
        "pluggy":            "Testing & Dev Tools",
        "iniconfig":         "Testing & Dev Tools",
        "hypothesis":        "Testing & Dev Tools",
        "sortedcontainers":  "Testing & Dev Tools",
        "black":             "Testing & Dev Tools",
        "blib2to3":          "Testing & Dev Tools",
        "isort":             "Testing & Dev Tools",
        "mypy":              "Testing & Dev Tools",
        "pyflakes":          "Testing & Dev Tools",
        "tomli":             "Testing & Dev Tools",
        "tomli_w":           "Testing & Dev Tools",
        "pytokens":          "Testing & Dev Tools",
        "pathspec":          "Testing & Dev Tools",
        "annotated_doc":     "Testing & Dev Tools",
        "annotated_types":   "Testing & Dev Tools",

        // Templating / Utility
        "jinja2":            "Templating / Utility",
        "markupsafe":        "Templating / Utility",
        "regex":             "Templating / Utility",
        "packaging":         "Templating / Utility",
        "more_itertools":    "Templating / Utility",
        "lark":              "Templating / Utility",
        "dateutil":          "Templating / Utility",
        "python_dateutil":   "Templating / Utility",
        "pytz":              "Templating / Utility",
        "pendulum":          "Templating / Utility",
        "attr":              "Templating / Utility",
        "attrs":             "Templating / Utility",
        "cattrs":            "Templating / Utility",
        "platformdirs":      "Templating / Utility",
        "humanize":          "Templating / Utility",
        "tabulate":          "Templating / Utility",
        "watchdog":          "Templating / Utility",
        "psutil":            "Templating / Utility",
        "pycparser":         "Templating / Utility",

        // Package Management
        "pip":               "Package Management",
        "wheel":             "Package Management",
        "setuptools":        "Package Management",
        "pkg_resources":     "Package Management",
        "_distutils_hack":   "Package Management",

        // CodeBench helpers
        "offlinai_ai":       "CodeBench helpers",
        "_torch_metal_bridge": "CodeBench helpers",
        "_cb_training":      "CodeBench helpers",
        "_cb_background":    "CodeBench helpers",
        "_cb_gguf_export":   "CodeBench helpers",
        "sitecustomize":     "CodeBench helpers",
    ]

    private static func categorize(_ name: String) -> String {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "_")
        return CATEGORY_MAP[key] ?? "Other"
    }

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
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 38
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
                self.sections = Self.buildSections(from: pkgs, search: "")
                self.tableView.reloadData()
                self.isLoading = false
                self.refreshControl.endRefreshing()
                let totalRows = self.sections.reduce(0) { $0 + $1.rows.count }
                self.emptyLabel.isHidden = totalRows > 0
                if totalRows == 0 { self.emptyLabel.text = "No packages found." }
            }
        }
    }

    // MARK: - Scanning & grouping

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
                guard isDir.boolValue, !entry.hasPrefix(".") else { continue }
                if entry.hasSuffix(".dist-info") || entry.hasSuffix(".egg-info") { continue }
                if entry == "__pycache__" { continue }
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

        // Sort within each origin alphabetically.
        pkgs.sort { $0.name.lowercased() < $1.name.lowercased() }
        return pkgs
    }

    /// Group packages into displayable sections, optionally filtered by `search`.
    private static func buildSections(from packages: [Pkg], search: String) -> [Section] {
        // Filter first
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty
            ? packages
            : packages.filter { $0.name.lowercased().contains(q) }

        // Split by origin
        var userPkgs: [Pkg] = []
        var bundledByCat: [String: [Pkg]] = [:]
        for p in filtered {
            if p.origin == "User" {
                userPkgs.append(p)
            } else {
                let cat = categorize(p.name)
                bundledByCat[cat, default: []].append(p)
            }
        }

        var out: [Section] = []

        // Pip-installed section (only if anything matches)
        if !userPkgs.isEmpty {
            out.append(Section(
                title: "Pip installed  (\(userPkgs.count))",
                rows: userPkgs))
        }

        // Bundled sections in canonical order
        for cat in CATEGORY_ORDER {
            if let rows = bundledByCat[cat], !rows.isEmpty {
                out.append(Section(
                    title: "Bundled — \(cat)  (\(rows.count))",
                    rows: rows))
            }
        }

        return out
    }

    // MARK: - UITableView

    func numberOfSections(in tv: UITableView) -> Int { sections.count }

    func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
        return sections[s].rows.count
    }

    func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? {
        return sections[s].title
    }

    func tableView(_ tv: UITableView, viewForHeaderInSection s: Int) -> UIView? {
        // Custom header so the Pip-installed section gets accent styling
        // (green tint) to stand out from the Bundled sections (white-ish).
        let title = sections[s].title
        let isPip = title.hasPrefix("Pip installed")

        let container = UIView()
        container.backgroundColor = .clear
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = isPip
            ? UIColor(red: 0.4, green: 0.85, blue: 0.4, alpha: 1)   // green for Pip
            : UIColor(white: 0.7, alpha: 1)                          // dim for bundled
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        return container
    }

    func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: ip)
        let pkg = sections[ip.section].rows[ip.row]
        cell.backgroundColor = UIColor(white: 0.12, alpha: 1)
        cell.selectionStyle = .default
        cell.accessoryType = .disclosureIndicator

        var cfg = cell.defaultContentConfiguration()
        cfg.text = pkg.name
        cfg.textProperties.color = UIColor(white: 0.95, alpha: 1)
        cfg.textProperties.font = .systemFont(ofSize: 15, weight: .semibold)
        cfg.secondaryText = pkg.version
        cfg.secondaryTextProperties.color = pkg.origin == "User"
            ? UIColor(red: 0.4, green: 0.85, blue: 0.4, alpha: 1)
            : UIColor(white: 0.55, alpha: 1)
        cfg.secondaryTextProperties.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        cell.contentConfiguration = cfg
        return cell
    }

    /// Tap a row → action sheet with: open the package's docs page on
    /// PyPI in Safari, copy `import <pkg>` to clipboard, or close.
    func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        let pkg = sections[ip.section].rows[ip.row]
        let slug = pkg.name
            .replacingOccurrences(of: " ", with: "-")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pkg.name
        let pypi = URL(string: "https://pypi.org/project/\(slug)/")
        let modName = pkg.name
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()

        let body = "version  \(pkg.version)\norigin   \(pkg.origin)"
        let alert = UIAlertController(title: pkg.name, message: body,
                                      preferredStyle: .actionSheet)
        if let url = pypi {
            alert.addAction(UIAlertAction(title: "View docs on PyPI", style: .default) { _ in
                UIApplication.shared.open(url)
            })
        }
        alert.addAction(UIAlertAction(title: "Copy `import \(modName)`", style: .default) { _ in
            UIPasteboard.general.string = "import \(modName)"
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        // iPad action sheets must be anchored.
        if let pop = alert.popoverPresentationController,
           let cell = tv.cellForRow(at: ip) {
            pop.sourceView = cell
            pop.sourceRect = cell.bounds
            pop.permittedArrowDirections = .any
        }
        present(alert, animated: true)
    }

    // MARK: - Search
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        sections = Self.buildSections(from: allPackages, search: searchText)
        let totalRows = sections.reduce(0) { $0 + $1.rows.count }
        emptyLabel.isHidden = totalRows > 0
        if totalRows == 0 {
            emptyLabel.text = searchText.trimmingCharacters(in: .whitespaces).isEmpty
                ? "No packages found."
                : "No matches for \"\(searchText)\""
        }
        tableView.reloadData()
    }
}
