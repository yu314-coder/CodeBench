import UIKit
import QuartzCore

// MARK: - Secret features hub
//
// All discoverable-but-hidden visual extras live in this file so they
// can be enabled/disabled centrally and don't pollute production VCs.
// Each is a small standalone class — instantiate and pin to a view.

// ════════════════════════════════════════════════════════════════════
// 1. Performance HUD — 7 taps on Run button toggles
// ════════════════════════════════════════════════════════════════════

final class PerformanceHUD: UIView {
    static let shared = PerformanceHUD()
    private let label = UILabel()
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var frameCount = 0
    private var fps: Double = 0

    private init() {
        super.init(frame: CGRect(x: 20, y: 100, width: 130, height: 60))
        backgroundColor = UIColor.black.withAlphaComponent(0.7)
        layer.cornerRadius = 8
        layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.5).cgColor
        layer.borderWidth = 1
        label.frame = bounds.insetBy(dx: 8, dy: 6)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .systemGreen
        label.numberOfLines = 0
        addSubview(label)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func drag(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: superview)
        center.x += t.x; center.y += t.y
        g.setTranslation(.zero, in: superview)
    }

    func toggle(in host: UIView) {
        if superview == nil { host.addSubview(self) }
        isHidden.toggle()
        if !isHidden { start() } else { stop() }
    }

    private func start() {
        stop()
        let dl = CADisplayLink(target: self, selector: #selector(tick))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
        lastFrameTime = CACurrentMediaTime()
    }
    private func stop() { displayLink?.invalidate(); displayLink = nil }

    @objc private func tick() {
        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastFrameTime >= 0.5 {
            fps = Double(frameCount) / (now - lastFrameTime)
            frameCount = 0; lastFrameTime = now
            refresh()
        }
    }

    private func refresh() {
        let mem = appPhysFootprintMB()
        let avail = osProcAvailableMemoryMB()
        label.text = String(format:
            "FPS  %5.1f\nMEM  %d MB\nAVL  %d MB",
            fps, mem, avail)
    }

    private func appPhysFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { r in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), r, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) / (1024 * 1024) : 0
    }
    private func osProcAvailableMemoryMB() -> Int {
        let h = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "os_proc_available_memory")
        guard let h else { return 0 }
        let fn = unsafeBitCast(h, to: (@convention(c) () -> Int).self)
        return fn() / (1024 * 1024)
    }
}


// ════════════════════════════════════════════════════════════════════
// 2. Retro / theme cycler — 3-finger swipe down in editor, OR
//    long-press 3 sec on terminal title bar (= retro amber only).
// ════════════════════════════════════════════════════════════════════

enum SecretTheme: Int, CaseIterable {
    case off, amber, matrix, dracula

    var name: String {
        switch self {
        case .off:     return "default"
        case .amber:   return "amber CRT"
        case .matrix:  return "matrix"
        case .dracula: return "dracula"
        }
    }
    var bg: UIColor {
        switch self {
        case .off:     return UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        case .amber:   return UIColor(red: 0.07, green: 0.04, blue: 0.02, alpha: 1)
        case .matrix:  return UIColor.black
        case .dracula: return UIColor(red: 0.157, green: 0.165, blue: 0.212, alpha: 1)
        }
    }
    var fg: UIColor {
        switch self {
        case .off:     return UIColor(red: 0.82, green: 0.83, blue: 0.87, alpha: 1)
        case .amber:   return UIColor(red: 1.0, green: 0.71, blue: 0.15, alpha: 1)
        case .matrix:  return UIColor(red: 0.20, green: 1.0, blue: 0.40, alpha: 1)
        case .dracula: return UIColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1)
        }
    }
}

final class SecretThemeManager {
    static let shared = SecretThemeManager()
    static let didChange = Notification.Name("SecretThemeDidChange")

    private(set) var current: SecretTheme = .off

