import UIKit

/// Packages tab — curated list of pure-Python libraries the user can
/// install on-device at runtime via pip, plus a free-form text field
/// for any other pip-installable pure-Python package.
///
/// Installs go to `Documents/site-packages/` (writable), which
/// PythonRuntime adds to sys.path alongside the bundled app_packages.
final class PackageManagerViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate, UITextFieldDelegate {

    // MARK: - Curated list
    struct CuratedPackage {
        let name: String       // pip name, e.g. "rich"
        let importAs: String?  // optional alt import name if different from pip
        let summary: String    // one-liner
        let pipSpec: String    // exact spec for pip, e.g. "rich==13.9.4"
        var displayName: String { name }
    }

    // Pure-Python (no C extensions) packages known to work on iOS.
    private let curated: [CuratedPackage] = [
        CuratedPackage(name: "rich", importAs: nil,
                       summary: "Rich text & beautiful formatting in the terminal",
                       pipSpec: "rich"),
        CuratedPackage(name: "colorama", importAs: nil,
                       summary: "Cross-platform colored terminal text",
                       pipSpec: "colorama"),
        CuratedPackage(name: "click", importAs: nil,
                       summary: "Composable command-line interface toolkit",
                       pipSpec: "click"),
        CuratedPackage(name: "typer", importAs: nil,
                       summary: "Easy CLI apps based on Python type hints",
                       pipSpec: "typer"),
        CuratedPackage(name: "tqdm", importAs: nil,
                       summary: "Fast, extensible progress bar",
                       pipSpec: "tqdm"),
        CuratedPackage(name: "requests", importAs: nil,
                       summary: "HTTP library (urllib wrapper, JSON helpers)",
                       pipSpec: "requests"),
        CuratedPackage(name: "httpx", importAs: nil,
                       summary: "Next-generation HTTP client w/ async support",
                       pipSpec: "httpx"),
        CuratedPackage(name: "pydantic", importAs: nil,
                       summary: "Data validation with Python type hints (pure-py mode)",
                       pipSpec: "pydantic --no-binary :all:"),
        CuratedPackage(name: "pyyaml", importAs: "yaml",
                       summary: "YAML parser & emitter",
                       pipSpec: "pyyaml --no-binary :all:"),
        CuratedPackage(name: "toml", importAs: nil,
                       summary: "TOML file parser & writer",
                       pipSpec: "toml"),
        CuratedPackage(name: "tomli", importAs: nil,
                       summary: "A lil' TOML parser (Python 3)",
                       pipSpec: "tomli"),
        CuratedPackage(name: "Jinja2", importAs: "jinja2",
                       summary: "Fast, full-featured template engine",
                       pipSpec: "Jinja2"),
        CuratedPackage(name: "markdown-it-py", importAs: "markdown_it",
                       summary: "CommonMark-compliant Markdown parser",
                       pipSpec: "markdown-it-py"),
        CuratedPackage(name: "mistune", importAs: nil,
                       summary: "Fast yet powerful Markdown parser",
                       pipSpec: "mistune"),
        CuratedPackage(name: "beautifulsoup4", importAs: "bs4",
                       summary: "HTML/XML parser with a Pythonic API",
                       pipSpec: "beautifulsoup4"),
        CuratedPackage(name: "defusedxml", importAs: nil,
                       summary: "Safer XML parsing (drop-in for lxml many cases)",
                       pipSpec: "defusedxml"),
        CuratedPackage(name: "networkx", importAs: nil,
                       summary: "Network analysis in Python",
                       pipSpec: "networkx"),
        CuratedPackage(name: "pytz", importAs: nil,
                       summary: "World timezone definitions for Python",
                       pipSpec: "pytz"),
        CuratedPackage(name: "python-dateutil", importAs: "dateutil",
                       summary: "Powerful date/time extensions",
                       pipSpec: "python-dateutil"),
        CuratedPackage(name: "dataclasses-json", importAs: "dataclasses_json",
                       summary: "Easily serialize dataclasses to & from JSON",
                       pipSpec: "dataclasses-json"),
        CuratedPackage(name: "attrs", importAs: "attr",
                       summary: "Classes without boilerplate",
                       pipSpec: "attrs"),
        CuratedPackage(name: "more-itertools", importAs: "more_itertools",
                       summary: "More routines for operating on iterables",
                       pipSpec: "more-itertools"),
        CuratedPackage(name: "joblib", importAs: nil,
                       summary: "Lightweight pipelining & caching for Python",
                       pipSpec: "joblib"),
        CuratedPackage(name: "regex", importAs: nil,
                       summary: "Alternative regex module w/ Unicode support",
                       pipSpec: "regex --no-binary :all:"),
        CuratedPackage(name: "chardet", importAs: nil,
                       summary: "Universal character-encoding detector",
                       pipSpec: "chardet"),
        CuratedPackage(name: "charset-normalizer", importAs: "charset_normalizer",
                       summary: "Read any charset into a Python unicode string",
                       pipSpec: "charset-normalizer"),
        CuratedPackage(name: "idna", importAs: nil,
                       summary: "Internationalized domain names (RFC 5891)",
                       pipSpec: "idna"),
        CuratedPackage(name: "urllib3", importAs: nil,
                       summary: "HTTP client with connection pooling, file uploads",
                       pipSpec: "urllib3"),
        CuratedPackage(name: "certifi", importAs: nil,
                       summary: "Mozilla's CA Bundle for Python",
                       pipSpec: "certifi"),
        CuratedPackage(name: "packaging", importAs: nil,
                       summary: "Core utilities for Python packages (pep440 etc)",
                       pipSpec: "packaging"),
        CuratedPackage(name: "six", importAs: nil,
                       summary: "Python 2/3 compat library (used by many libs)",
                       pipSpec: "six"),
        CuratedPackage(name: "tabulate", importAs: nil,
                       summary: "Pretty-print tabular data in ASCII/HTML/etc.",
                       pipSpec: "tabulate"),
        CuratedPackage(name: "prettytable", importAs: nil,
                       summary: "ASCII table rendering",
                       pipSpec: "prettytable"),
    ]

