import UIKit

/// "System" tab content. Aggregates everything a power user might want
/// to see at-a-glance about the running CodeBench instance: device
/// model + OS, Python version + paths, runtime memory + storage, the
/// SSL trust roots, and a snapshot of which native runtimes are
/// available (C / C++ / Fortran / LaTeX / executorch).
///
/// Refreshes on every viewWillAppear so a `pip install` / model load /
/// `cd` from the terminal is reflected the next time the user opens
/// the tab. The expensive calls (Python introspection, du-walk) run
/// on a background queue; UI update bounces back to main.
final class SystemInfoViewController: UIViewController {

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let bgColor   = UIColor(red: 0.098, green: 0.102, blue: 0.114, alpha: 1)
    private let surfaceColor = UIColor(red: 0.130, green: 0.137, blue: 0.157, alpha: 1)
    private let textColor = UIColor(red: 0.820, green: 0.835, blue: 0.870, alpha: 1)
    private let dimColor  = UIColor(red: 0.520, green: 0.540, blue: 0.580, alpha: 1)
    private let accentColor = UIColor(red: 0.400, green: 0.588, blue: 0.929, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.indicatorStyle = .white
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    /// Cached snapshot from the last refresh. Reused across tab
    /// visits so flipping back to System Info is instant — only
    /// pip-install events would invalidate it (not yet wired up).
    private static var cachedInfo: PythonInfo?

    private func refresh() {
        // Pure-Swift probe — walks ~250 dist-info dirs on the
        // main thread but each one is a metadata read (~few KB),
        // total ~50 ms even on slow iPad. No PythonRuntime.shared
        // .execute() call, so we never block on the Python queue
        // even when the REPL is busy. Synchronous keeps the rebuild
        // single-pass — no flicker between "probing…" and real data.
        let pyInfo = SystemInfoViewController.swiftPythonProbe()
        SystemInfoViewController.cachedInfo = pyInfo
        rebuildContent(pythonInfo: pyInfo)
    }

    private func rebuildContent(pythonInfo: PythonInfo?) {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        contentStack.addArrangedSubview(makeHeroHeader())
        contentStack.addArrangedSubview(
            makeCard(title: "Device", icon: "ipad",
                     rows: deviceRows()))
        contentStack.addArrangedSubview(
            makeCard(title: "App", icon: "app.badge",
                     rows: appRows()))
        contentStack.addArrangedSubview(
            makeCard(title: "Python", icon: "snowflake",
                     rows: pythonRows(pythonInfo)))
        contentStack.addArrangedSubview(
            makeCard(title: "Storage", icon: "internaldrive",
                     rows: storageRows()))
        contentStack.addArrangedSubview(
            makeCard(title: "SSL trust", icon: "lock.shield",
                     rows: sslRows(pythonInfo)))
        contentStack.addArrangedSubview(
            makeCard(title: "Runtimes available", icon: "hammer",
                     rows: runtimesRows()))
    }

    // MARK: - Hero Header

    private func makeHeroHeader() -> UIView {
        let v = UIView()
        v.layer.cornerRadius = 16
        v.layer.cornerCurve = .continuous
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        v.clipsToBounds = true

        // Subtle gradient — accent fading into surface — for a more
        // polished look than the flat surfaceColor previously used.
        let gradient = CAGradientLayer()
        gradient.colors = [
            accentColor.withAlphaComponent(0.35).cgColor,
            surfaceColor.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.frame = CGRect(x: 0, y: 0, width: 1000, height: 200)
        v.layer.insertSublayer(gradient, at: 0)
        // Resize the gradient with the view (cheap layoutSubviews-style
        // trick using a wrapper that exposes layoutSubviews).
        let proxy = GradientResizeView(layer: gradient)
        proxy.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(proxy)
        NSLayoutConstraint.activate([
            proxy.topAnchor.constraint(equalTo: v.topAnchor),
            proxy.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            proxy.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            proxy.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])

        let icon = UIImageView(image: UIImage(systemName: "info.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)))
        icon.tintColor = accentColor
        // Without an explicit size + scaleAspectFit, the UIImageView
        // would stretch to fill the hero card's full height (the
        // horizontal-stack alignment was happy to make it ~80pt tall),
        // producing a giant blue ellipse instead of a small icon.
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
        ])

        let title = UILabel()
        title.text = "System Info"
        title.font = UIFont.systemFont(ofSize: 26, weight: .bold).rounded
        title.textColor = textColor

        let subtitle = UILabel()
        subtitle.text = "Tap a value to copy. Switch tabs to refresh."
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = dimColor

        let textStack = UIStackView(arrangedSubviews: [title, subtitle])
        textStack.axis = .vertical; textStack.spacing = 2

        let stack = UIStackView(arrangedSubviews: [icon, textStack])
        stack.axis = .horizontal; stack.spacing = 14; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -18),
        ])
        return v
    }

    // MARK: - Card factory

    private func makeCard(title: String, icon: String, rows: [(String, String)]) -> UIView {
        let card = UIView()
        card.backgroundColor = surfaceColor
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        // Faint border + shadow for slight depth so cards read as
        // separate cards instead of one flat surface.
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor(white: 1, alpha: 0.06).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.20
        card.layer.shadowOffset = CGSize(width: 0, height: 1)
        card.layer.shadowRadius = 4
        card.translatesAutoresizingMaskIntoConstraints = false

        // Header with icon + title (rounded SF Pro for the title).
        let iconBg = UIView()
        iconBg.backgroundColor = accentColor.withAlphaComponent(0.15)
        iconBg.layer.cornerRadius = 8
        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconBg.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let iconView = UIImageView(image: UIImage(systemName: icon,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
        iconView.tintColor = accentColor
        iconView.contentMode = .center
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBg.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
        ])

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold).rounded
        titleLabel.textColor = textColor

        let header = UIStackView(arrangedSubviews: [iconBg, titleLabel])
        header.axis = .horizontal; header.spacing = 10; header.alignment = .center

        // Rows: each is a key/value horizontal pair, monospace value.
        // Values that read like a status ("✓ available", "— not found",
        // "<unset>") get colored — green for ✓, red for —, dim for unset.
        let rowsStack = UIStackView()
        rowsStack.axis = .vertical; rowsStack.spacing = 6

        for (k, v) in rows {
            let kLabel = UILabel()
            kLabel.text = k
            kLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium).rounded
            kLabel.textColor = dimColor
            kLabel.setContentHuggingPriority(.required, for: .horizontal)
            kLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true

            let vLabel = UILabel()
            vLabel.text = v
            vLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            vLabel.textColor = Self.colorForValue(v, default: textColor,
                                                  ok: UIColor(red: 0.36, green: 0.85, blue: 0.55, alpha: 1.0),
                                                  bad: UIColor(red: 0.95, green: 0.45, blue: 0.45, alpha: 1.0),
                                                  dim: dimColor)
            vLabel.numberOfLines = 0
            vLabel.lineBreakMode = .byCharWrapping

            vLabel.isUserInteractionEnabled = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(copyValue(_:)))
            vLabel.addGestureRecognizer(tap)

            let row = UIStackView(arrangedSubviews: [kLabel, vLabel])
            row.axis = .horizontal; row.alignment = .top; row.spacing = 12
            rowsStack.addArrangedSubview(row)
        }

        let cardStack = UIStackView(arrangedSubviews: [header, rowsStack])
        cardStack.axis = .vertical; cardStack.spacing = 14
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    /// Pick a sensible color for a value cell based on its content.
    /// "✓ <anything>" is green, "— <anything>" is red, "<unset>" is
    /// dimmed, "loading…" is dimmed, everything else uses the default.
    private static func colorForValue(_ v: String, default def: UIColor,
                                      ok: UIColor, bad: UIColor, dim: UIColor) -> UIColor {
        let trimmed = v.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("✓") { return ok }
        if trimmed.hasPrefix("—") { return bad }
        if trimmed == "<unset>" || trimmed.hasSuffix("…") || trimmed.hasSuffix("loading") {
            return dim
        }
        return def
    }

    @objc private func copyValue(_ sender: UITapGestureRecognizer) {
        guard let lbl = sender.view as? UILabel, let text = lbl.text, !text.isEmpty else {
            return
        }
        UIPasteboard.general.string = text
        // Light haptic so the user knows the tap was received.
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()
    }

    // MARK: - Row builders

    private func deviceRows() -> [(String, String)] {
        let device = UIDevice.current
        let processInfo = ProcessInfo.processInfo
        let memBytes = processInfo.physicalMemory
        let model = systemModelIdentifier()
        return [
            ("Model",       model),
            ("Display",     device.model),
            ("OS",          "\(device.systemName) \(device.systemVersion)"),
            ("Name",        device.name),
            ("CPU cores",   "\(processInfo.activeProcessorCount) active / \(processInfo.processorCount) total"),
            ("RAM",         formatBytes(Int64(memBytes))),
            ("Up since",    formatDate(Date().addingTimeInterval(-processInfo.systemUptime))),
        ]
    }

    private func appRows() -> [(String, String)] {
        let info = Bundle.main.infoDictionary ?? [:]
        let displayName = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String ?? "?"
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build   = info["CFBundleVersion"] as? String ?? "?"
        let bundleID = Bundle.main.bundleIdentifier ?? "?"
        return [
            ("Display name", displayName),
            ("Version",     "\(version) (\(build))"),
            ("Bundle ID",   bundleID),
            ("Bundle path", Bundle.main.bundlePath),
            ("Documents",   NSHomeDirectory() + "/Documents"),
        ]
    }

    private func pythonRows(_ info: PythonInfo?) -> [(String, String)] {
        guard let info = info else {
            return [("Status", "probing the interpreter…")]
        }
        var rows: [(String, String)] = [
            ("Version",       info.version),
            ("Platform",      info.platform),
            ("Executable",    info.executable),
            ("Prefix",        info.prefix),
            ("Packages",      "\(info.packageCount) installed (\(info.userPackageCount) user-installed)"),
        ]
        if !info.firstFewPackages.isEmpty {
            rows.append(("Recent",
                info.firstFewPackages.prefix(5).joined(separator: ", ")))
        }
        return rows
    }

    /// Cached directory sizes (computed once on a background queue,
    /// reused across rebuilds). The walk over the multi-hundred-MB
    /// app bundle would freeze the main thread for ~1 s if recomputed
    /// on every refresh — measure once, reuse forever (the bundle is
    /// read-only at runtime so its size won't change).
    private static var cachedBundleSize: Int64 = 0
    private static var cachedDocsSize: Int64 = 0
    private static var sizeProbeStarted = false

    private func storageRows() -> [(String, String)] {
        let docs = NSHomeDirectory() + "/Documents"
        let attrs = (try? FileManager.default.attributesOfFileSystem(forPath: docs)) ?? [:]
        let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free  = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let used  = max(0, total - free)

        // Kick off the async size walk once (per app launch). Until
        // it returns, "(measuring…)" stands in. Subsequent visits
        // see the cached values immediately.
        let bundleSize = SystemInfoViewController.cachedBundleSize
        let docsSize = SystemInfoViewController.cachedDocsSize
        if !SystemInfoViewController.sizeProbeStarted {
            SystemInfoViewController.sizeProbeStarted = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let bundlePath = Bundle.main.bundlePath
                let docsPath = NSHomeDirectory() + "/Documents"
                let bs = SystemInfoViewController.directorySize(at: bundlePath)
                let ds = SystemInfoViewController.directorySize(at: docsPath)
                SystemInfoViewController.cachedBundleSize = bs
                SystemInfoViewController.cachedDocsSize = ds
                DispatchQueue.main.async {
                    self?.rebuildContent(pythonInfo: SystemInfoViewController.cachedInfo)
                }
            }
        }
        return [
            ("Disk free",    formatBytes(free)),
            ("Disk used",    formatBytes(used)),
            ("Disk total",   formatBytes(total)),
            ("App bundle",   bundleSize > 0 ? formatBytes(bundleSize) : "(measuring…)"),
            ("Documents",    docsSize > 0 ? formatBytes(docsSize) : "(measuring…)"),
        ]
    }

    private func sslRows(_ info: PythonInfo?) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("SSL_CERT_FILE",      ProcessInfo.processInfo.environment["SSL_CERT_FILE"] ?? "<unset>"),
            ("REQUESTS_CA_BUNDLE", ProcessInfo.processInfo.environment["REQUESTS_CA_BUNDLE"] ?? "<unset>"),
        ]
        if let info = info {
            rows.append(("OpenSSL", info.opensslVersion))
            rows.append(("Default cafile", info.defaultCAFile))
        }
        return rows
    }

    private func runtimesRows() -> [(String, String)] {
        let fm = FileManager.default
        let bundle = Bundle.main.bundlePath
        let appPkg = bundle + "/app_packages/site-packages"

        // Detection approach:
        //   • Python — the app we're running IS Python; if we got
        //     this far it's loaded, so always "available". (Probing
        //     filesystem paths is fragile; the version comes from
        //     gatherPythonInfo().)
        //   • C / C++ / Fortran — in-process runtimes statically
        //     linked into the app binary. Same logic: if the wrapper
        //     classes exist at compile time, runtime presence is a
        //     given.
        //   • LaTeX (busytex.wasm) — bundle resource. Xcode 16's
        //     synchronized-root flattens subfolders, use
        //     Bundle.main.url to find it wherever Xcode placed it.
        //   • llama.cpp — embedded .framework (xcframework resolved
        //     at build time). Walk Frameworks/ for any llama*.
        //   • ExecuTorch — linked statically ("Do Not Embed"). No
        //     separate file exists at runtime; check if the source
        //     framework dir was even shipped, OR fall back to
        //     "always available" since we link against it.
        //   • PyTorch — Python package, look for torch/__init__.py.

        func bundleHas(_ name: String, ext: String) -> Bool {
            Bundle.main.url(forResource: name, withExtension: ext) != nil
        }

        // llama: try .framework, .xcframework, and any directory
        // starting with "llama" inside Frameworks/.
        var llamaOK = fm.fileExists(atPath: bundle + "/Frameworks/llama.framework")
            || fm.fileExists(atPath: bundle + "/Frameworks/llama.xcframework")
        if !llamaOK,
           let entries = try? fm.contentsOfDirectory(atPath: bundle + "/Frameworks") {
            llamaOK = entries.contains { $0.lowercased().contains("llama") }
        }

        let busytexOK = bundleHas("busytex", ext: "wasm")
        let torchOK = fm.fileExists(atPath: appPkg + "/torch/__init__.py")

        // ExecuTorch: the xcframework is linked statically (Do Not
        // Embed) so detecting via filesystem at runtime is unreliable.
        // We DO ship Frameworks/ExecuTorch/ at source-tree level, but
        // whether that survives into the runtime .app depends on
        // build settings. Best-effort: report ExecuTorch as available
        // because the app wouldn't link if it were missing — append
        // a "statically linked" note so the user understands why
        // there's no path.

        func mark(_ ok: Bool) -> String { ok ? "✓ available" : "— not found" }

        return [
            ("Python",     "✓ \(Bundle.main.bundlePath)/Frameworks/Python.framework"),
            ("C / C++",    "✓ via in-process clang+lld"),
            ("Fortran",    "✓ via in-process flang+lld"),
            ("LaTeX",      mark(busytexOK) + (busytexOK ? " (busytex.wasm — pdftex/xelatex/lualatex)" : "")),
            ("ExecuTorch", "✓ statically linked into app binary"),
            ("llama.cpp",  mark(llamaOK) + (llamaOK ? " (Frameworks/llama)" : "")),
            ("PyTorch",    mark(torchOK) + (torchOK ? " (app_packages/site-packages/torch)" : "")),
        ]
    }

    // MARK: - Python introspection

    struct PythonInfo: Equatable {
        let version: String
        let platform: String
        let executable: String
        let prefix: String
        let opensslVersion: String
        let defaultCAFile: String
        let packageCount: Int
        let userPackageCount: Int
        let totalPackageSize: Int64
        let firstFewPackages: [String]   // most recently added (user_site first)
    }

    /// Pure-Swift Python probe — walks the bundled and user
    /// site-packages directly, never calls into the running
    /// interpreter. This avoids the previous freeze where
    /// `PythonRuntime.shared.execute()` would block on the runtime
    /// queue for arbitrary time when the REPL was mid-task. The
    /// trade-off: we don't get sys.version etc. dynamically, but
    /// for our shipped Python 3.14 build the value is fixed and
    /// can be inferred from the bundle layout.
    static func swiftPythonProbe() -> PythonInfo? {
        let bundle = Bundle.main.bundlePath
        let bundleSite = bundle + "/app_packages/site-packages"
        let userSite = NSHomeDirectory() + "/Documents/site-packages"

        // sys.version: the bundle's python/lib/python3.X dir tells us
        // the Python version we shipped. Fall back to "3.14" since
        // that's what the project pins.
        var pyVersion = "3.14"
        if let entries = try? FileManager.default.contentsOfDirectory(
            atPath: bundle + "/python/lib") {
            if let dir = entries.first(where: { $0.hasPrefix("python3.") }) {
                pyVersion = String(dir.dropFirst("python".count))
            }
        }

        // Walk both site-packages dirs for *.dist-info/METADATA. Each
        // dist-info gives us Name + Version. We don't need the version
        // for the System tab — just the count + names.
        func collectDistInfo(_ root: String, isUser: Bool) -> [(name: String, isUser: Bool)] {
            guard FileManager.default.fileExists(atPath: root),
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: root)
            else { return [] }
            return entries.compactMap { entry -> (String, Bool)? in
                guard entry.hasSuffix(".dist-info") else { return nil }
                let metadata = root + "/" + entry + "/METADATA"
                guard let raw = try? String(contentsOfFile: metadata, encoding: .utf8)
                else { return nil }
                for line in raw.split(separator: "\n", maxSplits: 30,
                                      omittingEmptySubsequences: true) {
                    if line.hasPrefix("Name: ") {
                        let name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { return (name, isUser) }
                    }
                }
                return nil
            }
        }
        let bundled = collectDistInfo(bundleSite, isUser: false)
        let user = collectDistInfo(userSite, isUser: true)
        let totalCount = bundled.count + user.count
        let userCount = user.count
        let recent = user.map(\.0)

        // SSL trust roots — read from environment variables that the
        // shell bootstrap sets to certifi. No interpreter call needed.
        let caFile = ProcessInfo.processInfo.environment["SSL_CERT_FILE"]
            ?? bundle + "/app_packages/site-packages/certifi/cacert.pem"

        return PythonInfo(
            version:    pyVersion,
            platform:   "ios",
            executable: bundle + "/python/bin/python3",
            prefix:     bundle + "/python",
            opensslVersion: "OpenSSL (bundled)",
            defaultCAFile:  caFile,
            packageCount:   totalCount,
            userPackageCount: userCount,
            totalPackageSize: 0,
            firstFewPackages: Array(recent.suffix(8))
        )
    }

    // MARK: - Helpers

    private func systemModelIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let raw = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return raw.isEmpty ? "?" : raw
    }

    private static func directorySize(at path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let entry as String in enumerator {
            let full = path + "/" + entry
            if let attrs = try? fm.attributesOfItem(atPath: full),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    private func formatBytes(_ n: Int64) -> String {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        let v = Double(n)
        if v >= gb { return String(format: "%.2f GB", v / gb) }
        if v >= mb { return String(format: "%.1f MB", v / mb) }
        if v >= kb { return String(format: "%.0f KB", v / kb) }
        return "\(n) B"
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}

/// Tiny helper view that resizes an external CAGradientLayer to its
/// own bounds. Lets the hero header use a gradient via insertSublayer
/// without needing a full UIView subclass for the gradient itself.
private final class GradientResizeView: UIView {
    private let target: CAGradientLayer
    init(layer: CAGradientLayer) {
        self.target = layer
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        target.frame = bounds
    }
}