    func apply(_ t: SecretTheme) {
        current = t
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    func cycle() {
        let all = SecretTheme.allCases
        let next = all[(current.rawValue + 1) % all.count]
        apply(next)
    }
}


// ════════════════════════════════════════════════════════════════════
// 3. CRT scanlines overlay — non-interactive thin lines + glow.
// ════════════════════════════════════════════════════════════════════

final class CRTScanlinesView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.compositingFilter = "screenBlendMode"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.06).cgColor)
        ctx.setLineWidth(1)
        var y: CGFloat = 0
        while y < rect.height {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: rect.width, y: y))
            y += 3
        }
        ctx.strokePath()
    }
}


// ════════════════════════════════════════════════════════════════════
// 5. Snowfall — December only
// ════════════════════════════════════════════════════════════════════

final class SnowfallView: UIView {
    private var flakes: [(layer: CATextLayer, vy: CGFloat, vx: CGFloat)] = []
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    static var isDecember: Bool {
        Calendar.current.component(.month, from: Date()) == 12
    }

    func start(count: Int = 28) {
        for _ in 0..<count {
            let l = CATextLayer()
            l.string = "❄"
            l.fontSize = CGFloat.random(in: 9...18)
            l.contentsScale = UIScreen.main.scale
            l.foregroundColor = UIColor.white.withAlphaComponent(CGFloat.random(in: 0.3...0.7)).cgColor
            l.frame = CGRect(x: CGFloat.random(in: 0..<bounds.width),
                             y: CGFloat.random(in: -bounds.height..<0),
                             width: 20, height: 20)
            layer.addSublayer(l)
            flakes.append((l, CGFloat.random(in: 0.4...1.2), CGFloat.random(in: -0.3...0.3)))
        }
        let dl = CADisplayLink(target: self, selector: #selector(tick))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }
    func stop() { displayLink?.invalidate(); displayLink = nil; flakes.forEach { $0.layer.removeFromSuperlayer() }; flakes.removeAll() }

    @objc private func tick() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for f in flakes {
            var fr = f.layer.frame
            fr.origin.y += f.vy
            fr.origin.x += f.vx
            if fr.minY > bounds.height {
                fr.origin.y = -fr.height
                fr.origin.x = CGFloat.random(in: 0..<bounds.width)
            }
            f.layer.frame = fr
        }
        CATransaction.commit()
    }
}


// ════════════════════════════════════════════════════════════════════
// 6. Confetti — for the celebrate-on-shake reward
// ════════════════════════════════════════════════════════════════════

final class ConfettiView: UIView {
    func burst() {
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: -20)
        emitter.emitterShape = .line
        emitter.emitterSize = CGSize(width: bounds.width, height: 1)
        let colors: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemPink]
        emitter.emitterCells = colors.map { c in
            let cell = CAEmitterCell()
            cell.contents = makeDot(c).cgImage
            cell.birthRate = 6
            cell.lifetime = 6
            cell.velocity = 240
            cell.velocityRange = 80
            cell.emissionLongitude = .pi
            cell.emissionRange = .pi / 4
            cell.spin = 4
            cell.spinRange = 4
            cell.scale = 0.5
            cell.scaleRange = 0.3
            return cell
        }
        layer.addSublayer(emitter)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { emitter.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            emitter.removeFromSuperlayer()
            self.removeFromSuperview()
        }
    }
    private func makeDot(_ color: UIColor) -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        return r.image { ctx in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 12, height: 12)).fill()
        }
    }
}


// ════════════════════════════════════════════════════════════════════
// 7. Konami code tracker
// ════════════════════════════════════════════════════════════════════

// KonamiTracker + KeyCaptureWindow were removed per user request
// (the up-up-down-down → Developer panel easter egg). The properties
// and types are no longer referenced anywhere in the app; if the
// Developer Panel is wanted again it can be reached directly via the
// `DeveloperPanelViewController` below.


// ════════════════════════════════════════════════════════════════════
// 8. Defeated face toast — 10× rapid stop
// ════════════════════════════════════════════════════════════════════

