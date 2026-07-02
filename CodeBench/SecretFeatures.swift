import UIKit
import QuartzCore
import CoreImage

// MARK: - Secret features hub
//
// All discoverable-but-hidden visual extras live in this file so they
// can be enabled/disabled centrally and don't pollute production VCs.
// Each is a small standalone class — instantiate and pin to a view.

// ════════════════════════════════════════════════════════════════════
// 1. Performance HUD — 7 taps on Run button toggles
// ════════════════════════════════════════════════════════════════════

/// Small namespace for shared helpers used by the secret-features VCs.
enum SecretFeatures {
    /// The foreground active window's root view, used as a HUD host when
    /// no presenting-VC view is available. Read-only; touches no shared VC.
    static func keyHostView() -> UIView? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow })
    }
}

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

    private struct Section { let title: String; var icon: String? = nil; let rows: [DevRow] }
    private enum DevRow {
        case info(key: String, value: () -> String)               // read-only display, re-evaluated on refresh
        case action(title: String, subtitle: String, handler: (DeveloperPanelViewController) -> Void)
        case toggle(title: String, getter: () -> Bool, setter: (Bool) -> Void)
    }
    private var sections: [Section] = []
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var refreshTimer: Timer?
    private let launchUptime = ProcessInfo.processInfo.systemUptime  // for "panel uptime" delta
    private var fpsLink: CADisplayLink?
    private var fpsFrames = 0
    private var fpsWindowStart: CFTimeInterval = 0
    private var liveFPS: Double = 0

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

        // Footer credit — version/build, tappable hint mirrors "Copy diagnostics".
        let footer = UILabel()
        let fInfo = Bundle.main.infoDictionary ?? [:]
        footer.text = "CodeBench \((fInfo["CFBundleShortVersionString"] as? String) ?? "?") "
            + "(\((fInfo["CFBundleVersion"] as? String) ?? "?")) · developer tools"
        footer.font = .systemFont(ofSize: 11, weight: .regular)
        footer.textColor = Self.muted
        footer.textAlignment = .center
        footer.numberOfLines = 2
        footer.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: 56)
        table.tableFooterView = footer

        // Refresh memory/info rows every second while visible.
        // Refresh just the live values in the on-screen rows every second.
        // (Previously this called table.reloadData(), which on iPad reset the
        // scroll position — the panel kept jumping back to the top.)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshLiveValues()
        }

        // Lightweight FPS sampler owned by this VC (does not couple to the
        // shared PerformanceHUD). Torn down in viewWillDisappear.
        fpsWindowStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(fpsTick))
        link.add(to: .main, forMode: .common)
        fpsLink = link
    }

    @objc private func fpsTick() {
        fpsFrames += 1
        let now = CACurrentMediaTime()
        let dt = now - fpsWindowStart
        if dt >= 0.5 {
            liveFPS = Double(fpsFrames) / dt
            fpsFrames = 0
            fpsWindowStart = now
        }
    }

    /// Re-evaluate only the `.info` rows that are currently on screen and write
    /// their fresh value straight into the existing cell. No table.reloadData(),
    /// so the scroll position and any selection are preserved — this is what
    /// stops the iPad "panel scrolls back to the top every second" behaviour.
    private func refreshLiveValues() {
        refreshHeroChips()
        guard let visible = table.indexPathsForVisibleRows else { return }
        for ip in visible {
            guard ip.section < sections.count,
                  ip.row < sections[ip.section].rows.count,
                  let cell = table.cellForRow(at: ip) else { continue }
            if case .info(let key, let value) = sections[ip.section].rows[ip.row] {
                var cfg = UIListContentConfiguration.valueCell()
                cfg.text = key
                cfg.secondaryText = value()
                cfg.textProperties.color = Self.fg
                cfg.textProperties.font = .systemFont(ofSize: 14, weight: .regular)
                cfg.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                cfg.secondaryTextProperties.color = Self.monoVal
                cell.contentConfiguration = cfg
            }
        }
    }

    /// Hero card mounted at the top of the table — violet glyph + title,
    /// a row of LIVE stat chips (memory / free / fps, refreshed by the
    /// same 1 Hz timer as the table — no extra timers), and a row of
    /// one-tap quick actions so the most-used tools (Games, QR, smoke
    /// test, perf HUD) aren't buried sections deep.
    private var heroMemValue: UILabel?
    private var heroFreeValue: UILabel?
    private var heroFPSValue: UILabel?

    private func makeHeroHeader() -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.layer.borderColor = UIColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 0.15).cgColor
        card.layer.borderWidth = 1
        LiquidGlass.apply(to: card, corner: 18, dim: 0.30)

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
        titleLbl.textColor = Self.fg

        let subLbl = UILabel()
        subLbl.translatesAutoresizingMaskIntoConstraints = false
        subLbl.text = "Memory probes, Python diagnostics, easter eggs."
        subLbl.font = .systemFont(ofSize: 12, weight: .regular)
        subLbl.textColor = Self.muted
        subLbl.numberOfLines = 2

        let textCol = UIStackView(arrangedSubviews: [titleLbl, subLbl])
        textCol.translatesAutoresizingMaskIntoConstraints = false
        textCol.axis = .vertical
        textCol.spacing = 3

        // ── Live stat chips ───────────────────────────────────────────
        func makeChip(_ caption: String) -> (UIView, UILabel) {
            let wrap = UIView()
            wrap.backgroundColor = UIColor(white: 1, alpha: 0.04)
            wrap.layer.cornerRadius = 10
            wrap.layer.cornerCurve = .continuous
            wrap.layer.borderWidth = 1
            wrap.layer.borderColor = UIColor(white: 1, alpha: 0.06).cgColor
            let cap = UILabel()
            cap.text = caption
            cap.font = .systemFont(ofSize: 9, weight: .semibold)
            cap.textColor = Self.muted
            let val = UILabel()
            val.text = "—"
            val.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
            val.textColor = Self.monoVal
            val.adjustsFontSizeToFitWidth = true
            val.minimumScaleFactor = 0.6
            let col = UIStackView(arrangedSubviews: [cap, val])
            col.axis = .vertical
            col.spacing = 1
            col.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 7),
                col.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
                col.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -10),
                col.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -7),
            ])
            return (wrap, val)
        }
        let (memChip, memVal) = makeChip("APP MEM")
        let (freeChip, freeVal) = makeChip("OS FREE")
        let (fpsChip, fpsVal) = makeChip("FPS")
        heroMemValue = memVal
        heroFreeValue = freeVal
        heroFPSValue = fpsVal
        let chipsRow = UIStackView(arrangedSubviews: [memChip, freeChip, fpsChip])
        chipsRow.axis = .horizontal
        chipsRow.spacing = 8
        chipsRow.distribution = .fillEqually
        chipsRow.translatesAutoresizingMaskIntoConstraints = false

        // ── Quick actions ─────────────────────────────────────────────
        func makeQuick(_ title: String, _ symbol: String, _ action: Selector) -> UIButton {
            let b = UIButton(type: .system)
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
            cfg.imagePlacement = .top
            cfg.imagePadding = 4
            var attr = AttributeContainer()
            attr.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
            cfg.attributedTitle = AttributedString(title, attributes: attr)
            cfg.baseForegroundColor = Self.actionTint
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 2, bottom: 8, trailing: 2)
            b.configuration = cfg
            b.backgroundColor = Self.actionTint.withAlphaComponent(0.07)
            b.layer.cornerRadius = 10
            b.layer.cornerCurve = .continuous
            b.layer.borderWidth = 1
            b.layer.borderColor = Self.actionTint.withAlphaComponent(0.20).cgColor
            b.addTarget(self, action: action, for: .touchUpInside)
            return b
        }
        let actionsRow = UIStackView(arrangedSubviews: [
            makeQuick("Games", "gamecontroller.fill", #selector(quickOpenGames)),
            makeQuick("QR code", "qrcode", #selector(quickOpenQR)),
            makeQuick("Smoke test", "checklist", #selector(quickSmokeTest)),
            makeQuick("Perf HUD", "gauge.with.needle", #selector(quickToggleHUD)),
        ])
        actionsRow.axis = .horizontal
        actionsRow.spacing = 8
        actionsRow.distribution = .fillEqually
        actionsRow.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(icon)
        card.addSubview(textCol)
        card.addSubview(chipsRow)
        card.addSubview(actionsRow)
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

            chipsRow.topAnchor.constraint(equalTo: textCol.bottomAnchor, constant: 14),
            chipsRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            chipsRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            actionsRow.topAnchor.constraint(equalTo: chipsRow.bottomAnchor, constant: 10),
            actionsRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            actionsRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            actionsRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        refreshHeroChips()
        return container
    }

    private func refreshHeroChips() {
        heroMemValue?.text = Self.formatBytes(Self.physFootprint())
        heroFreeValue?.text = Self.formatBytes(Self.osAvailable())
        heroFPSValue?.text = liveFPS > 0 ? String(format: "%.0f", liveFPS) : "—"
    }

    // Quick-action handlers (mirror the equivalent table rows).
    @objc private func quickOpenGames() {
        let nav = UINavigationController(rootViewController: HiddenGamesLauncher())
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
    @objc private func quickOpenQR() { presentQRGenerator() }
    @objc private func quickSmokeTest() {
        runPython(
            "import importlib, time\n" +
            "mods=['numpy','scipy','pandas','statsmodels','sympy','networkx','matplotlib','PIL','sklearn','shapely','pint','uncertainties','qrcode']\n" +
            "ok=[]; bad=[]\n" +
            "for m in mods:\n" +
            "    try:\n" +
            "        t=time.time(); importlib.import_module(m); ok.append('  + %s (%.0f ms)' % (m,(time.time()-t)*1000))\n" +
            "    except Exception as e:\n" +
            "        bad.append('  x %s: %s: %s' % (m, type(e).__name__, e))\n" +
            "print('PASS %d/%d' % (len(ok), len(mods)))\n" +
            "print('\\n'.join(ok))\n" +
            "print('\\nFAIL:\\n'+'\\n'.join(bad) if bad else '\\nall core libraries import cleanly')",
            title: "Smoke test")
    }
    @objc private func quickToggleHUD() {
        guard let host = SecretFeatures.keyHostView() else { return }
        PerformanceHUD.shared.toggle(in: host)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate(); refreshTimer = nil
        fpsLink?.invalidate(); fpsLink = nil
    }

    @objc private func close()  { dismiss(animated: true) }
    @objc private func reload() { buildSections(); table.reloadData() }

    /// Present the native QR-code generator (CoreImage CIQRCodeGenerator —
    /// instant, no Python round-trip). The bundled pure-Python `qrcode` lib
    /// stays available for use inside scripts.
    fileprivate func presentQRGenerator() {
        let nav = UINavigationController(rootViewController: QRGeneratorViewController())
        nav.modalPresentationStyle = .formSheet
        nav.navigationBar.tintColor = Self.actionTint
        present(nav, animated: true)
    }

    // MARK: - Section builder

    private func buildSections() {
        let info = Bundle.main.infoDictionary ?? [:]
        sections = [
            // ── App identity ──────────────────────────────────────
            Section(title: "App", icon: "info.circle", rows: [
                .info(key: "Version",   value: { (info["CFBundleShortVersionString"] as? String) ?? "?" }),
                .info(key: "Build",     value: { (info["CFBundleVersion"] as? String) ?? "?" }),
                .info(key: "Bundle id", value: { Bundle.main.bundleIdentifier ?? "?" }),
                .info(key: "Device",    value: { "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)" }),
                .info(key: "Locale",    value: { Locale.current.identifier }),
                .info(key: "Thermal",   value: { Self.thermalString() }),
                .info(key: "Low power", value: { ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "off" }),
                .info(key: "Free disk", value: { Self.formatBytes(Self.freeDiskBytes()) }),
            ]),

            // ── Tools ─────────────────────────────────────────────
            Section(title: "Tools", icon: "qrcode", rows: [
                .action(title: "QR Code Generator",
                        subtitle: "URL or word list → scannable QR images you can save") { vc in
                    vc.presentQRGenerator()
                },
            ]),

            // ── Live memory ───────────────────────────────────────
            Section(title: "Memory (live)", icon: "memorychip", rows: [
                .info(key: "phys_footprint", value: { Self.formatBytes(Self.physFootprint()) }),
                .info(key: "resident_size",  value: { Self.formatBytes(Self.residentSize()) }),
                .info(key: "available",      value: { Self.formatBytes(Self.osAvailable()) }),
                .info(key: "device RAM",     value: { Self.formatBytes(Int(ProcessInfo.processInfo.physicalMemory)) }),
                .info(key: "uptime (panel)", value: { [weak self] in
                    guard let self else { return "—" }
                    return Self.formatDuration(ProcessInfo.processInfo.systemUptime - self.launchUptime)
                }),
                .info(key: "FPS (display)", value: { [weak self] in
                    guard let self else { return "—" }
                    return self.liveFPS > 0 ? String(format: "%.0f fps", self.liveFPS) : "—"
                }),
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
            Section(title: "Python", icon: "chevron.left.forwardslash.chevron.right", rows: [
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
                        subtitle: "Close figures, flush plotly / torch / tqdm caches, force GC") { vc in
                    vc.runPython("import offlinai_shell; offlinai_shell._post_script_cleanup(); print('cleanup complete')",
                                 title: "Reset manim / pyav")
                },
                .action(title: "Run import smoke test",
                        subtitle: "Import the core bundled libraries and report pass / fail") { vc in
                    vc.runPython(
                        "import importlib, time\n" +
                        "mods=['numpy','scipy','pandas','statsmodels','sympy','networkx','matplotlib','PIL','sklearn','shapely','pint','uncertainties','qrcode']\n" +
                        "ok=[]; bad=[]\n" +
                        "for m in mods:\n" +
                        "    try:\n" +
                        "        t=time.time(); importlib.import_module(m); ok.append('  + %s (%.0f ms)' % (m,(time.time()-t)*1000))\n" +
                        "    except Exception as e:\n" +
                        "        bad.append('  x %s: %s: %s' % (m, type(e).__name__, e))\n" +
                        "print('PASS %d/%d' % (len(ok), len(mods)))\n" +
                        "print('\\n'.join(ok))\n" +
                        "print('\\nFAIL:\\n'+'\\n'.join(bad) if bad else '\\nall core libraries import cleanly')",
                        title: "Smoke test")
                },
            ]),

            // ── Visual extras (direct toggles) ─────────────────────
            Section(title: "Visual extras", icon: "paintbrush", rows: [
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
                .toggle(title: "Performance HUD",
                        getter: { !PerformanceHUD.shared.isHidden },
                        setter: { on in
                            // Route through the existing toggle(in:) so the
                            // display-link start/stop logic still runs. Only
                            // act when the desired state differs from current.
                            guard let host = SecretFeatures.keyHostView() else { return }
                            let currentlyShown = !PerformanceHUD.shared.isHidden
                            if on != currentlyShown { PerformanceHUD.shared.toggle(in: host) }
                        }),
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
            Section(title: "State", icon: "internaldrive", rows: [
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
                .action(title: "Copy diagnostics",
                        subtitle: "App + memory + Python summary → clipboard") { vc in
                    let info = Bundle.main.infoDictionary ?? [:]
                    let lines = [
                        "CodeBench diagnostics",
                        "version      \((info["CFBundleShortVersionString"] as? String) ?? "?") (\((info["CFBundleVersion"] as? String) ?? "?"))",
                        "bundle id    \(Bundle.main.bundleIdentifier ?? "?")",
                        "device       \(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)",
                        "thermal      \(Self.thermalString())",
                        "low power    \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "off")",
                        "phys_foot    \(Self.formatBytes(Self.physFootprint()))",
                        "resident     \(Self.formatBytes(Self.residentSize()))",
                        "available    \(Self.formatBytes(Self.osAvailable()))",
                        "device RAM   \(Self.formatBytes(Int(ProcessInfo.processInfo.physicalMemory)))",
                        "free disk    \(Self.formatBytes(Self.freeDiskBytes()))",
                        "python       \(Self.pythonVersion())",
                        "fps          \(vc.liveFPS > 0 ? String(format: "%.0f", vc.liveFPS) : "—")",
                    ]
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                    vc.toast("diagnostics copied")
                },
            ]),

            // ── Webview / pywebview ───────────────────────────────
            Section(title: "Webview", icon: "globe", rows: [
                // When ON, pywebview WKWebViews use an ephemeral data
                // store (.nonPersistent()) → every page loads fresh, the
                // disk cache is never read or written. The existing
                // persistent cache is left intact, so turning this OFF
                // again transparently reuses it. Applies to the next
                // pywebview window / page load.
                .toggle(title: "pywebview: no cache",
                        getter: { PywebviewBridge.disableCache },
                        setter: { UserDefaults.standard.set($0, forKey: PywebviewBridge.disableCacheKey) }),
            ]),

            // ── Easter eggs (direct triggers) ─────────────────────
            Section(title: "Easter eggs (direct)", icon: "gift", rows: [
                .action(title: "Open Hidden Games",
                        subtitle: "6 games: 2048 · Mines · Sokoban · Codle · Lights Out · Slide 15") { vc in
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

    /// Run Python and show its captured stdout/stderr in a sheet. The dev
    /// panel is presented over the terminal, so surfacing the output here is
    /// the only way the user actually sees what a button did (the old
    /// fire-and-forget path discarded it).
    fileprivate func runPython(_ code: String, title: String = "Output") {
        let nav = UINavigationController(
            rootViewController: PythonOutputViewController(title: title, runningCode: code))
        nav.modalPresentationStyle = .pageSheet
        nav.navigationBar.tintColor = Self.actionTint
        present(nav, animated: true)
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

    private static func thermalString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }
    private static func freeDiskBytes() -> Int {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let v = try? url?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = v.volumeAvailableCapacityForImportantUsage {
            return Int(cap)
        }
        return 0
    }
    private static func formatDuration(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec)s"
    }

    // MARK: - UITableView

    private static let fg = UIColor(red: 0.941, green: 0.941, blue: 0.961, alpha: 1.0)
    private static let muted = UIColor(red: 0.420, green: 0.420, blue: 0.502, alpha: 1.0)
    private static let actionTint = UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 1.0) // violet
    private static let monoVal = UIColor(red: 0.776, green: 0.788, blue: 1.0, alpha: 1.0)       // soft indigo
    private static let cardBg = UIColor(red: 0.071, green: 0.071, blue: 0.102, alpha: 1.0)
    private static let gaugeWarn = UIColor(red: 0.984, green: 0.749, blue: 0.141, alpha: 1.0) // amber #fbbf24
    private static let gaugeCrit = UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1.0) // red   #ef4444
    private static let okGreen   = UIColor(red: 0.20,  green: 0.83,  blue: 0.60,  alpha: 1.0)  // #34d399 (matches toggle ON)

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
        // Optional leading SF Symbol, tinted to the violet accent. Falls
        // back to the original flush-left label layout when icon == nil,
        // so the look is unchanged for any section without an icon.
        if let symbol = sections[s].icon,
           let img = UIImage(systemName: symbol,
               withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)) {
            let iv = UIImageView(image: img)
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.tintColor = Self.actionTint.withAlphaComponent(0.85)
            iv.contentMode = .scaleAspectFit
            iv.setContentHuggingPriority(.required, for: .horizontal)
            container.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
                iv.firstBaselineAnchor.constraint(equalTo: lbl.firstBaselineAnchor),
                iv.widthAnchor.constraint(equalToConstant: 15),
                lbl.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 7),
                lbl.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
                lbl.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            ])
        } else {
            NSLayoutConstraint.activate([
                lbl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
                lbl.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
                lbl.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            ])
        }
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

// MARK: - QR Code generator

/// Type a URL or text — one entry per line for a batch — generate scannable
/// QR images, and save / share them. Uses CoreImage's `CIQRCodeGenerator`, so
/// it's instant and needs no Python round-trip. (A pure-Python `qrcode` lib is
/// also bundled for use inside scripts.)
final class QRGeneratorViewController: UIViewController, UITextViewDelegate {

    private let bg     = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1.0)
    private let cardBg = UIColor(red: 0.071, green: 0.071, blue: 0.102, alpha: 1.0)
    private let fg     = UIColor(red: 0.941, green: 0.941, blue: 0.961, alpha: 1.0)
    private let muted  = UIColor(red: 0.420, green: 0.420, blue: 0.502, alpha: 1.0)
    private let accent = UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 1.0)

    private let input        = UITextView()
    private let placeholder  = UILabel()
    private let resultsStack  = UIStackView()
    private var generated: [(text: String, image: UIImage)] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        title = "QR Generator"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .action, target: self, action: #selector(shareAll))
        navigationItem.rightBarButtonItem?.isEnabled = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)

        let content = UIStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.spacing = 16
        content.isLayoutMarginsRelativeArrangement = true
        content.layoutMargins = UIEdgeInsets(top: 20, left: 20, bottom: 40, right: 20)
        scroll.addSubview(content)

        // Input card.
        let inputCard = UIView()
        inputCard.translatesAutoresizingMaskIntoConstraints = false
        inputCard.backgroundColor = cardBg
        inputCard.layer.cornerRadius = 14
        inputCard.layer.cornerCurve = .continuous

        input.translatesAutoresizingMaskIntoConstraints = false
        input.backgroundColor = .clear
        input.textColor = fg
        input.tintColor = accent
        input.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        input.autocapitalizationType = .none
        input.autocorrectionType = .no
        input.delegate = self
        inputCard.addSubview(input)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = "Enter a URL or text.\nPut one per line to make several QR codes."
        placeholder.numberOfLines = 0
        placeholder.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        placeholder.textColor = muted
        inputCard.addSubview(placeholder)

        // Generate button.
        let genButton = UIButton(type: .system)
        genButton.translatesAutoresizingMaskIntoConstraints = false
        var bc = UIButton.Configuration.filled()
        bc.title = "Generate"
        bc.baseBackgroundColor = accent
        bc.baseForegroundColor = .white
        bc.cornerStyle = .large
        bc.buttonSize = .large
        genButton.configuration = bc
        genButton.addTarget(self, action: #selector(generate), for: .touchUpInside)

        resultsStack.axis = .vertical
        resultsStack.spacing = 16

        content.addArrangedSubview(inputCard)
        content.addArrangedSubview(genButton)
        content.addArrangedSubview(resultsStack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),

            input.topAnchor.constraint(equalTo: inputCard.topAnchor, constant: 12),
            input.leadingAnchor.constraint(equalTo: inputCard.leadingAnchor, constant: 12),
            input.trailingAnchor.constraint(equalTo: inputCard.trailingAnchor, constant: -12),
            input.bottomAnchor.constraint(equalTo: inputCard.bottomAnchor, constant: -12),
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),

            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 8),
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 5),
            placeholder.trailingAnchor.constraint(equalTo: input.trailingAnchor, constant: -5),
        ])
    }

    @objc private func done() { view.endEditing(true); dismiss(animated: true) }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
    }

    @objc private func generate() {
        view.endEditing(true)
        let lines = (input.text ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        generated = Array(lines.prefix(50)).compactMap { t in
            Self.makeQRImage(t).map { (text: t, image: $0) }
        }
        renderResults()
        navigationItem.rightBarButtonItem?.isEnabled = generated.count > 1
    }

    private func renderResults() {
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !generated.isEmpty else {
            let empty = UILabel()
            empty.text = "Nothing to encode yet."
            empty.textColor = muted
            empty.font = .systemFont(ofSize: 13)
            empty.textAlignment = .center
            resultsStack.addArrangedSubview(empty)
            return
        }
        for (idx, item) in generated.enumerated() {
            resultsStack.addArrangedSubview(makeResultCard(text: item.text, image: item.image, index: idx))
        }
    }

    private func makeResultCard(text: String, image: UIImage, index: Int) -> UIView {
        let card = UIView()
        card.backgroundColor = cardBg
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous

        let imgView = UIImageView(image: image)
        imgView.translatesAutoresizingMaskIntoConstraints = false
        imgView.contentMode = .scaleAspectFit
        imgView.backgroundColor = .white
        imgView.layer.cornerRadius = 8
        imgView.clipsToBounds = true

        let caption = UILabel()
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.text = text
        caption.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        caption.textColor = muted
        caption.numberOfLines = 2
        caption.lineBreakMode = .byTruncatingMiddle
        caption.textAlignment = .center

        let save = UIButton(type: .system)
        save.translatesAutoresizingMaskIntoConstraints = false
        var sc = UIButton.Configuration.tinted()
        sc.title = "Save / Share"
        sc.image = UIImage(systemName: "square.and.arrow.up")
        sc.imagePadding = 6
        sc.baseForegroundColor = accent
        sc.baseBackgroundColor = accent
        save.configuration = sc
        save.tag = index
        save.addTarget(self, action: #selector(shareOne(_:)), for: .touchUpInside)

        let col = UIStackView(arrangedSubviews: [imgView, caption, save])
        col.translatesAutoresizingMaskIntoConstraints = false
        col.axis = .vertical
        col.spacing = 12
        col.alignment = .center
        col.isLayoutMarginsRelativeArrangement = true
        col.layoutMargins = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        card.addSubview(col)

        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: card.topAnchor),
            col.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            col.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            imgView.widthAnchor.constraint(equalToConstant: 220),
            imgView.heightAnchor.constraint(equalToConstant: 220),
            caption.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -36),
        ])
        return card
    }

    @objc private func shareOne(_ sender: UIButton) {
        guard sender.tag < generated.count else { return }
        presentShare(images: [generated[sender.tag].image], source: sender)
    }

    @objc private func shareAll() {
        guard !generated.isEmpty else { return }
        presentShare(images: generated.map { $0.image }, source: navigationItem.rightBarButtonItem)
    }

    private func presentShare(images: [UIImage], source: Any?) {
        let av = UIActivityViewController(activityItems: images, applicationActivities: nil)
        // iPad requires a popover anchor or this traps.
        if let bar = source as? UIBarButtonItem {
            av.popoverPresentationController?.barButtonItem = bar
        } else if let v = source as? UIView {
            av.popoverPresentationController?.sourceView = v
            av.popoverPresentationController?.sourceRect = v.bounds
        }
        present(av, animated: true)
    }

    /// Black-on-white QR with a quiet-zone margin so it scans reliably even
    /// against the panel's dark chrome. Scaled at the CIImage stage and drawn
    /// upright (no mirror) so it stays crisp.
    static func makeQRImage(_ text: String, side: CGFloat = 660, margin: CGFloat = 28) -> UIImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage, ci.extent.width > 0 else { return nil }
        let scale = (side - 2 * margin) / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        let qr = UIImage(cgImage: cg)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { rctx in
            UIColor.white.setFill()
            rctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            rctx.cgContext.interpolationQuality = .none
            qr.draw(in: CGRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin))
        }
    }
}

