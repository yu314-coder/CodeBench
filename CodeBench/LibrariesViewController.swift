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

    /// Accessible to PackageDetailViewController in this file so the
    /// detail view's hero header can pick the same category icon.
    fileprivate static func categorize(_ name: String) -> String {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "_")
        return CATEGORY_MAP[key] ?? "Other"
    }

    /// SF Symbol name + accent color for each category. Used to give
    /// each row a distinct visual identity instead of stock-iOS table
    /// rows. Returns a small image for cell badges and a tint color
    /// for the row's left-edge stripe.
    static func iconForCategory(_ category: String) -> (symbol: String, tint: UIColor) {
        switch category {
        case "Pip installed":
            return ("arrow.down.app.fill",
                    UIColor(red: 0.32, green: 0.83, blue: 0.45, alpha: 1))     // green
        case "Machine Learning":
            return ("brain.head.profile",
                    UIColor(red: 0.69, green: 0.51, blue: 0.95, alpha: 1))     // purple
        case "Scientific Computing":
            return ("function",
                    UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1))     // blue
        case "Visualization":
            return ("chart.line.uptrend.xyaxis",
                    UIColor(red: 0.95, green: 0.60, blue: 0.30, alpha: 1))     // orange
        case "Animation & Math":
            return ("wand.and.stars",
                    UIColor(red: 0.95, green: 0.45, blue: 0.70, alpha: 1))     // pink
        case "Media (image / video / audio / docs)":
            return ("photo.on.rectangle.angled",
                    UIColor(red: 0.95, green: 0.45, blue: 0.45, alpha: 1))     // red
        case "LaTeX":
            return ("x.squareroot",
                    UIColor(red: 0.85, green: 0.72, blue: 0.35, alpha: 1))     // gold
        case "Web & Network":
            return ("network",
                    UIColor(red: 0.35, green: 0.78, blue: 0.85, alpha: 1))     // cyan
        case "Data Formats":
            return ("tablecells",
                    UIColor(red: 0.40, green: 0.80, blue: 0.70, alpha: 1))     // teal
        case "CLI / Terminal UI":
            return ("terminal",
                    UIColor(red: 0.55, green: 0.65, blue: 0.95, alpha: 1))     // indigo
        case "Testing & Dev Tools":
            return ("checkmark.shield",
                    UIColor(red: 0.92, green: 0.85, blue: 0.30, alpha: 1))     // yellow
        case "Templating / Utility":
            return ("wrench.and.screwdriver",
                    UIColor(red: 0.65, green: 0.70, blue: 0.78, alpha: 1))     // slate
        case "Package Management":
            return ("shippingbox",
                    UIColor(red: 0.55, green: 0.78, blue: 0.55, alpha: 1))     // mint
        case "CodeBench helpers":
            return ("sparkles",
                    UIColor(red: 0.95, green: 0.78, blue: 0.35, alpha: 1))     // amber
        default:
            return ("shippingbox",
                    UIColor(white: 0.55, alpha: 1))
        }
    }

    /// Per-row category — Pip-installed rows get their own marker.
    static func iconForPackage(name: String, origin: String) -> (symbol: String, tint: UIColor) {
        if origin == "User" {
            return iconForCategory("Pip installed")
        }
        return iconForCategory(categorize(name))
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
        // Custom header: category icon + title, color-coded by category.
        // Gives each section a clear visual identity instead of stock-iOS
        // text headers.
        let title = sections[s].title
        let isPip = title.hasPrefix("Pip installed")

        // Extract the bare category name for icon lookup.
        // "Bundled — Machine Learning  (8)"  →  "Machine Learning"
        // "Pip installed  (3)"               →  "Pip installed"
        let catName: String = {
            if isPip { return "Pip installed" }
            var t = title
            if let r = t.range(of: "Bundled — ") { t.removeSubrange(t.startIndex..<r.upperBound) }
            if let r = t.range(of: "  (")        { t = String(t[..<r.lowerBound]) }
            return t
        }()
        let (symbol, tint) = Self.iconForCategory(catName)

        let container = UIView()
        container.backgroundColor = .clear

        // Tinted icon disc
        let iconBg = UIView()
        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.backgroundColor = tint.withAlphaComponent(0.18)
        iconBg.layer.cornerRadius = 9
        container.addSubview(iconBg)

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIImage(systemName: symbol)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit
        container.addSubview(icon)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = isPip
            ? UIColor(red: 0.4, green: 0.85, blue: 0.4, alpha: 1)
            : UIColor(white: 0.75, alpha: 1)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            iconBg.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            iconBg.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 1),
            iconBg.widthAnchor.constraint(equalToConstant: 18),
            iconBg.heightAnchor.constraint(equalToConstant: 18),
            icon.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: iconBg.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 1),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
        return container
    }

    func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: ip)
        let pkg = sections[ip.section].rows[ip.row]
        let (symbol, tint) = Self.iconForPackage(name: pkg.name, origin: pkg.origin)

        cell.backgroundColor = UIColor(white: 0.12, alpha: 1)
        cell.selectionStyle = .default
        cell.accessoryType = .disclosureIndicator

        // Strip any prior custom subviews from reused cells (cellForRowAt
        // gets called with recycled instances; without this the icon
        // accumulates).
        cell.contentView.subviews
            .filter { $0.tag == 9101 || $0.tag == 9102 || $0.tag == 9103 }
            .forEach { $0.removeFromSuperview() }

        // Left-edge category accent stripe — 3px tall colored bar that
        // matches the section's tint. Distinct from default iOS table
        // rows, gives the user a quick category cue without reading
        // the section header again.
        let stripe = UIView()
        stripe.tag = 9101
        stripe.translatesAutoresizingMaskIntoConstraints = false
        stripe.backgroundColor = tint
        stripe.layer.cornerRadius = 1.5
        cell.contentView.addSubview(stripe)

        // Tinted icon disc on the left
        let iconBg = UIView()
        iconBg.tag = 9102
        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.backgroundColor = tint.withAlphaComponent(0.18)
        iconBg.layer.cornerRadius = 8
        cell.contentView.addSubview(iconBg)

        let icon = UIImageView()
        icon.tag = 9103
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIImage(systemName: symbol)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit
        cell.contentView.addSubview(icon)

        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 6),
            stripe.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 6),
            stripe.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -6),
            stripe.widthAnchor.constraint(equalToConstant: 3),
            iconBg.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 14),
            iconBg.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            iconBg.widthAnchor.constraint(equalToConstant: 30),
            iconBg.heightAnchor.constraint(equalToConstant: 30),
            icon.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])

        var cfg = cell.defaultContentConfiguration()
        cfg.text = pkg.name
        cfg.textProperties.color = UIColor(white: 0.95, alpha: 1)
        cfg.textProperties.font = .systemFont(ofSize: 15, weight: .semibold)
        cfg.secondaryText = pkg.version
        cfg.secondaryTextProperties.color = pkg.origin == "User"
            ? UIColor(red: 0.4, green: 0.85, blue: 0.4, alpha: 1)
            : UIColor(white: 0.55, alpha: 1)
        cfg.secondaryTextProperties.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        // Indent text past the icon disc.
        cfg.directionalLayoutMargins.leading = 50
        cell.contentConfiguration = cfg
        return cell
    }

    /// Tap a row:
    ///   - Bundled package → open in-app detail view with summary,
    ///     iOS-specific notes, example code, and import helper. We
    ///     own this content so we can call out iPad-specific gotchas.
    ///   - Pip-installed package → action sheet with PyPI link (we
    ///     don't know what arbitrary user-installed packages do).
    func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        let pkg = sections[ip.section].rows[ip.row]
        if pkg.origin == "User" {
            presentPyPIActionSheet(for: pkg, anchor: tv.cellForRow(at: ip))
        } else {
            presentBundledDetail(for: pkg)
        }
    }

    /// Bundled → push the rich in-app detail.
    private func presentBundledDetail(for pkg: Pkg) {
        let detailVC = PackageDetailViewController(pkg: pkg)
        let nav = UINavigationController(rootViewController: detailVC)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    /// Pip-installed → simple action sheet (we don't ship docs for it).
    private func presentPyPIActionSheet(for pkg: Pkg, anchor: UIView?) {
        let slug = pkg.name
            .replacingOccurrences(of: " ", with: "-")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pkg.name
        let pypi = URL(string: "https://pypi.org/project/\(slug)/")
        let modName = pkg.name
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        let body = "version  \(pkg.version)\norigin   \(pkg.origin)  (pip-installed)"
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
        if let pop = alert.popoverPresentationController, let anchor = anchor {
            pop.sourceView = anchor
            pop.sourceRect = anchor.bounds
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


// MARK: - PackageDetailViewController
//
// In-app detail screen for a bundled package. Shows our own
// description + iOS-specific notes + a copy-paste example, so users
// don't have to leave the app to find out what each library does (or
// how it behaves on iPad specifically — which is the more useful
// info that PyPI / upstream docs won't tell them).
//
// Data lives in a static dictionary BELOW. Adding a new bundled
// package = one new entry keyed by lowercased name. Packages without
// an entry fall back to a generic "transitive dependency" message
// and still get the import helper + PyPI link.

final class PackageDetailViewController: UIViewController {

    struct Info {
        let summary: String        // 1-2 paragraph what-it-is
        let iosNotes: String?      // iOS-specific gotchas / workarounds
        let example: String?       // monospaced sample code
    }

    private let pkg: InstalledLibsViewController.Pkg
    private let info: Info

    init(pkg: InstalledLibsViewController.Pkg) {
        self.pkg = pkg
        self.info = Self.lookup(pkg.name)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.075, green: 0.078, blue: 0.090, alpha: 1)
        title = pkg.name
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissSelf))
        navigationController?.navigationBar.tintColor = .systemBlue
        navigationController?.navigationBar.titleTextAttributes = [
            .foregroundColor: UIColor(white: 0.95, alpha: 1)
        ]
        navigationController?.navigationBar.barStyle = .black
        buildUI()
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    private func buildUI() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.backgroundColor = .clear
        view.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 18
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        // Header: version + origin
        stack.addArrangedSubview(makeMetaRow())

        // Summary
        stack.addArrangedSubview(makeSection(
            title: "Description",
            body: info.summary,
            mono: false))

        // iOS notes (only if present)
        if let notes = info.iosNotes, !notes.isEmpty {
            stack.addArrangedSubview(makeSection(
                title: "iOS-specific notes",
                body: notes,
                mono: false,
                accentColor: UIColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1)))  // amber
        }

        // Example (mono)
        if let ex = info.example, !ex.isEmpty {
            stack.addArrangedSubview(makeSection(
                title: "Example",
                body: ex,
                mono: true))
        }

        // Action buttons row
        stack.addArrangedSubview(makeButtonsRow())

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -40),
        ])
    }

    // MARK: - View builders

    private func makeMetaRow() -> UIView {
        // Hero header: big category-tinted icon on the left + version
        // text + category name pill on the right. Replaces the prior
        // plain "version + BUNDLED" row with something visually
        // distinctive that anchors the detail view.
        let row = UIView()
        let category = InstalledLibsViewController.categorize(pkg.name)
        let (symbol, tint) = InstalledLibsViewController.iconForCategory(category)

        // Hero icon disc (60×60, tinted background)
        let iconBg = UIView()
        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.backgroundColor = tint.withAlphaComponent(0.18)
        iconBg.layer.cornerRadius = 12
        iconBg.layer.borderWidth = 1
        iconBg.layer.borderColor = tint.withAlphaComponent(0.35).cgColor
        row.addSubview(iconBg)

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIImage(systemName: symbol)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold))
        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit
        row.addSubview(icon)

        // Right side: stack of version + category pill
        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 6
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(textStack)

        let version = UILabel()
        version.text = "v\(pkg.version)"
        version.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        version.textColor = UIColor(white: 0.92, alpha: 1)
        textStack.addArrangedSubview(version)

        // Pill row: category name + BUNDLED tag
        let pillRow = UIStackView()
        pillRow.axis = .horizontal
        pillRow.spacing = 6
        pillRow.alignment = .center
        textStack.addArrangedSubview(pillRow)

        let catPill = Self.makePill(text: category, tint: tint, filled: false)
        pillRow.addArrangedSubview(catPill)
        let bundledPill = Self.makePill(text: "BUNDLED",
                                        tint: UIColor(white: 0.65, alpha: 1),
                                        filled: true)
        pillRow.addArrangedSubview(bundledPill)
        pillRow.addArrangedSubview(UIView())   // flexible spacer

        NSLayoutConstraint.activate([
            iconBg.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            iconBg.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconBg.widthAnchor.constraint(equalToConstant: 60),
            iconBg.heightAnchor.constraint(equalToConstant: 60),
            icon.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
            textStack.leadingAnchor.constraint(equalTo: iconBg.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 64),
        ])
        return row
    }

    /// Small rounded pill label — used for category / origin tags in
    /// the detail-view hero header.
    private static func makePill(text: String, tint: UIColor, filled: Bool) -> UIView {
        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        if filled {
            pill.backgroundColor = tint
        } else {
            pill.backgroundColor = tint.withAlphaComponent(0.18)
            pill.layer.borderColor = tint.withAlphaComponent(0.5).cgColor
            pill.layer.borderWidth = 1
        }
        pill.layer.cornerRadius = 5
        pill.layer.masksToBounds = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = filled ? UIColor(white: 0.08, alpha: 1) : tint
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
        ])
        return pill
    }

    private func makeSection(title: String,
                             body: String,
                             mono: Bool,
                             accentColor: UIColor? = nil) -> UIView {
        let v = UIStackView()
        v.axis = .vertical
        v.spacing = 6

        let header = UILabel()
        header.text = title.uppercased()
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = accentColor ?? UIColor(white: 0.5, alpha: 1)
        header.setContentCompressionResistancePriority(.required, for: .vertical)
        v.addArrangedSubview(header)

        let text = UILabel()
        text.text = body
        text.numberOfLines = 0
        if mono {
            text.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            text.textColor = UIColor(red: 0.78, green: 0.95, blue: 0.78, alpha: 1)
            text.backgroundColor = UIColor(white: 0.13, alpha: 1)
            text.layer.cornerRadius = 6
            text.layer.masksToBounds = true
            text.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
            text.layer.borderWidth = 1
            // Pad the text inside the label by inserting newlines/spaces is ugly.
            // Use an attributed string + NSTextContainer? Simpler: wrap in a
            // container with insets.
            let pad = UIView()
            pad.backgroundColor = UIColor(white: 0.13, alpha: 1)
            pad.layer.cornerRadius = 6
            pad.layer.masksToBounds = true
            pad.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
            pad.layer.borderWidth = 1
            pad.translatesAutoresizingMaskIntoConstraints = false
            text.backgroundColor = .clear
            text.layer.borderWidth = 0
            text.translatesAutoresizingMaskIntoConstraints = false
            pad.addSubview(text)
            NSLayoutConstraint.activate([
                text.topAnchor.constraint(equalTo: pad.topAnchor, constant: 10),
                text.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 12),
                text.trailingAnchor.constraint(equalTo: pad.trailingAnchor, constant: -12),
                text.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -10),
            ])
            v.addArrangedSubview(pad)
        } else {
            text.font = .systemFont(ofSize: 15, weight: .regular)
            text.textColor = UIColor(white: 0.92, alpha: 1)
            v.addArrangedSubview(text)
        }
        return v
    }

    private func makeButtonsRow() -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 10
        stack.distribution = .fillEqually

        let copyBtn = UIButton(type: .system)
        let modName = pkg.name.replacingOccurrences(of: "-", with: "_").lowercased()
        copyBtn.setTitle("Copy  import \(modName)", for: .normal)
        copyBtn.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        copyBtn.backgroundColor = UIColor(white: 0.18, alpha: 1)
        copyBtn.setTitleColor(UIColor(white: 0.95, alpha: 1), for: .normal)
        copyBtn.layer.cornerRadius = 8
        copyBtn.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        copyBtn.addAction(UIAction { [weak self] _ in
            UIPasteboard.general.string = "import \(modName)"
            // Confirm with brief title flash
            let prev = self?.title
            self?.title = "Copied!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.title = prev
            }
        }, for: .touchUpInside)
        stack.addArrangedSubview(copyBtn)

        let pypiBtn = UIButton(type: .system)
        pypiBtn.setTitle("Open on PyPI", for: .normal)
        pypiBtn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        pypiBtn.backgroundColor = UIColor(white: 0.18, alpha: 1)
        pypiBtn.setTitleColor(.systemBlue, for: .normal)
        pypiBtn.layer.cornerRadius = 8
        pypiBtn.contentEdgeInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let slug = pkg.name
            .replacingOccurrences(of: " ", with: "-")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pkg.name
        pypiBtn.addAction(UIAction { _ in
            if let url = URL(string: "https://pypi.org/project/\(slug)/") {
                UIApplication.shared.open(url)
            }
        }, for: .touchUpInside)
        stack.addArrangedSubview(pypiBtn)
        return stack
    }

    // MARK: - Info table
    //
    // Curated descriptions of bundled packages. Adding a new package:
    // append one entry below keyed by `name.lowercased()` with
    // hyphens→underscores. Anything not in the table falls into the
    // generic "transitive dep" bucket — still gets the import helper
    // and a working PyPI link.

    private static func lookup(_ name: String) -> Info {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "_")
        return PACKAGE_INFO[key] ?? Info(
            summary: "A bundled Python package — either an explicit "
                + "dependency of a larger package (matplotlib, manim, "
                + "transformers, etc.) or a transitive dep needed for "
                + "those to import correctly. Most packages without an "
                + "entry here work the same as their upstream PyPI release.",
            iosNotes: nil,
            example: nil)
    }

    // The actual data. Long, but flat and easy to edit.
    private static let PACKAGE_INFO: [String: Info] = [

        // ─── Machine Learning ──────────────────────────────────────
        "torch": Info(
            summary: "PyTorch 2.1.2 native iOS arm64 build. Provides "
                + "tensors, autograd, nn.Module, torch.optim (SGD, "
                + "AdamW, Adam, RMSprop, …), JIT, FFT, and full "
                + "LAPACK via Apple's Accelerate framework. First "
                + "public native PyTorch on iOS.",
            iosNotes: "• torch.cuda.*, torch.backends.mps, torch."
                + "distributed, torch.multiprocessing — NOT available "
                + "(iOS forbids fork; no CUDA).\n"
                + "• torch.compile — disabled (iOS forbids JIT).\n"
                + "• torch.from_numpy() / tensor.numpy() — auto-"
                + "patched via sitecustomize (USE_NUMPY=0 build).\n"
                + "• DataLoader(num_workers>0) — set to 0 (workers "
                + "use fork).\n"
                + "• GPU acceleration: torch.matmul / mm / bmm / "
                + "addmm / F.linear / F.scaled_dot_product_attention "
                + "are auto-routed to Apple Metal via the bundled "
                + "_torch_metal_bridge (fp32 / fp16 / bf16).",
            example: """
            import torch
            x = torch.randn(64, 128)
            y = x @ x.T        # auto-dispatched to Metal GPU
            print(y.shape)     # torch.Size([64, 64])
            """
        ),
        "transformers": Info(
            summary: "HuggingFace transformers 4.41.2. Load and train "
                + "any HF model: BERT, GPT-2, T5, BART, Llama, Qwen, "
                + "Mistral, Phi, etc. `from_pretrained` reads local "
                + "files or HF Hub URLs. `model.generate()` does full "
                + "autoregressive generation (sampling / beam search). "
                + "Trainer + accelerate + peft are all bundled.",
            iosNotes: "• `Trainer.train()` auto-checkpoints every 100 "
                + "steps (sitecustomize patches save_steps + auto-"
                + "resume).\n"
                + "• `model.save_pretrained()` writes .safetensors via "
                + "our pure-Python writer.\n"
                + "• `datasets.load_dataset(...)` is NOT bundled — "
                + "subclass torch.utils.data.Dataset instead.\n"
                + "• Llama / T5 / BART tokenizers need sentencepiece "
                + "(also not bundled); GPT-2 / Qwen / Mistral / Phi "
                + "use BPE and work without it.\n"
                + "• FlashAttention / DeepSpeed / BitsAndBytes — "
                + "unavailable. SDPA falls back to our GPU-accelerated "
                + "matmul+softmax path.",
            example: """
            from transformers import AutoModelForCausalLM, AutoTokenizer
            tok = AutoTokenizer.from_pretrained("gpt2")
            model = AutoModelForCausalLM.from_pretrained("gpt2")
            ids = tok("hello", return_tensors="pt").input_ids
            print(tok.decode(model.generate(ids, max_new_tokens=10)[0]))
            """
        ),
        "accelerate": Info(
            summary: "HuggingFace Accelerate 0.30.1. Pure Python. "
                + "Required by transformers' Trainer (hard import). "
                + "Handles device placement, gradient accumulation, "
                + "mixed precision.",
            iosNotes: "• Single-device only (no fork → no multi-"
                + "process).\n"
                + "• On iPad, `Accelerator()` picks CPU by default; "
                + "GPU acceleration happens via our Metal bridge at "
                + "the op level (matmul / linear / SDPA), not via "
                + "accelerate's device abstraction.",
            example: """
            from accelerate import Accelerator
            acc = Accelerator()
            model, optimizer = acc.prepare(model, optimizer)
            # ... training loop with acc.backward(loss) ...
            """
        ),
        "peft": Info(
            summary: "HuggingFace PEFT 0.12.0 — Parameter-Efficient "
                + "Fine-Tuning. `LoraConfig` + `get_peft_model` for "
                + "LoRA, IA3, prefix tuning. Pure Python.",
            iosNotes: "• Save adapters via model.save_pretrained() — "
                + "writes adapter_model.safetensors via our shim.\n"
                + "• Convert to GGUF for fast llama.cpp inference: "
                + "`python -m _cb_gguf_export --pt … --gguf …`.",
            example: """
            from peft import LoraConfig, get_peft_model
            cfg = LoraConfig(r=8, lora_alpha=16,
                             target_modules=["q_proj", "v_proj"])
            model = get_peft_model(model, cfg)
            model.print_trainable_parameters()
            """
        ),
        "tokenizers": Info(
            summary: "HuggingFace tokenizers 0.19.1. Real Rust BPE / "
                + "WordPiece / Unigram implementations cross-compiled "
                + "for iOS arm64 via PyO3. First public iOS build.",
            iosNotes: "• Covers GPT-2 / Llama / Mistral / Phi / Qwen / "
                + "BERT / T5 tokenizers via BPE / WordPiece / Unigram "
                + "formats.\n"
                + "• Tokenizer formats that need sentencepiece's C++ "
                + "library (Llama-base, T5-base, BART) won't load "
                + "without sentencepiece bundled.",
            example: """
            from tokenizers import Tokenizer
            tok = Tokenizer.from_pretrained("bert-base-uncased")
            enc = tok.encode("hello world")
            print(enc.tokens)
            """
        ),
        "safetensors": Info(
            summary: "Safe tensor serialization format. Pure-Python "
                + "shim — the real Rust + PyO3 safetensors hasn't "
                + "been cross-compiled for iOS, so we re-implement "
                + "the on-disk format (8-byte LE header length + "
                + "JSON metadata + raw tensor data) over mmap + "
                + "torch.frombuffer.",
            iosNotes: "• Read + write both work. All 6 dtypes (fp32 / "
                + "fp16 / bf16 / int8-64 / uint8 / bool) round-trip "
                + "bit-identical (verified).\n"
                + "• `model.save_pretrained()` uses this transparently "
                + "(safe_serialization=True is HF's default).",
            example: """
            import torch
            import safetensors.torch as st

            st.save_file({"w": torch.randn(64, 128)}, "x.safetensors",
                         metadata={"format": "pt"})
            tensors = st.load_file("x.safetensors")
            """
        ),
        "huggingface_hub": Info(
            summary: "HuggingFace Hub client 0.24.7. Downloads models, "
                + "datasets, spaces from huggingface.co. Used by "
                + "`AutoModel.from_pretrained(\"org/model\")`.",
            iosNotes: "• Network required for from_pretrained over "
                + "HF Hub URLs. Local file paths work offline.",
            example: """
            from huggingface_hub import snapshot_download
            path = snapshot_download(repo_id="gpt2")
            # → ~/.cache/huggingface/hub/models--gpt2/...
            """
        ),
        "sklearn": Info(
            summary: "scikit-learn — 40 pure-NumPy modules: "
                + "classification, regression, clustering, "
                + "preprocessing, metrics, model_selection. No C "
                + "extensions used (pure-Python subset).",
            iosNotes: "• Native cython-compiled extensions (some "
                + "tree-based models, fast SVD) aren't bundled; the "
                + "pure-Python fallback handles most common use cases.",
            example: """
            from sklearn.linear_model import LogisticRegression
            from sklearn.datasets import make_classification
            X, y = make_classification(n_samples=200, n_features=10)
            clf = LogisticRegression().fit(X, y)
            print(clf.score(X, y))
            """
        ),

        // ─── Scientific Computing ──────────────────────────────────
        "numpy": Info(
            summary: "NumPy 2.3.5 — native iOS arm64 build. Full "
                + "ndarray, linear algebra, FFT, random, broadcasting. "
                + "Cross-compiled from upstream NumPy with our build "
                + "scripts (see numpy_ios/).",
            iosNotes: "• Behavior matches upstream NumPy exactly — no "
                + "iOS-specific shims at the API level.\n"
                + "• torch ↔ numpy interop patched via sitecustomize "
                + "(USE_NUMPY=0 PyTorch build).",
            example: """
            import numpy as np
            a = np.arange(12).reshape(3, 4)
            print(a @ a.T)
            print(np.linalg.svd(a.astype(float)))
            """
        ),
        "scipy": Info(
            summary: "SciPy 1.15.0. Optimization, integration, "
                + "interpolation, signal processing, sparse linear "
                + "algebra, statistics. Cross-compiled native iOS + "
                + "Python shim for parts that needed iOS-specific "
                + "patching.",
            iosNotes: "• scipy.special's _ufuncs.so / _gufuncs.so "
                + "depend on libsf_error_state.dylib (bundled in "
                + "App.app/Frameworks/).\n"
                + "• scipy.sparse.linalg's arpack/propack need "
                + "_Fortran* symbols satisfied by "
                + "libfortran_io_stubs.dylib (bundled).",
            example: """
            from scipy.optimize import minimize_scalar
            print(minimize_scalar(lambda x: (x - 3)**2).x)  # ≈ 3.0
            """
        ),
        "sympy": Info(
            summary: "SymPy 1.14 — pure-Python symbolic math: "
                + "calculus, equation solving, linear algebra over "
                + "symbolic expressions, simplification.",
            iosNotes: nil,
            example: """
            from sympy import symbols, integrate, sin
            x = symbols('x')
            print(integrate(sin(x)**2, x))  # x/2 - sin(2*x)/4
            """
        ),
        "mpmath": Info(
            summary: "mpmath 1.4 — arbitrary-precision floating-point "
                + "arithmetic. Pure Python. Backs SymPy's numerical "
                + "evaluations.",
            iosNotes: nil,
            example: """
            from mpmath import mp, mpf, pi
            mp.dps = 50  # 50 decimal digits
            print(pi)
            """
        ),
        "networkx": Info(
            summary: "NetworkX 3.6 — pure-Python graph theory: graph "
                + "construction, algorithms (shortest paths, "
                + "centrality, communities), visualization helpers.",
            iosNotes: nil,
            example: """
            import networkx as nx
            G = nx.karate_club_graph()
            print(nx.shortest_path(G, 0, 33))
            """
        ),

        // ─── Visualization ─────────────────────────────────────────
        "matplotlib": Info(
            summary: "matplotlib 3.9.0 — Python's standard plotting "
                + "library. iOS build uses the Plotly backend "
                + "(matplotlib draws → Plotly renders in WKWebView) "
                + "since there's no native iOS renderer.",
            iosNotes: "• plt.show() opens an HTML preview in CodeBench "
                + "(no GUI window on iOS).\n"
                + "• plt.savefig('plot.png') writes to the workspace "
                + "and works normally.",
            example: """
            import matplotlib.pyplot as plt
            import numpy as np
            x = np.linspace(0, 2*np.pi, 100)
            plt.plot(x, np.sin(x))
            plt.savefig('sine.png')
            """
        ),
        "plotly": Info(
            summary: "Plotly 6.6.0 — interactive web-based charts: "
                + "2D / 3D, geographic, dashboards. Renders via "
                + "WKWebView inside CodeBench's preview pane.",
            iosNotes: nil,
            example: """
            import plotly.graph_objects as go
            fig = go.Figure(go.Scatter(x=[1,2,3], y=[1,4,9]))
            fig.write_html('chart.html')
            """
        ),
        "seaborn": Info(
            summary: "seaborn — statistical plotting on top of "
                + "matplotlib. Higher-level chart types (boxplots, "
                + "violins, regression plots, heatmaps).",
            iosNotes: nil,
            example: """
            import seaborn as sns
            import matplotlib.pyplot as plt
            sns.boxplot(data=[[1,2,3], [2,4,6], [1,3,5]])
            plt.savefig('box.png')
            """
        ),

        // ─── Animation & Math viz ─────────────────────────────────
        "manim": Info(
            summary: "Manim Community 0.19 — programmatic math "
                + "animations. Produces MP4 video via FFmpeg/PyAV "
                + "(bundled). 145+ mobjects, 73 animation types.",
            iosNotes: "• Renders to ~/Documents/manim_outputs/ by "
                + "default.\n"
                + "• MathTex uses our bundled offlinai_latex engine "
                + "for in-frame LaTeX equations.\n"
                + "• Memory-heavy at high quality; CodeBench enforces "
                + "soft cap to prevent iOS OOM kills.",
            example: """
            from manim import Scene, Circle, Create
            class Demo(Scene):
                def construct(self):
                    self.play(Create(Circle()))
            # Run via: manim -ql script.py Demo
            """
        ),
        "manimpango": Info(
            summary: "Pango text-shaping shim for Manim. The real "
                + "manimpango is a C extension binding to Pango; our "
                + "iOS build uses a Python shim that delegates to the "
                + "bundled Pango (in Cairo dylibs).",
            iosNotes: nil,
            example: nil
        ),

        // ─── Media ────────────────────────────────────────────────
        "pil": Info(
            summary: "Pillow (imports as PIL) — image processing: "
                + "open / save / convert / resize / filter / draw / "
                + "color spaces / EXIF / many file formats. Native "
                + "iOS arm64 build.",
            iosNotes: "• JPEG / PNG / WebP / TIFF / GIF / BMP all "
                + "work via bundled libjpeg-turbo, zlib, etc.\n"
                + "• Pillow.ImageTk is unavailable (no Tk on iOS).",
            example: """
            from PIL import Image, ImageFilter
            img = Image.open('photo.jpg')
            img.thumbnail((512, 512))
            img.filter(ImageFilter.GaussianBlur(2)).save('blur.png')
            """
        ),
        "av": Info(
            summary: "PyAV — Python bindings to FFmpeg. Read / write "
                + "video and audio files, transcode between codecs, "
                + "extract frames. Bundles 7 native FFmpeg dylibs "
                + "(libav*, libsw*).",
            iosNotes: "• Hardware H.264 encoding via VideoToolbox is "
                + "available (`vcodec='h264_videotoolbox'`).\n"
                + "• install_name_tool rewrites of /tmp/ffmpeg-ios "
                + "paths happen at app build time.",
            example: """
            import av
            with av.open('out.mp4', mode='w') as out, \\
                 av.open('in.mp4') as src:
                for frame in src.decode(video=0):
                    out.mux(out.streams.video[0].encode(frame))
            """
        ),
        "cairo": Info(
            summary: "Cairo + Pango + HarfBuzz + FreeType + GLib + "
                + "libffi (all native iOS arm64). 2D vector graphics + "
                + "text shaping. Backs matplotlib SVG output, manim, "
                + "and many others.",
            iosNotes: nil,
            example: """
            import cairo
            surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, 200, 200)
            ctx = cairo.Context(surf)
            ctx.arc(100, 100, 80, 0, 6.28)
            ctx.fill()
            surf.write_to_png('circle.png')
            """
        ),
        "pydub": Info(
            summary: "Audio manipulation: cut, concat, fade, "
                + "normalize. Reads / writes WAV / MP3 / OGG via "
                + "FFmpeg (bundled).",
            iosNotes: nil,
            example: """
            from pydub import AudioSegment
            seg = AudioSegment.from_file('in.wav')
            seg[:5000].export('first5s.wav', format='wav')
            """
        ),
        "audioop": Info(
            summary: "LTS-backported `audioop` module — raw audio "
                + "primitives (RMS, biquad, μ-law / A-law). Removed "
                + "from CPython's stdlib in 3.13; we ship the "
                + "pre-removal source so packages depending on it "
                + "(pydub etc.) keep working.",
            iosNotes: nil,
            example: nil
        ),
        "pypdf": Info(
            summary: "Read PDF files: extract text, page metadata, "
                + "split / merge pages. Pure Python.",
            iosNotes: nil,
            example: """
            from pypdf import PdfReader
            reader = PdfReader('doc.pdf')
            for p in reader.pages:
                print(p.extract_text()[:200])
            """
        ),
        "fpdf": Info(
            summary: "fpdf2 — generate PDFs from Python. Vector text, "
                + "images, tables. Pure Python.",
            iosNotes: nil,
            example: """
            from fpdf import FPDF
            pdf = FPDF(); pdf.add_page(); pdf.set_font('helvetica', size=12)
            pdf.cell(0, 10, 'hello iPad')
            pdf.output('hello.pdf')
            """
        ),
        "reportlab": Info(
            summary: "ReportLab — full PDF generation toolkit: "
                + "vector graphics, text layout, tables, charts.",
            iosNotes: nil,
            example: nil
        ),
        "openpyxl": Info(
            summary: "Read / write Excel `.xlsx` files. Pure Python.",
            iosNotes: nil,
            example: """
            from openpyxl import Workbook
            wb = Workbook(); ws = wb.active
            ws.append(["a", "b", "c"]); ws.append([1, 2, 3])
            wb.save("out.xlsx")
            """
        ),
        "xlsxwriter": Info(
            summary: "Write Excel `.xlsx` files (no read support — "
                + "use openpyxl for that). Supports formulas, charts, "
                + "conditional formatting.",
            iosNotes: nil,
            example: nil
        ),

        // ─── LaTeX ────────────────────────────────────────────────
        "offlinai_latex": Info(
            summary: "Math-mode LaTeX rendering via SwiftMath. Backs "
                + "manim's MathTex and CodeBench's `pdflatex` builtin "
                + "(for math expressions, not full documents).",
            iosNotes: "• Math-mode rendering: unlimited and reliable.\n"
                + "• Full `\\documentclass{article}` builds: use the "
                + "busytex WASM engine (CodeBench's `pdflatex` shell "
                + "command routes there).",
            example: nil
        ),

        // ─── Web & Network ────────────────────────────────────────
        "requests": Info(
            summary: "requests 2.33.1 — HTTP client. GET / POST / "
                + "PUT / DELETE / sessions / JSON / file uploads / "
                + "cookies / auth.",
            iosNotes: "• TLS works via bundled certifi CA bundle.\n"
                + "• Connection lifetime tied to the Python process — "
                + "iOS may suspend the app; long-poll patterns are "
                + "fragile.",
            example: """
            import requests
            r = requests.get('https://httpbin.org/get', timeout=10)
            print(r.json())
            """
        ),
        "urllib3": Info(
            summary: "urllib3 2.6 — low-level HTTP transport. Used by "
                + "`requests` under the hood; rarely imported directly.",
            iosNotes: nil,
            example: nil
        ),
        "httpx": Info(
            summary: "httpx — async + sync HTTP client. Drop-in "
                + "alternative to requests with HTTP/2 support and "
                + "true async via httpcore.",
            iosNotes: nil,
            example: """
            import httpx
            r = httpx.get('https://httpbin.org/get', timeout=10)
            print(r.status_code, r.json())
            """
        ),
        "bs4": Info(
            summary: "BeautifulSoup4 — HTML / XML parser. Tag "
                + "navigation, CSS selectors, find / find_all.",
            iosNotes: nil,
            example: """
            from bs4 import BeautifulSoup
            soup = BeautifulSoup('<a href="x">hi</a>', 'html.parser')
            print(soup.a.get('href'), soup.a.text)
            """
        ),
        "webview": Info(
            summary: "pywebview shim — render HTML/CSS/JS UIs from "
                + "Python inside the CodeBench preview pane. Real "
                + "pywebview targets desktop OSs; our shim adapts the "
                + "API to a WKWebView.",
            iosNotes: "• window.create_window() opens in the preview "
                + "pane, not a separate OS window.\n"
                + "• File dialogs: limited to iOS document picker "
                + "scope.",
            example: """
            import webview
            webview.create_window('demo', html='<h1>hello iPad</h1>')
            webview.start()
            """
        ),

        // ─── Data Formats ─────────────────────────────────────────
        "yaml": Info(
            summary: "PyYAML — read / write YAML files. Native iOS "
                + "build with the libyaml C parser.",
            iosNotes: nil,
            example: """
            import yaml
            data = yaml.safe_load("name: ipad\\nversion: 18.5")
            print(data)
            """
        ),
        "jsonschema": Info(
            summary: "JSON Schema validation. `validate()` raises on "
                + "violations; `Draft202012Validator(...).iter_errors` "
                + "yields all issues.",
            iosNotes: nil,
            example: """
            from jsonschema import validate
            validate({"x": 1}, {"type": "object",
                                "properties": {"x": {"type": "integer"}}})
            """
        ),
        "fsspec": Info(
            summary: "Filesystem abstraction layer. Backs HF "
                + "transformers / huggingface_hub for local + remote "
                + "I/O.",
            iosNotes: nil,
            example: nil
        ),

        // ─── CLI / Terminal UI ────────────────────────────────────
        "rich": Info(
            summary: "Rich text and progress bars in the terminal. "
                + "Tables, syntax-highlighted code, ANSI color, "
                + "spinners, layout grids.",
            iosNotes: "• Auto-detects CodeBench's SwiftTerm and "
                + "renders ANSI properly.",
            example: """
            from rich.console import Console
            from rich.table import Table
            t = Table(title="Results")
            t.add_column("Step"); t.add_column("Loss")
            t.add_row("1", "2.31"); t.add_row("2", "1.42")
            Console().print(t)
            """
        ),
        "click": Info(
            summary: "click 8.1.7 — Python CLI framework: argument "
                + "parsing, prompts, subcommands, colored help.",
            iosNotes: nil,
            example: """
            import click
            @click.command()
            @click.option('--name', default='ipad')
            def hi(name): click.echo(f'hello {name}')
            hi(['--name', 'world'], standalone_mode=False)
            """
        ),
        "typer": Info(
            summary: "Modern CLI framework on top of click + Pydantic-"
                + "style type hints. `typer.run(fn)` is the quick path.",
            iosNotes: nil,
            example: nil
        ),
        "textual": Info(
            summary: "TUI framework for full-screen terminal apps. "
                + "Built on Rich. Reactive components, CSS-style "
                + "stylesheets, mouse support.",
            iosNotes: nil,
            example: nil
        ),
        "tqdm": Info(
            summary: "Progress bars for loops. `for x in tqdm(iter): "
                + "...` shows live progress in CodeBench's terminal.",
            iosNotes: nil,
            example: """
            from tqdm import tqdm
            import time
            for i in tqdm(range(50)):
                time.sleep(0.02)
            """
        ),
        "pygments": Info(
            summary: "Syntax highlighting for 500+ languages. Used by "
                + "Rich / docstring renderers / Sphinx-style output.",
            iosNotes: nil,
            example: nil
        ),

        // ─── Templating / Utility ─────────────────────────────────
        "jinja2": Info(
            summary: "Templating engine: variables, conditionals, "
                + "loops, inheritance, autoescape. Used by HF "
                + "transformers chat templates.",
            iosNotes: nil,
            example: """
            from jinja2 import Template
            print(Template('Hi {{name}}').render(name='iPad'))
            """
        ),
        "markupsafe": Info(
            summary: "Safe HTML escaping primitive used by Jinja2 + "
                + "Flask. Tiny utility package.",
            iosNotes: nil,
            example: nil
        ),
        "regex": Info(
            summary: "Drop-in replacement for stdlib `re` with extra "
                + "features: lookbehind, named groups, Unicode "
                + "categories. HuggingFace tokenizers use it.",
            iosNotes: nil,
            example: nil
        ),
        "packaging": Info(
            summary: "PyPA's version + requirement parser. Backs "
                + "`pip` and `importlib.metadata`.",
            iosNotes: nil,
            example: nil
        ),
        "filelock": Info(
            summary: "Cross-process file locking. Used by "
                + "huggingface_hub to coordinate concurrent model "
                + "downloads.",
            iosNotes: nil,
            example: nil
        ),
        "dateutil": Info(
            summary: "Better date / time parsing than stdlib "
                + "`datetime`. `dateutil.parser.parse(any_string)` "
                + "handles dozens of formats.",
            iosNotes: nil,
            example: """
            from dateutil import parser
            print(parser.parse("May 15, 2026 at 4:30pm"))
            """
        ),
        "psutil": Info(
            summary: "System / process monitoring: CPU %, RAM use, "
                + "open files, connections, battery. iOS-specific "
                + "shim implements `_psutil_osx` in pure Python (real "
                + "C extension isn't cross-compiled).",
            iosNotes: "• Reports real RSS via task_info().\n"
                + "• Battery info via UIDevice.\n"
                + "• Some POSIX-y bits (kqueue / process scanning) "
                + "return empty or estimated values inside iOS "
                + "sandbox.",
            example: """
            import psutil
            print(f'CPU: {psutil.cpu_percent()}%')
            print(f'RAM: {psutil.virtual_memory().percent}%')
            """
        ),

        // ─── Testing / Dev ────────────────────────────────────────
        "pytest": Info(
            summary: "Test framework: collect + run tests, fixtures, "
                + "parametrize, plugins. Works as-is in CodeBench's "
                + "shell.",
            iosNotes: nil,
            example: """
            # save as test_x.py, then run: pytest test_x.py
            def test_basic(): assert 1 + 1 == 2
            """
        ),
        "hypothesis": Info(
            summary: "Property-based testing — generates random "
                + "inputs to expose edge cases. Integrates with pytest.",
            iosNotes: nil,
            example: nil
        ),
        "black": Info(
            summary: "Uncompromising Python code formatter. `black "
                + "file.py` rewrites in place.",
            iosNotes: nil,
            example: nil
        ),
        "isort": Info(
            summary: "Sort and group Python imports. Often run "
                + "alongside black.",
            iosNotes: nil,
            example: nil
        ),
        "mypy": Info(
            summary: "Static type checker for Python.",
            iosNotes: nil,
            example: nil
        ),
        "pyflakes": Info(
            summary: "Fast Python static analyser — catches unused "
                + "imports, undefined names. No style opinions "
                + "(unlike flake8).",
            iosNotes: nil,
            example: nil
        ),

        // ─── Package Management ───────────────────────────────────
        "pip": Info(
            summary: "Python's package installer 26.0.1. Patched in "
                + "CodeBench to: skip native-build sdist fallbacks, "
                + "retry with --no-deps when bundled-deps conflict, "
                + "recursively install missing runtime deps, and "
                + "inject the right `--target` for the per-workspace "
                + "site-packages.",
            iosNotes: "• Installs go to ~/Documents/site-packages "
                + "(visible in the Pip-installed section above).\n"
                + "• Pure-Python packages install fine; anything with "
                + "C / Rust extensions usually fails (no cross-"
                + "compile toolchain on-device).",
            example: """
            # In the CodeBench shell:
            pip install evaluate
            """
        ),
        "wheel": Info(
            summary: "Wheel-format builder. Pip uses it under the "
                + "hood; rarely imported directly.",
            iosNotes: nil,
            example: nil
        ),
        "setuptools": Info(
            summary: "Package build + metadata tools. Backs "
                + "`setup.py` / `pyproject.toml` parsing.",
            iosNotes: nil,
            example: nil
        ),

        // ─── CodeBench helpers ────────────────────────────────────
        "_torch_metal_bridge": Info(
            summary: "PyTorch → Apple Metal GPU dispatch. Patches "
                + "torch.matmul / mm / bmm / addmm / F.linear / "
                + "F.scaled_dot_product_attention to route through "
                + "the Swift @_cdecl bridge in MetalMatmulBridge.swift. "
                + "Auto-installed at every Python startup via "
                + "sitecustomize.",
            iosNotes: "• fp32 + fp16 native via "
                + "MPSMatrixMultiplication; bf16 casts to fp32 "
                + "internally.\n"
                + "• 2-D matmul + N-D batched + N-D × 2-D mixed-rank "
                + "all handled.\n"
                + "• Disable via env var "
                + "CODEBENCH_GPU_MATMUL_MIN_FLOPS=999999999.",
            example: """
            import _torch_metal_bridge as b
            print('available:', b.is_available())
            print('stats:', b.stats())
            """
        ),
        "_cb_training": Info(
            summary: "Opt-in training utilities for hand-rolled "
                + "training loops (HF Trainer users don't need "
                + "these — its built-in checkpointing is auto-"
                + "configured via sitecustomize).",
            iosNotes: "Five classes — OOMGuard (auto-halve batch on "
                + "OOM), MemoryProfiler (RSS snapshots), KVCache "
                + "(autoregressive inference cache), TrainingMonitor "
                + "(terminal loss/it-s/ETA/RAM dashboard), "
                + "AutoCheckpointer (periodic save + resume).",
            example: """
            from _cb_training import TrainingMonitor
            mon = TrainingMonitor(total_steps=1000, log_every=10)
            for step in range(1000):
                # loss = train_step(batch)
                mon.update(step, loss=...); mon.maybe_print(step)
            """
        ),
        "_cb_background": Info(
            summary: "iOS background-time extension. Auto-enabled at "
                + "every Python startup. When the user backgrounds "
                + "CodeBench mid-training, iOS grants extra time "
                + "(via UIApplication.beginBackgroundTask) instead "
                + "of suspending immediately.",
            iosNotes: "• time_remaining() returns +inf while in "
                + "foreground.\n"
                + "• Disable with CODEBENCH_AUTO_BACKGROUND=0.\n"
                + "• Implemented in Swift "
                + "(BackgroundTimeManager.swift); the Python wrapper "
                + "is a thin ctypes binding.",
            example: """
            import _cb_background as bg
            print('available:', bg.is_available())
            print('time_remaining:', bg.time_remaining())
            """
        ),
        "_cb_gguf_export": Info(
            summary: "Convert PyTorch LoRA `.pt` adapters to GGUF "
                + "format for llama.cpp inference. Closes the train-"
                + "then-deploy loop: train via HF Trainer + PEFT, "
                + "export with this, load via "
                + "LlamaRunner.applyLoraAdapter().",
            iosNotes: "• Supports Qwen / Llama / Mistral / Phi-family "
                + "module names (attn_q/k/v/output, "
                + "ffn_gate/up/down). Extend _MODULE_MAP for other "
                + "architectures.\n"
                + "• Pure-Python GGUF v3 writer — no external deps.",
            example: """
            # After training a LoRA via HF Trainer + PEFT, in the shell:
            python -m _cb_gguf_export \\
                --pt ~/Documents/run/adapter_model.safetensors \\
                --gguf ~/Documents/lora.gguf \\
                --arch qwen2 --alpha 16
            """
        ),
        "offlinai_ai": Info(
            summary: "CodeBench RAG + embedding utilities. Vector "
                + "store over user-imported text / PDF / markdown.",
            iosNotes: nil,
            example: nil
        ),
    ]
}