enum SecretToast {
    static func defeated(on host: UIView) {
        showBig(host: host, lines: [
            "  (•_•)",
            " <)   )╯  I give up.",
            "  /    \\",
        ])
    }
    static func celebrate(on host: UIView, title: String) {
        showBig(host: host, lines: ["🏆", title])
    }
    static func custom(on host: UIView, lines: [String]) { showBig(host: host, lines: lines) }

    private static func showBig(host: UIView, lines: [String]) {
        let v = UILabel()
        v.text = lines.joined(separator: "\n")
        v.numberOfLines = 0
        v.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        v.textColor = .white
        v.textAlignment = .center
        v.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        v.layer.cornerRadius = 12
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            v.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.8),
        ])
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.4
        v.layer.shadowOffset = .zero
        v.layer.shadowRadius = 12
        UIView.animate(withDuration: 0.25, animations: { v.alpha = 1; v.transform = CGAffineTransform(scaleX: 1.05, y: 1.05) }) { _ in
            UIView.animate(withDuration: 0.15) { v.transform = .identity }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            UIView.animate(withDuration: 0.35, animations: { v.alpha = 0 }) { _ in v.removeFromSuperview() }
        }
    }
}


// ════════════════════════════════════════════════════════════════════
// 9. Credits sheet — long-press System tab title
// ════════════════════════════════════════════════════════════════════

final class SecretCreditsViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.098, green: 0.102, blue: 0.114, alpha: 1)
        title = "Credits"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))

        let label = UILabel()
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.attributedText = NSAttributedString(string:
            """

            CodeBench

            An iPad Python / LaTeX / AI workstation.
            Bundled: CPython 3.14, NumPy, SciPy, Matplotlib,
            Manim, llama.cpp, Cairo, Pango, Busytex, KaTeX,
            SwiftTerm, Monaco, pywebview.

            Hidden features you've now found:
              • 5-tap on Settings title  → Browser history
              • 3-finger 3× tap on System  → Reopen last URL
              • 3-finger swipe-down editor → Cycle secret themes
              • 7-tap on Run button  → Performance HUD
              • 10× rapid Stop  → Defeated face
              • Long-press System title  → This screen
              • Konami code  → Developer panel
              • Long-press terminal title  → Retro amber mode

            Built with care.
            """,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor(red: 0.82, green: 0.835, blue: 0.87, alpha: 1),
            ])
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }
    @objc private func close() { dismiss(animated: true) }
}


// ════════════════════════════════════════════════════════════════════
// 10. Developer panel — Konami code reward
// ════════════════════════════════════════════════════════════════════