    private var filtered: [CuratedPackage] = []

    // MARK: - UI
    private let scroll = UIScrollView()
    private let contentStack = UIStackView()

    // Header
    private let headerLabel = UILabel()
    private let subtitleLabel = UILabel()

    // Custom install (text field + button)
    private let customField = UITextField()
    private let customInstallButton = UIButton(type: .system)

    // Search
    private let searchBar = UISearchBar()

    // Table
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var tableHeightConstraint: NSLayoutConstraint?

    // Terminal
    private let termCard = UIView()
    private let termStatusLabel = PaddingLabel()  // top bar: "Idle" / "Downloading" / "Installing" / …
    private let termDotView = UIView()            // colored dot next to status
    private let termProgressBar = UIProgressView(progressViewStyle: .bar)
    private let termSpinner = UIActivityIndicatorView(style: .medium)
    private let termClearBtn = UIButton(type: .system)
    private let termCopyBtn = UIButton(type: .system)
    private let termOutputView = UITextView()
    private let termOutputHeight: CGFloat = 300

    // State
    private var isInstalling = false
    private var currentStage: Stage = .idle

    enum Stage {
        case idle, resolving, downloading, installing, verifying, success, failure
        var title: String {
            switch self {
            case .idle:        return "Idle"
            case .resolving:   return "Resolving"
            case .downloading: return "Downloading"
            case .installing:  return "Installing"
            case .verifying:   return "Verifying"
            case .success:     return "Installed"
            case .failure:     return "Failed"
            }
        }
        var color: UIColor {
            switch self {
            case .idle:        return UIColor(white: 0.45, alpha: 1)
            case .resolving:   return UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1)
            case .downloading: return UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1)
            case .installing:  return UIColor(red: 1.0, green: 0.75, blue: 0.2, alpha: 1)
            case .verifying:   return UIColor(red: 0.85, green: 0.55, blue: 1.0, alpha: 1)
            case .success:     return UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1)
            case .failure:     return UIColor(red: 1.0, green: 0.38, blue: 0.38, alpha: 1)
            }
        }
    }

    /// Fired after every install attempt finishes (success or failure). Used by
    /// the combined Libraries tab to refresh its "Installed" list.
    var onDidFinishInstall: (() -> Void)?

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.075, green: 0.078, blue: 0.090, alpha: 1.0)
        filtered = curated
        buildUI()
        resetTerminal(initial: true)
    }

    // MARK: - UI construction
    private func buildUI() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .onDrag
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            contentStack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
        ])

        // Header
        headerLabel.text = "Python Packages"
        headerLabel.font = .systemFont(ofSize: 22, weight: .bold)
        headerLabel.textColor = UIColor(white: 0.95, alpha: 1)
        contentStack.addArrangedSubview(headerLabel)

        subtitleLabel.text = "Install pure-Python libraries on device. Installs go to Documents/site-packages/ and are added to sys.path automatically — `import <pkg>` starts working immediately."
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 0.65, alpha: 1)
        subtitleLabel.numberOfLines = 0
        contentStack.addArrangedSubview(subtitleLabel)

        // Custom install row
        contentStack.addArrangedSubview(buildCustomInstallRow())

        // Divider
        contentStack.addArrangedSubview(makeDivider())

        // Section header
        let curatedHeader = UILabel()
        curatedHeader.text = "CURATED — TAP TO INSTALL"
        curatedHeader.font = .systemFont(ofSize: 11, weight: .bold)
        curatedHeader.textColor = UIColor(white: 0.55, alpha: 1)
        contentStack.addArrangedSubview(curatedHeader)

        // Search
        searchBar.placeholder = "Filter curated packages"
        searchBar.delegate = self
        searchBar.searchBarStyle = .minimal
        searchBar.backgroundColor = .clear
        searchBar.tintColor = .systemBlue
        if let field = searchBar.value(forKey: "searchField") as? UITextField {
            field.textColor = UIColor(white: 0.95, alpha: 1)
            field.backgroundColor = UIColor(white: 0.15, alpha: 1)
            field.attributedPlaceholder = NSAttributedString(
                string: "Filter curated packages",
                attributes: [.foregroundColor: UIColor(white: 0.55, alpha: 1)])
        }
        contentStack.addArrangedSubview(searchBar)

        // Table of curated packages
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(PackageCell.self, forCellReuseIdentifier: "pkg")
        tableView.isScrollEnabled = false  // scrolled by outer scroll view
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        contentStack.addArrangedSubview(tableView)
        tableHeightConstraint = tableView.heightAnchor.constraint(equalToConstant: 80)
        tableHeightConstraint?.isActive = true

        // Divider
        contentStack.addArrangedSubview(makeDivider())

        // Terminal card
        contentStack.addArrangedSubview(buildTerminalCard())

        DispatchQueue.main.async { [weak self] in self?.updateTableHeight() }
    }

    // MARK: - Terminal card

    private func buildTerminalCard() -> UIView {
        termCard.translatesAutoresizingMaskIntoConstraints = false
        termCard.backgroundColor = UIColor(red: 0.040, green: 0.044, blue: 0.056, alpha: 1.0)
        termCard.layer.cornerRadius = 10
        termCard.layer.borderWidth = 0.5
        termCard.layer.borderColor = UIColor(white: 0.20, alpha: 1).cgColor
        termCard.clipsToBounds = true

        // Title bar
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = UIColor(white: 0.10, alpha: 1)
        termCard.addSubview(bar)

        // Mac-style traffic lights (purely cosmetic)
        let dots = UIStackView()
        dots.axis = .horizontal
        dots.spacing = 6
        dots.translatesAutoresizingMaskIntoConstraints = false
        for color in [UIColor(red: 1.0, green: 0.38, blue: 0.38, alpha: 1),
                      UIColor(red: 1.0, green: 0.75, blue: 0.20, alpha: 1),
                      UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1)] {
            let d = UIView()
            d.translatesAutoresizingMaskIntoConstraints = false
            d.backgroundColor = color
            d.layer.cornerRadius = 5
            d.widthAnchor.constraint(equalToConstant: 10).isActive = true
            d.heightAnchor.constraint(equalToConstant: 10).isActive = true
            dots.addArrangedSubview(d)
        }
        bar.addSubview(dots)

        // Status line: colored dot + status + spinner
        termDotView.translatesAutoresizingMaskIntoConstraints = false
        termDotView.backgroundColor = Stage.idle.color
        termDotView.layer.cornerRadius = 4
        bar.addSubview(termDotView)

        termStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        termStatusLabel.text = "● pip — idle"
        termStatusLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        termStatusLabel.textColor = UIColor(white: 0.75, alpha: 1)
        bar.addSubview(termStatusLabel)

        termSpinner.translatesAutoresizingMaskIntoConstraints = false
        termSpinner.color = UIColor(white: 0.7, alpha: 1)
        termSpinner.hidesWhenStopped = true
        bar.addSubview(termSpinner)

        // Copy + Clear buttons
        var clearCfg = UIButton.Configuration.plain()
        clearCfg.image = UIImage(systemName: "trash")
        clearCfg.baseForegroundColor = UIColor(white: 0.55, alpha: 1)
        termClearBtn.configuration = clearCfg
        termClearBtn.addTarget(self, action: #selector(clearTerminal), for: .touchUpInside)
        termClearBtn.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(termClearBtn)

        var copyCfg = UIButton.Configuration.plain()
        copyCfg.image = UIImage(systemName: "doc.on.clipboard")
        copyCfg.baseForegroundColor = UIColor(white: 0.55, alpha: 1)
        termCopyBtn.configuration = copyCfg
        termCopyBtn.addTarget(self, action: #selector(copyTerminal), for: .touchUpInside)
        termCopyBtn.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(termCopyBtn)

        // Progress bar
        termProgressBar.translatesAutoresizingMaskIntoConstraints = false
        termProgressBar.progressTintColor = UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1)
        termProgressBar.trackTintColor = UIColor(white: 0.16, alpha: 1)
        termProgressBar.progress = 0
        termProgressBar.isHidden = true
        termCard.addSubview(termProgressBar)

        // Output view
        termOutputView.translatesAutoresizingMaskIntoConstraints = false
        termOutputView.backgroundColor = UIColor(red: 0.020, green: 0.024, blue: 0.032, alpha: 1.0)
        termOutputView.textColor = UIColor(white: 0.92, alpha: 1)
        termOutputView.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        termOutputView.isEditable = false
        termOutputView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        termOutputView.dataDetectorTypes = []
        termOutputView.alwaysBounceVertical = true
        termCard.addSubview(termOutputView)

        NSLayoutConstraint.activate([
            // bar
            bar.topAnchor.constraint(equalTo: termCard.topAnchor),
            bar.leadingAnchor.constraint(equalTo: termCard.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: termCard.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),

            dots.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            dots.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            termDotView.leadingAnchor.constraint(equalTo: dots.trailingAnchor, constant: 14),
            termDotView.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            termDotView.widthAnchor.constraint(equalToConstant: 8),
            termDotView.heightAnchor.constraint(equalToConstant: 8),

            termStatusLabel.leadingAnchor.constraint(equalTo: termDotView.trailingAnchor, constant: 6),
            termStatusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            termSpinner.leadingAnchor.constraint(equalTo: termStatusLabel.trailingAnchor, constant: 6),
            termSpinner.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            termCopyBtn.trailingAnchor.constraint(equalTo: termClearBtn.leadingAnchor),
            termCopyBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            termCopyBtn.widthAnchor.constraint(equalToConstant: 38),
            termCopyBtn.heightAnchor.constraint(equalToConstant: 32),

            termClearBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -4),
            termClearBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            termClearBtn.widthAnchor.constraint(equalToConstant: 38),
            termClearBtn.heightAnchor.constraint(equalToConstant: 32),

            // progress
            termProgressBar.topAnchor.constraint(equalTo: bar.bottomAnchor),
            termProgressBar.leadingAnchor.constraint(equalTo: termCard.leadingAnchor),
            termProgressBar.trailingAnchor.constraint(equalTo: termCard.trailingAnchor),
            termProgressBar.heightAnchor.constraint(equalToConstant: 2),

            // output
            termOutputView.topAnchor.constraint(equalTo: termProgressBar.bottomAnchor),
            termOutputView.leadingAnchor.constraint(equalTo: termCard.leadingAnchor),
            termOutputView.trailingAnchor.constraint(equalTo: termCard.trailingAnchor),
            termOutputView.bottomAnchor.constraint(equalTo: termCard.bottomAnchor),
            termOutputView.heightAnchor.constraint(equalToConstant: termOutputHeight),
        ])

        return termCard
    }

    @objc private func clearTerminal() {
        termOutputView.text = ""
        resetTerminal(initial: true)
    }

    @objc private func copyTerminal() {
        UIPasteboard.general.string = termOutputView.text
        flashStatus("✓ Copied", tint: Stage.success.color)
    }

    private func flashStatus(_ text: String, tint: UIColor) {
        let prev = termStatusLabel.text
        let prevColor = termStatusLabel.textColor
        termStatusLabel.text = text
        termStatusLabel.textColor = tint
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.termStatusLabel.text = prev
            self?.termStatusLabel.textColor = prevColor
        }
    }

    private func resetTerminal(initial: Bool) {
        currentStage = .idle
        termDotView.backgroundColor = Stage.idle.color
        termStatusLabel.text = "● pip — idle"
        termStatusLabel.textColor = UIColor(white: 0.75, alpha: 1)
        termSpinner.stopAnimating()
        termProgressBar.isHidden = true
        termProgressBar.progress = 0
        if initial {
            // Boot banner
            let banner = """
            ┌─ CodeBench package manager ────────────────────────────
            │ Python 3.14 · iOS arm64
            │ User site-packages: ~/Documents/site-packages
            │ Bundled:           <app>/app_packages/site-packages
            └────────────────────────────────────────────────────────

            Tap a package above, or type one in the PIP INSTALL
            field and hit Install. Progress + logs appear here.

            """
            termOutputView.text = banner
        }
    }

    private func setStage(_ stage: Stage) {
        currentStage = stage
        termDotView.backgroundColor = stage.color
        termStatusLabel.text = "● pip — \(stage.title.lowercased())"
        termStatusLabel.textColor = stage.color
        switch stage {
        case .idle, .success, .failure:
            termSpinner.stopAnimating()
        default:
            termSpinner.startAnimating()
        }
        // Progress visibility
        switch stage {
        case .downloading:
            termProgressBar.isHidden = false
            termProgressBar.progressTintColor = UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1)
        case .installing:
            termProgressBar.isHidden = false
            termProgressBar.progressTintColor = UIColor(red: 1.0, green: 0.75, blue: 0.20, alpha: 1)
        case .success:
            termProgressBar.isHidden = false
            termProgressBar.progress = 1.0
            termProgressBar.progressTintColor = Stage.success.color
            // Fade out progress after a moment
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.currentStage == .success { self?.termProgressBar.isHidden = true }
            }
        case .failure:
            termProgressBar.progressTintColor = Stage.failure.color
        default:
            break
        }
    }

    // MARK: - Custom install row

    private func buildCustomInstallRow() -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(white: 0.13, alpha: 1)
        container.layer.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "PIP INSTALL ANY PACKAGE"
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = UIColor(white: 0.6, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false

        customField.placeholder = "e.g. rich  •  pandas==2.0  •  git+https://..."
        customField.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        customField.textColor = UIColor(white: 0.95, alpha: 1)
        customField.backgroundColor = UIColor(white: 0.08, alpha: 1)
        customField.layer.cornerRadius = 8
        customField.autocorrectionType = .no
        customField.autocapitalizationType = .none
        customField.returnKeyType = .go
        customField.delegate = self
        customField.clearButtonMode = .whileEditing
        customField.setLeftPaddingPoints(10)
        customField.attributedPlaceholder = NSAttributedString(
            string: "e.g. rich  •  pandas==2.0  •  git+https://...",
            attributes: [.foregroundColor: UIColor(white: 0.45, alpha: 1),
                         .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)])
        customField.translatesAutoresizingMaskIntoConstraints = false

        var cfg = UIButton.Configuration.filled()
        cfg.title = "Install"
        cfg.image = UIImage(systemName: "arrow.down.circle.fill")
        cfg.imagePadding = 6
        cfg.baseBackgroundColor = UIColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0)
        cfg.baseForegroundColor = .white
        cfg.cornerStyle = .medium
        customInstallButton.configuration = cfg
        customInstallButton.addTarget(self, action: #selector(customInstallTapped), for: .touchUpInside)
        customInstallButton.translatesAutoresizingMaskIntoConstraints = false
        customInstallButton.setContentHuggingPriority(.required, for: .horizontal)

        container.addSubview(label)
        container.addSubview(customField)
        container.addSubview(customInstallButton)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            customField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            customField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            customField.heightAnchor.constraint(equalToConstant: 38),

            customInstallButton.centerYAnchor.constraint(equalTo: customField.centerYAnchor),
            customInstallButton.leadingAnchor.constraint(equalTo: customField.trailingAnchor, constant: 8),
            customInstallButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            customInstallButton.heightAnchor.constraint(equalToConstant: 38),

            container.bottomAnchor.constraint(equalTo: customField.bottomAnchor, constant: 12),
        ])
        return container
    }

    private func makeDivider() -> UIView {
        let divider = UIView()
        divider.backgroundColor = UIColor(white: 0.18, alpha: 1)
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return divider
    }

    // MARK: - Dynamic table sizing
    private func updateTableHeight() {
        tableView.layoutIfNeeded()
        let h = tableView.contentSize.height + 4
        tableHeightConstraint?.constant = max(h, 80)
        view.layoutIfNeeded()
    }

    // MARK: - UITableView
    func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
        return filtered.count
    }

    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "pkg", for: indexPath) as! PackageCell
        let pkg = filtered[indexPath.row]
        cell.configure(name: pkg.displayName, summary: pkg.summary)
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        let pkg = filtered[indexPath.row]
        installPackage(spec: pkg.pipSpec, displayName: pkg.name, importName: pkg.importAs ?? pkg.name)
    }

    // MARK: - UISearchBar
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            filtered = curated
        } else {
            filtered = curated.filter { $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
        }
        tableView.reloadData()
        DispatchQueue.main.async { [weak self] in self?.updateTableHeight() }
    }

    // MARK: - UITextField (custom install)
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        customInstallTapped()
        return true
    }

    @objc private func customInstallTapped() {
        let spec = customField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !spec.isEmpty else {
            appendOutput("\n[!] Enter a package spec above (e.g. rich, pandas==2.0, git+https://…)\n")
            return
        }
        view.endEditing(true)
        // Infer display name from spec (before any version pin)
        let displayName = spec.split(whereSeparator: { "=<>!~@".contains($0) }).first.map(String.init) ?? spec
        installPackage(spec: spec, displayName: displayName, importName: displayName)
    }

    // MARK: - Install driver
    private func installPackage(spec: String, displayName: String, importName: String) {
        guard !isInstalling else {
            appendOutput("\n[!] Another install is already running. Please wait.\n")
            return
        }
        isInstalling = true
        customInstallButton.isEnabled = false

        // Fresh terminal session
        termOutputView.text = ""
        appendOutput("$ pip install \(spec)\n", color: UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1))
        appendOutput("# target: ~/Documents/site-packages\n", color: UIColor(white: 0.55, alpha: 1))
        appendOutput("# python: 3.14 iOS arm64\n\n", color: UIColor(white: 0.55, alpha: 1))
        setStage(.resolving)

        let pyCode = """
import os, sys, time, re
# Ensure Documents/site-packages exists + is on sys.path
doc_dir = os.path.expanduser('~/Documents')
user_site = os.path.join(doc_dir, 'site-packages')
os.makedirs(user_site, exist_ok=True)
if user_site not in sys.path:
    sys.path.insert(0, user_site)

os.environ.setdefault('PIP_DISABLE_PIP_VERSION_CHECK', '1')
os.environ.setdefault('PIP_NO_CACHE_DIR', '1')
# Force unbuffered + progress-bar-on output so the terminal updates live
os.environ['PYTHONUNBUFFERED'] = '1'
os.environ['PIP_PROGRESS_BAR'] = 'on'

try:
    from pip._internal.cli.main import main as pip_main
except Exception as e:
    print(f'[FATAL] pip is not available in the bundle: {e}', flush=True)
    raise SystemExit(2)

args = ['install', '--target', user_site, '--upgrade', '--no-warn-script-location', '--progress-bar', 'on']
parts = \(dump(spec)).split()
args.extend(parts)
print(f'[STAGE resolving] args: {args}', flush=True)

t0 = time.time()
try:
    rc = pip_main(args)
except SystemExit as e:
    rc = int(e.code) if e.code is not None else 0
elapsed = time.time() - t0

print()
if rc == 0:
    print(f'[STAGE verifying] checking import …', flush=True)
    import importlib, importlib.util
    name = \(dump(importName))
    try:
        spec_ = importlib.util.find_spec(name)
        if spec_ is not None:
            print(f'  ✓ import {name}  → {spec_.origin}', flush=True)
            # count file + total size of the installed package dir
            pkg_dir = None
            if spec_.submodule_search_locations:
                pkg_dir = list(spec_.submodule_search_locations)[0]
            elif spec_.origin:
                pkg_dir = os.path.dirname(spec_.origin)
            if pkg_dir and os.path.isdir(pkg_dir):
                nfiles = 0
                nbytes = 0
                for root, _, files in os.walk(pkg_dir):
                    for f in files:
                        try:
                            p = os.path.join(root, f)
                            nbytes += os.path.getsize(p)
                            nfiles += 1
                        except OSError:
                            pass
                kb = nbytes / 1024.0
                print(f'  ✓ {nfiles} files  ·  {kb:,.1f} KB', flush=True)
            # Version from dist-info, if any
            try:
                from importlib.metadata import version as _ver
                v = _ver(name.replace('_', '-'))
                print(f'  ✓ version: {v}', flush=True)
            except Exception:
                pass
        else:
            print(f'  [?] Installed, but "import {name}" did not resolve. Try a different import name.', flush=True)
            rc = 3
    except Exception as e:
        print(f'  [?] find_spec({name}) failed: {e}', flush=True)
        rc = 3

print()
print(f'[STAGE done] pip exited with code {rc} in {elapsed:.1f}s', flush=True)
"""
        let runtime = PythonRuntime.shared
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = runtime.execute(code: pyCode) { chunk in
                DispatchQueue.main.async { self?.handlePipChunk(chunk) }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Final stage based on whether we saw a final success marker
                let text = self.termOutputView.text ?? ""
                let failed = text.contains("ERROR:") || text.contains("[FATAL]") || text.contains("exited with code 1")
                let verifyFailed = text.contains("did not resolve") || text.contains("find_spec") && text.contains("failed:")
                if failed || verifyFailed {
                    self.setStage(.failure)
                    self.appendOutput("\n❌ Install failed — scroll up for details.\n", color: Stage.failure.color)
                } else {
                    self.setStage(.success)
                    self.appendOutput("\n✅ \(displayName) is ready to import.\n   Try it in the Editor:   import \(importName)\n",
                                      color: Stage.success.color)
                }
                self.isInstalling = false
                self.customInstallButton.isEnabled = true
                self.onDidFinishInstall?()
            }
        }
    }

    // MARK: - Live pip chunk handling

    /// Parses a new chunk of pip stdout/stderr and:
    /// 1) extracts [STAGE xxx] markers to drive the colored status bar
    /// 2) parses percent progress like "  36%|████    | 128kB/1.2MB" and
    ///    any "x/y" counters at install time, and updates the progress bar
    /// 3) appends the text (with line colors for ERROR/WARNING/↓ download/…)
    private func handlePipChunk(_ chunk: String) {
        // Stage markers
        if let range = chunk.range(of: #"\[STAGE ([a-z]+)\]"#, options: .regularExpression) {
            let match = String(chunk[range]).replacingOccurrences(of: "[STAGE ", with: "")
                                             .replacingOccurrences(of: "]", with: "")
            switch match {
            case "resolving":   setStage(.resolving)
            case "downloading": setStage(.downloading)
            case "installing":  setStage(.installing)
            case "verifying":   setStage(.verifying)
            default: break
            }
        }
        // Heuristic: pip's CollectedPackage starts with "Collecting X", then
        // "Downloading ...", then "Installing collected packages:"
        if chunk.contains("Collecting ") || chunk.contains("Looking in indexes") {
            setStage(.resolving)
        }
        if chunk.contains("Downloading ") {
            setStage(.downloading)
        }
        if chunk.contains("Installing collected packages:") {
            setStage(.installing)
        }
        // Parse percent indicators like "  36%|████    |" OR "(36.0 MB)"
        if let pct = parsePercent(in: chunk) {
            termProgressBar.setProgress(Float(pct) / 100.0, animated: true)
        }
        appendOutput(chunk)
    }

    private func parsePercent(in chunk: String) -> Int? {
        // Match patterns like "  36%" or "|100%|"
        let pattern = #"(\d{1,3})%"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let match = re.firstMatch(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)),
           let rng = Range(match.range(at: 1), in: chunk) {
            return Int(chunk[rng])
        }
        return nil
    }

    // Quote a Swift string as a Python literal.
    private func dump(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Output

    private func appendOutput(_ text: String, color: UIColor? = nil) {
        let attr = NSMutableAttributedString(attributedString: termOutputView.attributedText ?? NSAttributedString(string: ""))

        let lineColor: UIColor
        if let color = color {
            lineColor = color
        } else if text.hasPrefix("$ ") || text.contains("[STAGE ") {
            lineColor = UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1)
        } else if text.contains("ERROR:") || text.contains("error:") || text.contains("Traceback") {
            lineColor = Stage.failure.color
        } else if text.contains("WARNING:") || text.contains("warning:") {
            lineColor = Stage.installing.color
        } else if text.contains("✓") || text.contains("Successfully installed") {
            lineColor = Stage.success.color
        } else if text.contains("Downloading ") || text.contains("Collecting ") {
            lineColor = UIColor(red: 0.55, green: 0.8, blue: 1.0, alpha: 1)
        } else if text.contains("Installing collected packages:") {
            lineColor = Stage.installing.color
        } else {
            lineColor = UIColor(white: 0.88, alpha: 1)
        }

        let piece = NSAttributedString(string: text, attributes: [
            .foregroundColor: lineColor,
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        ])
        attr.append(piece)
        termOutputView.attributedText = attr

        // Always auto-scroll
        let last = NSRange(location: max(0, (termOutputView.attributedText?.length ?? 1) - 1), length: 1)
        termOutputView.scrollRangeToVisible(last)
    }
}

