import UIKit
import Darwin.Mach

// Bridge for iOS 13+ jetsam-headroom query. Symbol lives in libsystem.
@_silgen_name("os_proc_available_memory")
private func _osProcAvailableMemoryBridge() -> Int

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

    /// One row in a card. Either an info pair (`.kv`) or a tappable
    /// action button (`.action`). Letting cards mix the two means
    /// the Diagnostics card can sit next to Storage in the same
    /// visual style.
    private enum Row {
        case kv(String, String)
        case action(title: String, subtitle: String?, destructive: Bool, action: () -> Void)

        /// Adapter so existing card builders that return
        /// `[(String, String)]` tuples plug into the new `[Row]` API
        /// without per-callsite `.map { .kv($0, $1) }`.
        static func kvFromTuple(_ t: (String, String)) -> Row { .kv(t.0, t.1) }
    }

    /// Cards rebuild only their own rows on subsequent refreshes
    /// (was: full content-stack teardown on every refresh, which
    /// caused flicker, scroll-position resets, and made async size
    /// walks redo work for every other card on completion). The
    /// rowsStack ref lives on the cached `Card` and gets its
    /// arranged-subviews swapped in place.
    private struct Card {
        let view: UIView
        let rowsStack: UIStackView
    }
    private var cards: [String: Card] = [:]

    /// Live Memory-card timer. Polls every 2s while the System tab is
    /// visible so the user sees a moving footprint. Suspended in
    /// viewWillDisappear so we don't waste CPU when the tab is hidden.
    private var memoryTimer: Timer?

    /// Process-state card needs to react to thermal / foreground
    /// notifications. We hold the observers so we can unregister
    /// (deinit + viewWillDisappear).
    private var stateObservers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor
        setupUI()
        installSecretBrowserGesture()
    }

    // MARK: - Hidden browser launcher
    //
    // 3-finger triple-tap anywhere on the System tab opens a prompt
    // to relaunch the most recent URL from BrowserDataStore in a
    // real browser view, with a choice of "Use saved cookies" or
    // "Fresh session". Lives on the System tab on purpose — that
    // tab is for diagnostics, totally unrelated to browsing, and
    // there's no visible affordance. Combined with the 5-tap on
    // Settings → BrowserHistory pane, this is a separate hidden
    // path entirely; the user has to know it exists AND know it
    // lives on this tab AND know the gesture.

    private func installSecretBrowserGesture() {
        let g = UITapGestureRecognizer(target: self, action: #selector(secretReopenLast))
        g.numberOfTouchesRequired = 3
        g.numberOfTapsRequired = 3
        g.cancelsTouchesInView = false
        view.addGestureRecognizer(g)

        // Long-press 2s anywhere on the System tab → credits sheet.
        let lp = UILongPressGestureRecognizer(target: self,
                                              action: #selector(showSecretCredits))
        lp.minimumPressDuration = 2.0
        lp.cancelsTouchesInView = false
        view.addGestureRecognizer(lp)
    }

    @objc private func showSecretCredits() {
        let vc = SecretCreditsViewController()
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    @objc private func secretReopenLast() {
        let visits = BrowserDataStore.shared.loadHistory()
        guard let last = visits.last else {
            let a = UIAlertController(title: "No history",
                                      message: "Nothing has been recorded yet.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
            return
        }
        let alert = UIAlertController(
            title: last.title.isEmpty ? "Reopen last URL?" : last.title,
            message: last.url,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Use saved cookies",
                                      style: .default) { _ in
            self.secretOpenInBrowser(url: last.url, fresh: false)
        })
        alert.addAction(UIAlertAction(title: "Fresh session",
                                      style: .default) { _ in
            self.secretOpenInBrowser(url: last.url, fresh: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func secretOpenInBrowser(url: String, fresh: Bool) {
        guard let liveURL = URL(string: url) else { return }
        let vc = MiniBrowserViewController(url: liveURL, fresh: fresh)
        let nav = UINavigationController(rootViewController: vc)
        // Sheet presentation with detents (iOS 16+) so the user can
        // drag the grabber between small / medium / fullscreen, OR
        // tap the size button in the nav bar to cycle. Falls back
        // to .pageSheet on older iOS.
        nav.modalPresentationStyle = .pageSheet
        if #available(iOS 16.0, *), let sheet = nav.sheetPresentationController {
            let small = UISheetPresentationController.Detent.custom(
                identifier: .init("mini-small")) { ctx in
                    ctx.maximumDetentValue * 0.30
                }
            sheet.detents = [small, .medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.largestUndimmedDetentIdentifier = .large
        }
        present(nav, animated: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        startMemoryTimer()
        registerStateObservers()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        memoryTimer?.invalidate()
        memoryTimer = nil
        stateObservers.forEach { NotificationCenter.default.removeObserver($0) }
        stateObservers.removeAll()
    }

    deinit {
        memoryTimer?.invalidate()
        stateObservers.forEach { NotificationCenter.default.removeObserver($0) }
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
        // First call seeds the stack with hero + every card, caching
        // each card by name in `cards`. Subsequent calls just refresh
        // each card's rows in place — no flicker, scroll position
        // preserved.
        let firstBuild = cards.isEmpty
        if firstBuild {
            contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            contentStack.addArrangedSubview(makeHeroHeader())
        }

        // Layout order — also defines vertical order on first build.
        let definitions: [(title: String, icon: String, rows: [Row])] = [
            ("Device",             "ipad",                  deviceRows().map(Row.kvFromTuple)),
            ("App",                "app.badge",             appRows().map(Row.kvFromTuple)),
            ("Python",             "snowflake",             pythonRows(pythonInfo).map(Row.kvFromTuple)),
            ("Memory",             "memorychip",            memoryRows()),
            ("Storage",            "internaldrive",         storageRows().map(Row.kvFromTuple)),
            ("Process",            "cpu",                   processRows()),
            ("SSL trust",          "lock.shield",           sslRows(pythonInfo).map(Row.kvFromTuple)),
            ("Runtimes available", "hammer",                runtimesRows().map(Row.kvFromTuple)),
            ("Diagnostics",        "stethoscope",           diagnosticsRows()),
        ]

        for def in definitions {
            if let existing = cards[def.title] {
                rebuildRows(existing.rowsStack, rows: def.rows)
            } else {
                let card = makeCard(title: def.title, icon: def.icon, rows: def.rows)
                cards[def.title] = card
                contentStack.addArrangedSubview(card.view)
            }
        }
    }

    /// Refresh a single named card's rows in-place. Called by async
    /// callbacks (storage size walk completes, memory timer ticks)
    /// without rebuilding any other card.
    private func updateCardRows(named name: String, rows: [Row]) {
        guard let card = cards[name] else { return }
        rebuildRows(card.rowsStack, rows: rows)
    }

    /// Replace every arranged-subview of the given rows-stack with
    /// freshly-built rows. Layout passes are batched into one frame
    /// so a partial swap doesn't briefly show empty rows.
    private func rebuildRows(_ stack: UIStackView, rows: [Row]) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for row in rows {
            stack.addArrangedSubview(buildRowView(row))
        }
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

    private func makeCard(title: String, icon: String, rows: [Row]) -> Card {
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

        // Rows live in their own stack so we can swap them without
        // touching the header. The whole-card refresh path below
        // reuses this stack across rebuilds.
        let rowsStack = UIStackView()
        rowsStack.axis = .vertical; rowsStack.spacing = 6
        for row in rows {
            rowsStack.addArrangedSubview(buildRowView(row))
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
        return Card(view: card, rowsStack: rowsStack)
    }

    /// Single row: key/value pair OR action button. Used by both the
    /// initial card build AND the in-place rebuild path.
    private func buildRowView(_ row: Row) -> UIView {
        switch row {
        case .kv(let k, let v):
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

            let stack = UIStackView(arrangedSubviews: [kLabel, vLabel])
            stack.axis = .horizontal; stack.alignment = .top; stack.spacing = 12
            return stack

        case .action(let title, let subtitle, let destructive, let action):
            let titleLabel = UILabel()
            titleLabel.text = title
            titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold).rounded
            titleLabel.textColor = destructive
                ? UIColor(red: 0.95, green: 0.45, blue: 0.45, alpha: 1.0)
                : accentColor

            let labelStack: UIStackView
            if let subtitle = subtitle {
                let sub = UILabel()
                sub.text = subtitle
                sub.font = .systemFont(ofSize: 11)
                sub.textColor = dimColor
                sub.numberOfLines = 0
                labelStack = UIStackView(arrangedSubviews: [titleLabel, sub])
                labelStack.spacing = 2
            } else {
                labelStack = UIStackView(arrangedSubviews: [titleLabel])
            }
            labelStack.axis = .vertical

            let chevron = UIImageView(image: UIImage(systemName: "chevron.right",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
            chevron.tintColor = dimColor
            chevron.contentMode = .center
            chevron.setContentHuggingPriority(.required, for: .horizontal)

            let stack = UIStackView(arrangedSubviews: [labelStack, chevron])
            stack.axis = .horizontal; stack.alignment = .center; stack.spacing = 12
            stack.isLayoutMarginsRelativeArrangement = true
            stack.layoutMargins = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

            let btn = UIControl()
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.layer.cornerRadius = 8
            btn.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: btn.topAnchor),
                stack.leadingAnchor.constraint(equalTo: btn.leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(equalTo: btn.trailingAnchor, constant: -4),
                stack.bottomAnchor.constraint(equalTo: btn.bottomAnchor),
            ])
            btn.addAction(UIAction { _ in
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.impactOccurred()
                action()
            }, for: .touchUpInside)
            // Press highlight — quick alpha pulse so a tap is obvious.
            btn.addAction(UIAction { _ in
                btn.alpha = 0.5
            }, for: .touchDown)
            btn.addAction(UIAction { _ in
                UIView.animate(withDuration: 0.15) { btn.alpha = 1 }
            }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
            return btn
        }
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

        let bundleSize = SystemInfoViewController.cachedBundleSize
        let docsSize = SystemInfoViewController.cachedDocsSize

        // Kick off the async size walk once. The completion now
        // refreshes ONLY the Storage card (was: rebuilding the whole
        // content stack, which caused flicker, scroll-position resets,
        // and triggered a redundant Python probe + runtimes scan).
        if !SystemInfoViewController.sizeProbeStarted {
            SystemInfoViewController.sizeProbeStarted = true
            startSizeProbe()
        }
        return [
            ("Disk free",    formatBytes(free)),
            ("Disk used",    formatBytes(used)),
            ("Disk total",   formatBytes(total)),
            ("App bundle",   bundleSize > 0 ? formatBytes(bundleSize) : "measuring…"),
            ("Documents",    docsSize > 0 ? formatBytes(docsSize) : "measuring…"),
        ]
    }

    /// Walk the bundle + Documents on a background queue, then push
    /// the result into the Storage card on main. Called from
    /// storageRows() the first time, and from the Diagnostics
    /// "Recompute storage" action on demand.
    private func startSizeProbe() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bundlePath = Bundle.main.bundlePath
            let docsPath = NSHomeDirectory() + "/Documents"
            let bs = SystemInfoViewController.directorySize(at: bundlePath)
            let ds = SystemInfoViewController.directorySize(at: docsPath)
            SystemInfoViewController.cachedBundleSize = bs
            SystemInfoViewController.cachedDocsSize = ds
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Refresh ONLY the Storage card — leaves Memory's
                // live-poll state, the user's scroll position, and
                // every other card's data alone.
                self.updateCardRows(named: "Storage",
                                    rows: self.storageRows().map(Row.kvFromTuple))
                // Diagnostics' subtitle includes the latest sizes,
                // refresh it too so "Recompute storage" reflects the
                // freshly-measured bytes.
                self.updateCardRows(named: "Diagnostics",
                                    rows: self.diagnosticsRows())
            }
        }
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

    // MARK: - Memory card (live polling)

    private func startMemoryTimer() {
        memoryTimer?.invalidate()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.updateCardRows(named: "Memory", rows: self.memoryRows())
        }
        if let t = memoryTimer {
            // Run during scroll so the user can watch the footprint
            // even while interacting with the System tab itself.
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func memoryRows() -> [Row] {
        let footprint = appPhysFootprint()
        let avail = osProcAvailableMemory()
        let resident = appResidentSize()
        let virt = appVirtualSize()
        let limit: UInt64 = footprint + UInt64(avail)

        let pct = limit > 0 ? Int((Double(footprint) / Double(limit)) * 100) : 0
        return [
            .kv("Footprint", "\(formatBytes(Int64(footprint)))   (\(pct)% of jetsam ceiling)"),
            .kv("Available", avail > 0 ? formatBytes(Int64(avail)) : "—"),
            .kv("Ceiling",   formatBytes(Int64(limit))),
            .kv("Resident",  formatBytes(Int64(resident))),
            .kv("Virtual",   formatBytes(Int64(virt))),
            .kv("Device RAM", formatBytes(Int64(ProcessInfo.processInfo.physicalMemory))),
        ]
    }

    /// Same task_info read as MemoryGraphView — phys_footprint is the
    /// number jetsam uses for kill decisions (Xcode's "Memory" gauge).
    private func appPhysFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reb, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private func appResidentSize() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reb, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    private func appVirtualSize() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reb in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reb, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.virtual_size : 0
    }

    private func osProcAvailableMemory() -> Int {
        // Symbol lives in libsystem on iOS 13+. _silgen_name binding
        // matches MemoryGraphView's (kept local so this file stays
        // self-contained).
        return _osProcAvailableMemoryBridge()
    }

    // MARK: - Process card (foreground/thermal/low-power state)

    private func registerStateObservers() {
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            ProcessInfo.thermalStateDidChangeNotification,
            UIApplication.didBecomeActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willResignActiveNotification,
            UIApplication.didBecomeActiveNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil,
                                       queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.updateCardRows(named: "Process", rows: self.processRows())
            }
            stateObservers.append(token)
        }
    }

    private func processRows() -> [Row] {
        let pi = ProcessInfo.processInfo
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active:     appState = "✓ active"
        case .inactive:   appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        let thermal: String
        switch pi.thermalState {
        case .nominal:  thermal = "✓ nominal"
        case .fair:     thermal = "fair"
        case .serious:  thermal = "— serious"
        case .critical: thermal = "— critical"
        @unknown default: thermal = "unknown"
        }
        let lowPower = pi.isLowPowerModeEnabled ? "— ON" : "✓ off"
        let uptime = pi.systemUptime
        let appUp = Date().timeIntervalSince(SystemInfoViewController.appLaunchDate)
        return [
            .kv("PID",          "\(pi.processIdentifier)"),
            .kv("App state",    appState),
            .kv("Thermal",      thermal),
            .kv("Low-power",    lowPower),
            .kv("System uptime", formatDuration(uptime)),
            .kv("App uptime",    formatDuration(appUp)),
            .kv("Active CPUs",   "\(pi.activeProcessorCount)/\(pi.processorCount)"),
            .kv("OS version",    "\(pi.operatingSystemVersionString)"),
        ]
    }

    // Captured once at first VC instantiation so "App uptime" reflects
    // session-since-launch, not since-tab-open.
    private static let appLaunchDate = Date()

    private func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, sec) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec)s"
    }

    // MARK: - Diagnostics card (action buttons)

    private func diagnosticsRows() -> [Row] {
        let bundleSize = SystemInfoViewController.cachedBundleSize
        let docsSize = SystemInfoViewController.cachedDocsSize
        let storageSubtitle: String
        if bundleSize > 0 || docsSize > 0 {
            storageSubtitle = "Bundle: \(formatBytes(bundleSize))   Docs: \(formatBytes(docsSize))"
        } else {
            storageSubtitle = "Run again to refresh size measurements"
        }

        return [
            .action(title: "Recompute storage sizes",
                    subtitle: storageSubtitle,
                    destructive: false) { [weak self] in
                SystemInfoViewController.cachedBundleSize = 0
                SystemInfoViewController.cachedDocsSize = 0
                guard let self = self else { return }
                self.updateCardRows(named: "Storage",
                                    rows: self.storageRows().map(Row.kvFromTuple))
                self.startSizeProbe()
            },
            .action(title: "Refresh Python info",
                    subtitle: "Re-scan installed packages + interpreter state",
                    destructive: false) { [weak self] in
                guard let self = self else { return }
                let info = SystemInfoViewController.swiftPythonProbe()
                SystemInfoViewController.cachedInfo = info
                self.updateCardRows(named: "Python",
                                    rows: self.pythonRows(info).map(Row.kvFromTuple))
                self.updateCardRows(named: "SSL trust",
                                    rows: self.sslRows(info).map(Row.kvFromTuple))
            },
            .action(title: "Open crash log",
                    subtitle: "Last 50 KB of ~/Documents/log.txt",
                    destructive: false) { [weak self] in
                self?.showFileTail(path: NSHomeDirectory() + "/Documents/log.txt",
                                    title: "Crash log")
            },
            .action(title: "Open shell bootstrap log",
                    subtitle: "REPL thread import attempts",
                    destructive: false) { [weak self] in
                self?.showFileTail(path: NSHomeDirectory() + "/Documents/shell_bootstrap.txt",
                                    title: "Shell bootstrap")
            },
            .action(title: "Dump Python threads",
                    subtitle: "Snapshot every Python stack to log.txt",
                    destructive: false) { [weak self] in
                self?.dumpPythonThreads()
            },
            .action(title: "Force garbage collection",
                    subtitle: "Run gc.collect() in the REPL interpreter",
                    destructive: false) { [weak self] in
                self?.forceGC()
            },
            .action(title: "Copy diagnostic summary",
                    subtitle: "Bundle ID, version, OS, RAM, sizes — to clipboard",
                    destructive: false) { [weak self] in
                self?.copyDiagnosticSummary()
            },
        ]
    }

    // MARK: - Diagnostic actions

    private func showFileTail(path: String, title: String) {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            let alert = UIAlertController(
                title: "\(title) not available",
                message: "\(path) doesn't exist yet.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let tail = data.suffix(50_000)
        let text = String(data: tail, encoding: .utf8)
            ?? "<\(data.count) bytes — not utf-8>"

        let vc = UIViewController()
        vc.view.backgroundColor = bgColor
        vc.title = title

        let tv = UITextView()
        tv.text = text
        tv.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.backgroundColor = bgColor
        tv.textColor = textColor
        tv.isEditable = false
        tv.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            tv.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.bottomAnchor),
        ])

        let nav = UINavigationController(rootViewController: vc)
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self,
            action: #selector(dismissModal))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            tv.scrollRangeToVisible(NSRange(location: text.count, length: 0))
        }
        present(nav, animated: true)
    }

    @objc private func dismissModal() { dismiss(animated: true) }

    private func dumpPythonThreads() {
        // Run on the runtime queue so it doesn't fight the REPL for
        // the GIL — but DON'T block the main thread waiting for
        // the result (the REPL queue may be busy).
        DispatchQueue.global(qos: .userInitiated).async {
            _ = PythonRuntime.shared.execute(code: """
            import faulthandler, sys, traceback
            try:
                faulthandler.dump_traceback(file=sys.__stderr__, all_threads=True)
                print('[diagnostics] thread dump written to stderr + log.txt')
            except Exception as e:
                print(f'[diagnostics] dump_traceback failed: {e}')
            """)
        }
        showToast("Thread dump scheduled — check ~/Documents/log.txt")
    }

    private func forceGC() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = PythonRuntime.shared.execute(code: """
            import gc
            before = len(gc.get_objects())
            collected = gc.collect()
            after = len(gc.get_objects())
            print(f'[diagnostics] gc.collect: '
                  f'{before:,} → {after:,} objects ({collected} collected)')
            """)
        }
        showToast("GC scheduled — output goes to terminal")
        // Bump the Memory card immediately so the user sees the drop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            self.updateCardRows(named: "Memory", rows: self.memoryRows())
        }
    }

    private func copyDiagnosticSummary() {
        let pi = ProcessInfo.processInfo
        let info = Bundle.main.infoDictionary ?? [:]
        let lines: [String] = [
            "CodeBench diagnostic snapshot",
            "Generated: \(Date())",
            "",
            "App: \(info["CFBundleDisplayName"] ?? info["CFBundleName"] ?? "?")  "
                + "v\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "Bundle ID: \(Bundle.main.bundleIdentifier ?? "?")",
            "OS: \(pi.operatingSystemVersionString)",
            "Device: \(systemModelIdentifier())",
            "Active CPUs: \(pi.activeProcessorCount)/\(pi.processorCount)",
            "Device RAM: \(formatBytes(Int64(pi.physicalMemory)))",
            "Footprint: \(formatBytes(Int64(appPhysFootprint())))",
            "Bundle size: \(SystemInfoViewController.cachedBundleSize > 0 ? formatBytes(SystemInfoViewController.cachedBundleSize) : "?")",
            "Documents:   \(SystemInfoViewController.cachedDocsSize > 0 ? formatBytes(SystemInfoViewController.cachedDocsSize) : "?")",
            "Thermal: \(thermalString(pi.thermalState))",
            "Low-power: \(pi.isLowPowerModeEnabled ? "ON" : "off")",
        ]
        UIPasteboard.general.string = lines.joined(separator: "\n")
        showToast("Diagnostic summary copied to clipboard")
    }

    private func thermalString(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func showToast(_ text: String) {
        let toast = UILabel()
        toast.text = text
        toast.font = .systemFont(ofSize: 13, weight: .medium)
        toast.textColor = .white
        toast.textAlignment = .center
        toast.numberOfLines = 0
        toast.backgroundColor = UIColor(white: 0.05, alpha: 0.92)
        toast.layer.cornerRadius = 10
        toast.layer.masksToBounds = true
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            toast.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
        // Internal padding: wrap with insets via a content view.
        let cap = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        toast.layoutMargins = cap
        UIView.animate(withDuration: 0.25, animations: { toast.alpha = 1 })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            UIView.animate(withDuration: 0.35, animations: { toast.alpha = 0 }) { _ in
                toast.removeFromSuperview()
            }
        }
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

    /// Recursively sum file sizes under `path`. Designed for the
    /// iOS app bundle (~200K files between numpy/matplotlib/manim/
    /// torch dist-infos) where a naive string-path walk takes
    /// minutes — leaving the System tab stuck on "(measuring…)"
    /// indefinitely.
    ///
    /// Why this is faster than `enumerator(atPath:) + attributesOfItem`:
    ///   • URL-based enumeration with `includingPropertiesForKeys`
    ///     prefetches stat data in a SINGLE syscall per directory
    ///     instead of one per file (10×+ speedup measured on iOS).
    ///   • `totalFileAllocatedSizeKey` returns actual on-disk bytes
    ///     (sparse files etc handled correctly) without an extra
    ///     stat round-trip.
    ///   • `skipsHiddenFiles` doesn't walk `.git`, `.DS_Store` chains.
    ///   • Symlinks are skipped to avoid loops + the bogus size of
    ///     "framework binary symlinked from Frameworks/X.framework/X".
    ///   • errorHandler returns true so a single unreadable framework
    ///     doesn't abort the whole walk (the bundled torch dylibs
    ///     have permission quirks that used to silently kill the
    ///     enumerator with no diagnostic).
    /// Typical iPad timing: ~150-400ms for the bundle, ~50-200ms for
    /// Documents.
    private static func directorySize(at path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        // NOTE: NO .skipsPackageDescendants — that would skip into
        // every .framework / .bundle which is where most of our
        // 200+ MB live (Python.framework, numpy/torch/etc. wrapped
        // as frameworks for App Store compliance).
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let rv = try? fileURL.resourceValues(forKeys: keys),
                  rv.isRegularFile == true,
                  rv.isSymbolicLink != true else { continue }
            // totalFileAllocatedSize falls back to fileAllocatedSize
            // for filesystems that don't report extended-attribute
            // overhead. Either is the right "on-disk bytes" answer.
            total += Int64(rv.totalFileAllocatedSize
                           ?? rv.fileAllocatedSize
                           ?? 0)
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
