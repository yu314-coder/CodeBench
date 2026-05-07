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

    private func refresh() {
        // Build the static (Swift-only) cards immediately so the user
        // sees something before the Python probe finishes. Python
        // probe runs in the background and re-renders when it
        // completes — same pattern the Libraries tab uses.
        rebuildContent(pythonInfo: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pyInfo = SystemInfoViewController.gatherPythonInfo()
            DispatchQueue.main.async {
                self?.rebuildContent(pythonInfo: pyInfo)
            }
        }
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
        v.backgroundColor = surfaceColor
        v.layer.cornerRadius = 12
        v.layer.cornerCurve = .continuous
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        let title = UILabel()
        title.text = "System Info"
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = textColor

        let subtitle = UILabel()
        subtitle.text = "Pull-to-refresh by switching tabs. All data is local."
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = dimColor

        let stack = UIStackView(arrangedSubviews: [title, subtitle])
        stack.axis = .vertical; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
        ])
        return v
    }

    // MARK: - Card factory

    private func makeCard(title: String, icon: String, rows: [(String, String)]) -> UIView {
        let card = UIView()
        card.backgroundColor = surfaceColor
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        // Header with icon + title
        let iconView = UIImageView(image: UIImage(systemName: icon,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
        iconView.tintColor = accentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = textColor

        let header = UIStackView(arrangedSubviews: [iconView, titleLabel])
        header.axis = .horizontal; header.spacing = 8; header.alignment = .center

        // Rows: each is a key/value horizontal pair, monospace value
        let rowsStack = UIStackView()
        rowsStack.axis = .vertical; rowsStack.spacing = 6

        for (k, v) in rows {
            let kLabel = UILabel()
            kLabel.text = k
            kLabel.font = .systemFont(ofSize: 12, weight: .medium)
            kLabel.textColor = dimColor
            kLabel.setContentHuggingPriority(.required, for: .horizontal)
            kLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true

            let vLabel = UILabel()
            vLabel.text = v
            vLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            vLabel.textColor = textColor
            vLabel.numberOfLines = 0
            vLabel.lineBreakMode = .byCharWrapping

            // Tap on the value: copy to clipboard. Useful for paths /
            // long versions the user might want to paste.
            vLabel.isUserInteractionEnabled = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(copyValue(_:)))
            vLabel.addGestureRecognizer(tap)

            let row = UIStackView(arrangedSubviews: [kLabel, vLabel])
            row.axis = .horizontal; row.alignment = .top; row.spacing = 12
            rowsStack.addArrangedSubview(row)
        }

        let cardStack = UIStackView(arrangedSubviews: [header, rowsStack])
        cardStack.axis = .vertical; cardStack.spacing = 12
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        return card
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

    private func storageRows() -> [(String, String)] {
        let docs = NSHomeDirectory() + "/Documents"
        let attrs = (try? FileManager.default.attributesOfFileSystem(forPath: docs)) ?? [:]
        let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free  = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let used  = max(0, total - free)
        let docsSize = directorySize(at: docs)
        let bundleSize = directorySize(at: Bundle.main.bundlePath)
        return [
            ("Disk free",    formatBytes(free)),
            ("Disk used",    formatBytes(used)),
            ("Disk total",   formatBytes(total)),
            ("App bundle",   formatBytes(bundleSize)),
            ("Documents",    formatBytes(docsSize)),
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

    struct PythonInfo {
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

    static func gatherPythonInfo() -> PythonInfo? {
        // Fast probe — no per-package du-walk (that took multiple
        // seconds on cold iPad and made the tab show "loading…" for
        // way too long). All we need is sys-level info plus a count
        // of installed dists; size is reported as 0 to indicate
        // "not measured" (the Storage card has the bundle size).
        let script = """
import sys, ssl, os, json
import importlib.metadata as _md

USER_SITE = os.path.expanduser("~/Documents/site-packages")

pkg_count = 0
user_count = 0
recent = []
for d in _md.distributions():
    try:
        name = d.metadata["Name"]
    except Exception:
        continue
    pkg_count += 1
    try:
        loc = str(d.locate_file("") or "")
    except Exception:
        loc = ""
    if loc and (USER_SITE in loc or "/Documents/site-packages" in loc):
        user_count += 1
        recent.append(name)

info = {
    "version":    sys.version.split()[0],
    "platform":   sys.platform,
    "executable": sys.executable,
    "prefix":     sys.prefix,
    "openssl":    ssl.OPENSSL_VERSION,
    "cafile":     ssl.get_default_verify_paths().cafile or "",
    "pkg_count":  pkg_count,
    "user_count": user_count,
    "size":       0,
    "recent":     recent[-8:],
}
print("__CODEBENCH_SYSINFO__=" + json.dumps(info))
"""
        let result = PythonRuntime.shared.execute(code: script)
        let output = result.output
        guard let r = output.range(of: "__CODEBENCH_SYSINFO__=") else { return nil }
        let json = String(output[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return PythonInfo(
            version:        (dict["version"]    as? String) ?? "?",
            platform:       (dict["platform"]   as? String) ?? "?",
            executable:     (dict["executable"] as? String) ?? "?",
            prefix:         (dict["prefix"]     as? String) ?? "?",
            opensslVersion: (dict["openssl"]    as? String) ?? "?",
            defaultCAFile:  (dict["cafile"]     as? String) ?? "<none>",
            packageCount:   (dict["pkg_count"]  as? Int)    ?? 0,
            userPackageCount: (dict["user_count"] as? Int)  ?? 0,
            totalPackageSize: (dict["size"] as? Int64)
                ?? Int64(((dict["size"] as? Int) ?? 0)),
            firstFewPackages: (dict["recent"]   as? [String]) ?? []
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

    private func directorySize(at path: String) -> Int64 {
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