// MARK: - Cell
private final class PackageCell: UITableViewCell {
    private let nameLabel = UILabel()
    private let summaryLabel = UILabel()
    private let installIcon = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = UIColor(white: 0.12, alpha: 1)
        contentView.backgroundColor = .clear
        selectionStyle = .default
        let selBg = UIView()
        selBg.backgroundColor = UIColor(white: 0.19, alpha: 1)
        selectedBackgroundView = selBg

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = UIColor(white: 0.95, alpha: 1)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 12, weight: .regular)
        summaryLabel.textColor = UIColor(white: 0.6, alpha: 1)
        summaryLabel.numberOfLines = 2
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        installIcon.image = UIImage(systemName: "arrow.down.circle")
        installIcon.tintColor = UIColor(white: 0.5, alpha: 1)
        installIcon.translatesAutoresizingMaskIntoConstraints = false
        installIcon.contentMode = .scaleAspectFit

        contentView.addSubview(nameLabel)
        contentView.addSubview(summaryLabel)
        contentView.addSubview(installIcon)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            nameLabel.trailingAnchor.constraint(equalTo: installIcon.leadingAnchor, constant: -10),

            summaryLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            summaryLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            summaryLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            installIcon.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            installIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            installIcon.widthAnchor.constraint(equalToConstant: 22),
            installIcon.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not impl") }

    func configure(name: String, summary: String) {
        nameLabel.text = name
        summaryLabel.text = summary
    }
}

// MARK: - UITextField padding helper
private extension UITextField {
    func setLeftPaddingPoints(_ amount: CGFloat) {
        let paddingView = UIView(frame: CGRect(x: 0, y: 0, width: amount, height: frame.size.height))
        self.leftView = paddingView
        self.leftViewMode = .always
    }
}

// MARK: - Padding label (so "● pip — idle" isn't flush against the status dot)
private final class PaddingLabel: UILabel {
    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(width: base.width + 2, height: base.height)
    }
}