// MARK: - Python output sheet

/// Shows captured Python stdout/stderr (or any ready-made text) in a
/// scrollable sheet. The dev panel is presented modally over the terminal, so
/// output the fire-and-forget path would discard is surfaced here instead.
final class PythonOutputViewController: UIViewController {

    private let textView = UITextView()
    private let spinner  = UIActivityIndicatorView(style: .medium)
    private let runningCode: String?
    private let initialText: String?

    init(title: String, runningCode: String? = nil, showingText: String? = nil) {
        self.runningCode = runningCode
        self.initialText = showingText
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1.0)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(closeSheet))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .action, target: self, action: #selector(shareOutput))

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.textColor = UIColor(red: 0.776, green: 0.788, blue: 1.0, alpha: 1.0)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
        view.addSubview(textView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        if let t = initialText {
            textView.text = t
            navigationItem.rightBarButtonItem?.isEnabled = !t.isEmpty
        } else if let code = runningCode {
            navigationItem.rightBarButtonItem?.isEnabled = false
            spinner.startAnimating()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = PythonRuntime.shared.execute(code: code)
                let out = result.output.isEmpty ? "(no output)" : result.output
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.spinner.stopAnimating()
                    self.textView.text = out
                    self.navigationItem.rightBarButtonItem?.isEnabled = true
                }
            }
        } else {
            textView.text = "(no output)"
        }
    }

    @objc private func closeSheet() { dismiss(animated: true) }
    @objc private func shareOutput() {
        let av = UIActivityViewController(activityItems: [textView.text ?? ""], applicationActivities: nil)
        av.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(av, animated: true)
    }
}