final class DeveloperPanelViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private struct Section { let title: String; let rows: [DevRow] }
    private enum DevRow {
        case info(key: String, value: () -> String)               // read-only display, re-evaluated on refresh
        case action(title: String, subtitle: String, handler: (DeveloperPanelViewController) -> Void)
        case toggle(title: String, getter: () -> Bool, setter: (Bool) -> Void)
    }
    private var sections: [Section] = []
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var refreshTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Dark canvas matches the Hidden Games launcher / app shell.
        view.backgroundColor = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1.0)  // #0a0a0f
        title = ""
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh, target: self, action: #selector(reload))

        buildSections()

        // Hero header — violet `terminal.fill` glyph + title + subtitle,
        // mounted as the table's tableHeaderView so it scrolls with the
        // section list and uses the table's own width.
        let header = makeHeroHeader()
        table.tableHeaderView = header
        // After the table has a width we can size the header to fit.
        table.layoutIfNeeded()
        header.frame.size = header.systemLayoutSizeFitting(
            CGSize(width: table.bounds.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        table.tableHeaderView = header

        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self; table.delegate = self
        // Inset-grouped on top of dark — system separators get auto-drawn
        // between rows; we kill the inset background later in cellForRow
        // by setting bg directly on the cell.
        table.backgroundColor = .clear
        table.separatorColor = UIColor.white.withAlphaComponent(0.06)
        table.sectionHeaderTopPadding = 14
        table.register(UITableViewCell.self, forCellReuseIdentifier: "k")
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Refresh memory/info rows every second while visible.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.table.reloadData()
        }
    }

    /// Hero card mounted at the top of the table — violet glyph in a
    /// tinted disc, big rounded title, muted subtitle. Mirrors the
    /// look of the Hidden Games launcher header.
    private func makeHeroHeader() -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(red: 0.071, green: 0.071, blue: 0.102, alpha: 1.0)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.layer.borderColor = UIColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 0.15).cgColor
        card.layer.borderWidth = 1

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIImage(systemName: "terminal.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold))
        icon.tintColor = UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 1.0)
        icon.layer.shadowColor = icon.tintColor.cgColor
        icon.layer.shadowOpacity = 0.55
        icon.layer.shadowRadius = 8
        icon.layer.shadowOffset = .zero

        let titleLbl = UILabel()
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.text = "Developer"
        titleLbl.font = .systemFont(ofSize: 24, weight: .bold).rounded
        titleLbl.textColor = UIColor(red: 0.941, green: 0.941, blue: 0.961, alpha: 1.0)

        let subLbl = UILabel()
        subLbl.translatesAutoresizingMaskIntoConstraints = false
        subLbl.text = "Memory probes, Python diagnostics, easter eggs."
        subLbl.font = .systemFont(ofSize: 12, weight: .regular)
        subLbl.textColor = UIColor(red: 0.420, green: 0.420, blue: 0.502, alpha: 1.0)
        subLbl.numberOfLines = 2

        let textCol = UIStackView(arrangedSubviews: [titleLbl, subLbl])
        textCol.translatesAutoresizingMaskIntoConstraints = false
        textCol.axis = .vertical
        textCol.spacing = 3

        card.addSubview(icon)
        card.addSubview(textCol)
        container.addSubview(card)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 36),
            icon.heightAnchor.constraint(equalToConstant: 36),

            textCol.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            textCol.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            textCol.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            textCol.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -18),
        ])
        return container
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate(); refreshTimer = nil
    }

    @objc private func close()  { dismiss(animated: true) }
    @objc private func reload() { buildSections(); table.reloadData() }

    // MARK: - Section builder

    private func buildSections() {
        let info = Bundle.main.infoDictionary ?? [:]
        sections = [
            // ── App identity ──────────────────────────────────────
            Section(title: "App", rows: [
                .info(key: "Version",   value: { (info["CFBundleShortVersionString"] as? String) ?? "?" }),
                .info(key: "Build",     value: { (info["CFBundleVersion"] as? String) ?? "?" }),
                .info(key: "Bundle id", value: { Bundle.main.bundleIdentifier ?? "?" }),
                .info(key: "Device",    value: { "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)" }),
                .info(key: "Locale",    value: { Locale.current.identifier }),
            ]),

            // ── Live memory ───────────────────────────────────────
            Section(title: "Memory (live)", rows: [
                .info(key: "phys_footprint", value: { Self.formatBytes(Self.physFootprint()) }),
                .info(key: "resident_size",  value: { Self.formatBytes(Self.residentSize()) }),
                .info(key: "available",      value: { Self.formatBytes(Self.osAvailable()) }),
                .info(key: "device RAM",     value: { Self.formatBytes(Int(ProcessInfo.processInfo.physicalMemory)) }),
                .action(title: "Force GC + malloc release",
                        subtitle: "Trigger gc.collect ×3 + malloc_zone_pressure_relief on every zone") { vc in
                    vc.runPython(
                        "import gc, ctypes; gc.collect(); gc.collect(); gc.collect(); " +
                        "ctypes.CDLL(None).malloc_zone_pressure_relief(None, 0); " +
                        "print('done')")
                },
                .action(title: "Memory stress test (allocate 200 MB)",
                        subtitle: "Allocate then free a 200 MB buffer — confirms jetsam awareness") { vc in
                    vc.runPython("import os; b = bytearray(200*1024*1024); print('allocated 200 MB at', hex(id(b))); del b; import gc; gc.collect()")
                },
            ]),

            // ── Python runtime ────────────────────────────────────
            Section(title: "Python", rows: [
                .info(key: "Version", value: { Self.pythonVersion() }),
                .info(key: "sys.path entries", value: { String(Self.sysPathCount()) }),
                .action(title: "Print sys.path",
                        subtitle: "Dump every entry to the terminal") { vc in
                    vc.runPython("import sys; print('\\n'.join(sys.path))")
                },
                .action(title: "List installed packages",
                        subtitle: "Top-level directories in site-packages") { vc in
                    vc.runPython(
                        "import os, sys, pathlib; " +
                        "site = next((p for p in sys.path if p.endswith('site-packages')), None); " +
                        "print('\\n'.join(sorted(os.listdir(site))) if site else '(no site-packages on sys.path)')")
                },
                .action(title: "Reset manim / pyav state",
                        subtitle: "Drop modules + flush Cairo/Pango/numpy caches") { vc in
                    vc.runPython("import offlinai_shell; offlinai_shell._codebench_force_kill(); print('reset complete')")
                },
                .action(title: "Run smoke test",
                        subtitle: "Execute /Volumes/D/OfflinAi/test_new_additions.py if present") { vc in
                    vc.runPython(
                        "import os, runpy; p = '/Volumes/D/OfflinAi/test_new_additions.py'; " +
                        "runpy.run_path(p, run_name='__main__') if os.path.exists(p) else print('test file not bundled')")
                },
            ]),

            // ── Visual extras (direct toggles) ─────────────────────
            Section(title: "Visual extras", rows: [
                .info(key: "Theme", value: { SecretThemeManager.shared.current.name }),
                .action(title: "Cycle theme",
                        subtitle: "default → amber → matrix → dracula") { _ in
                    SecretThemeManager.shared.cycle()
                },
                .action(title: "Default theme", subtitle: "remove CRT effects") { _ in
                    SecretThemeManager.shared.apply(.off)
                },
                .action(title: "Toggle performance HUD",
                        subtitle: "Live FPS / memory overlay") { vc in
                    if let win = vc.presentingViewController?.view {
                        PerformanceHUD.shared.toggle(in: win)
                    }
                },
                .action(title: "Confetti burst",
                        subtitle: "Just for fun — tests the particle emitter") { vc in
                    let host = vc.view!
                    let c = ConfettiView(frame: host.bounds)
                    c.translatesAutoresizingMaskIntoConstraints = false
                    host.addSubview(c)
                    NSLayoutConstraint.activate([
                        c.topAnchor.constraint(equalTo: host.topAnchor),
                        c.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                        c.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                        c.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    ])
                    host.layoutIfNeeded()
                    c.burst()
                },
            ]),

            // ── State management ──────────────────────────────────
            Section(title: "State", rows: [
                .action(title: "Reset onboarding",
                        subtitle: "Show onboarding again on next launch") { vc in
                    UserDefaults.standard.removeObject(forKey: "onboarding.completed")
                    vc.toast("onboarding will show on next launch")
                },
                .action(title: "Clear browser history",
                        subtitle: "Wipes recorded URLs (cookies kept)") { vc in
                    BrowserDataStore.shared.clearHistory()
                    vc.toast("history cleared")
                },
                .action(title: "Clear browser cookies",
                        subtitle: "Wipes the shared WKWebsiteDataStore cookie jar") { vc in
                    BrowserDataStore.shared.clearCookies {
                        vc.toast("cookies cleared")
                    }
                },
                .action(title: "Dump UserDefaults",
                        subtitle: "Print every key → value to the terminal") { vc in
                    let d = UserDefaults.standard.dictionaryRepresentation()
                    let lines = d.keys.sorted().map { "\($0) = \(d[$0] ?? "")" }
                        .joined(separator: "\n")
                    vc.runPython("print('''\n" + lines.replacingOccurrences(of: "'", with: "\\'") + "\n''')")
                },
                .action(title: "Open crash log",
                        subtitle: "~/Documents/log.txt — session + crash records") { vc in
                    vc.runPython(
                        "import os; p = os.path.expanduser('~/Documents/log.txt'); " +
                        "print(open(p).read()[-4000:] if os.path.exists(p) else 'no crash log yet')")
                },
            ]),

            // ── Easter eggs (direct triggers) ─────────────────────
            Section(title: "Easter eggs (direct)", rows: [
                .action(title: "Open Hidden Games",
                        subtitle: "2048 · Dungeon · Space Invaders") { vc in
                    let games = HiddenGamesLauncher()
                    let nav = UINavigationController(rootViewController: games)
                    nav.modalPresentationStyle = .fullScreen
                    vc.present(nav, animated: true)
                },
                .action(title: "Open browser history",
                        subtitle: "Same as 5-tap on Settings title") { vc in
                    let h = BrowserHistoryViewController()
                    let nav = UINavigationController(rootViewController: h)
                    nav.modalPresentationStyle = .pageSheet
                    vc.present(nav, animated: true)
                },
                .action(title: "Defeated face toast",
                        subtitle: "Same as 10× rapid Stop") { vc in
                    SecretToast.defeated(on: vc.view)
                },
            ]),
        ]
    }

    // MARK: - Helpers

    fileprivate func runPython(_ code: String) {
        // Stream output back to the terminal — this is the same path
        // the Run button uses. We don't surface a "completed" toast
        // because the user will see the print() lands in the terminal.
        toast("running…")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = PythonRuntime.shared.execute(code: code, targetScene: nil, onOutput: { _ in })
        }
    }

    fileprivate func toast(_ msg: String) {
        let l = UILabel()
        l.text = "  \(msg)  "
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .white
        l.backgroundColor = UIColor(red: 0.40, green: 0.59, blue: 0.93, alpha: 1)
        l.layer.cornerRadius = 8
        l.clipsToBounds = true
        l.alpha = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            l.heightAnchor.constraint(equalToConstant: 28),
        ])
        UIView.animate(withDuration: 0.2, animations: { l.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.25, delay: 1.2, options: [], animations: { l.alpha = 0 }) { _ in
                l.removeFromSuperview()
            }
        }
    }

    // MARK: - System metrics (static, no allocations on the hot path)

    private static func physFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { r in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), r, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
    private static func residentSize() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { r in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), r, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
    private static func osAvailable() -> Int {
        guard let h = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "os_proc_available_memory") else { return 0 }
        let fn = unsafeBitCast(h, to: (@convention(c) () -> Int).self)
        return fn()
    }
    private static func formatBytes(_ b: Int) -> String {
        if b > 1 << 30 { return String(format: "%.2f GB", Double(b) / Double(1 << 30)) }
        if b > 1 << 20 { return "\(b / (1 << 20)) MB" }
        if b > 1 << 10 { return "\(b / (1 << 10)) KB" }
        return "\(b) B"
    }
    private static func pythonVersion() -> String {
        // Cheap probe — read PYTHONHOME's lib dir name. Doesn't
        // require holding the GIL.
        if let home = ProcessInfo.processInfo.environment["PYTHONHOME"] {
            let lib = (home as NSString).appendingPathComponent("lib")
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: lib) {
                for e in entries where e.hasPrefix("python") { return String(e.dropFirst("python".count)) }
            }
        }
        return "?"
    }
    private static func sysPathCount() -> Int {
        // Without GIL we can't ask Python directly. The bundled
        // site-packages + version dir + lib-dynload + Documents
        // site-packages = 4 minimum, plus pandas_ios. Counting is
        // approximate but useful to spot misconfiguration.
        var count = 0
        if let home = ProcessInfo.processInfo.environment["PYTHONHOME"] {
            count += FileManager.default.fileExists(atPath: "\(home)/lib") ? 1 : 0
        }
        if let bundle = Bundle.main.resourceURL?.appendingPathComponent("app_packages/site-packages"),
           FileManager.default.fileExists(atPath: bundle.path) { count += 1 }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("site-packages"),
           FileManager.default.fileExists(atPath: docs.path) { count += 1 }
        return count
    }

    // MARK: - UITableView

    private static let fg = UIColor(red: 0.941, green: 0.941, blue: 0.961, alpha: 1.0)
    private static let muted = UIColor(red: 0.420, green: 0.420, blue: 0.502, alpha: 1.0)
    private static let actionTint = UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 1.0) // violet
    private static let monoVal = UIColor(red: 0.776, green: 0.788, blue: 1.0, alpha: 1.0)       // soft indigo
    private static let cardBg = UIColor(red: 0.071, green: 0.071, blue: 0.102, alpha: 1.0)

    func numberOfSections(in t: UITableView) -> Int { sections.count }
    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { sections[s].rows.count }

    func tableView(_ t: UITableView, viewForHeaderInSection s: Int) -> UIView? {
        let container = UIView()
        container.backgroundColor = .clear
        let lbl = UILabel()
        lbl.translatesAutoresizingMaskIntoConstraints = false
        let kern: CGFloat = 1.5  // ≈ 0.14em letter-spacing at 11pt
        lbl.attributedText = NSAttributedString(
            string: sections[s].title.uppercased(),
            attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: Self.muted,
                .kern: kern,
            ])
        container.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            lbl.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            lbl.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
        ])
        return container
    }
    func tableView(_ t: UITableView, heightForHeaderInSection s: Int) -> CGFloat { 38 }

    func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = t.dequeueReusableCell(withIdentifier: "k", for: ip)
        c.accessoryType = .none
        c.backgroundColor = Self.cardBg
        // Custom selection highlight in violet so the default blue
        // doesn't fight the dark theme.
        let sel = UIView()
        sel.backgroundColor = Self.actionTint.withAlphaComponent(0.10)
        c.selectedBackgroundView = sel
        let row = sections[ip.section].rows[ip.row]
        switch row {
        case .info(let key, let value):
            var cfg = UIListContentConfiguration.valueCell()
            cfg.text = key
            cfg.secondaryText = value()
            cfg.textProperties.color = Self.fg
            cfg.textProperties.font = .systemFont(ofSize: 14, weight: .regular)
            cfg.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cfg.secondaryTextProperties.color = Self.monoVal
            c.contentConfiguration = cfg
            c.selectionStyle = .none
        case .action(let title, let subtitle, _):
            var cfg = UIListContentConfiguration.subtitleCell()
            cfg.text = title
            cfg.secondaryText = subtitle
            cfg.textProperties.color = Self.actionTint
            cfg.textProperties.font = .systemFont(ofSize: 15, weight: .medium).rounded
            cfg.secondaryTextProperties.font = .systemFont(ofSize: 12)
            cfg.secondaryTextProperties.color = Self.muted
            c.contentConfiguration = cfg
            // Custom chevron coloured to the violet accent.
            let chev = UIImageView(image: UIImage(systemName: "chevron.right",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
            chev.tintColor = Self.actionTint.withAlphaComponent(0.55)
            chev.frame = CGRect(x: 0, y: 0, width: 14, height: 14)
            c.accessoryView = chev
            c.accessoryType = .none
        case .toggle(let title, let getter, _):
            var cfg = UIListContentConfiguration.valueCell()
            cfg.text = title
            cfg.secondaryText = getter() ? "ON" : "OFF"
            cfg.textProperties.color = Self.fg
            cfg.secondaryTextProperties.color = getter()
                ? UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1.0)
                : Self.muted
            cfg.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            c.contentConfiguration = cfg
        }
        return c
    }

    func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        t.deselectRow(at: ip, animated: true)
        let row = sections[ip.section].rows[ip.row]
        switch row {
        case .action(_, _, let handler): handler(self)
        case .toggle(_, let getter, let setter): setter(!getter()); t.reloadRows(at: [ip], with: .none)
        default: break
        }
    }
}
