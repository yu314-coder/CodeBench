import UIKit
import Darwin       // mach_task_self_, task_info, KERN_SUCCESS
import Metal        // MTLCreateSystemDefaultDevice for GPU status pill

/// Workspace Dashboard — premium landing screen that replaces the
/// IDE-clone first impression. Visually layered:
///
///   ┌─ Gradient brand stripe ───────────────────────────────────┐
///   │ Hero ── BenchCode title + stats pills (Python / GPU / RAM)│
///   │                                                           │
///   │ QUICK ACTIONS — 3 wide pill buttons (main verbs)          │
///   │                                                           │
///   │ RECENT — horizontal scroll of file cards                  │
///   │                                                           │
///   │ ALL TOOLS — 2-D grid of 6 category-tinted cards           │
///   └───────────────────────────────────────────────────────────┘
///
/// Button inventory was deliberately pared down (13 → 9): the
/// dashboard used to show Editor and AI Chat in BOTH the Quick
/// Actions row AND the tools grid; Run Last (Quick Actions) and
/// Run Script (tools grid) were the same verb. GPU Lab survives
/// as a feature but is reached from Settings, not the dashboard,
/// since it's a one-off benchmark rather than something users want
/// at first-tap distance.
///
/// The visual identity is intentionally NOT a stock UICollectionView
/// of identical cells (which is exactly what App Store 4.3 reviewers
/// cite as "looks like every other dev tool"). Hero gives the screen
/// a unique anchor, the per-category color system carries through
/// every interactive element, and the typography (heavy rounded
/// titles, letter-spaced section caps, monospaced version pills)
/// reads as a deliberate design language no competitor uses.

protocol WorkspaceDashboardDelegate: AnyObject {
    func dashboardDidSelect(_ action: WorkspaceDashboardView.Action)
}

final class WorkspaceDashboardView: UIView {

    enum Action {
        case editor, files, terminal, aiChat, libraries
        case latex, runScript, gpuLab, settings
        case recentFile(URL)
        // Legacy quick actions (no longer emitted by the dashboard;
        // cases kept so the host's exhaustive switch stays valid).
        case runLast, newPyFile
        // Smart model card: host decides chat / load / download.
        case modelAction
    }

    /// Host-fed state for the AI-model card.
    enum ModelState { case loaded, onDisk, notDownloaded }

    weak var delegate: WorkspaceDashboardDelegate?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let heroView = HeroView()
    private let introCard = IntroCard()
    private let continueCard = ContinueCard()
    private let modelCard = ModelStatusCard()
    private let insightsStrip = InsightsStrip()
    private let systemGraphs = SystemGraphsSection()
    private let recentSection = RecentFilesSection()
    private let toolsGrid = ToolsGrid()

    private var recentFiles: [URL] = []

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        refreshStats()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // Layered background — base dark + subtle top vignette so the
        // hero appears to float. The gradient is much lower contrast
        // than typical CSS-style dashboards, intentional for low-light
        // iPad use at night.
        backgroundColor = UIColor(red: 0.062, green: 0.066, blue: 0.078, alpha: 1)
        let bgGradient = CAGradientLayer()
        bgGradient.colors = [
            UIColor(red: 0.10, green: 0.10, blue: 0.13, alpha: 1).cgColor,
            UIColor(red: 0.062, green: 0.066, blue: 0.078, alpha: 1).cgColor,
        ]
        bgGradient.startPoint = CGPoint(x: 0, y: 0)
        bgGradient.endPoint   = CGPoint(x: 0, y: 0.45)
        layer.addSublayer(bgGradient)
        self.bgGradient = bgGradient

        // ScrollView for everything
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 32, right: 0)
        addSubview(scrollView)

        // Vertical content stack
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 26
        contentStack.alignment = .fill
        scrollView.addSubview(contentStack)

        // Wire delegates to action passthrough
        modelCard.onTap        = { [weak self] in self?.fire(.modelAction) }
        recentSection.onSelect = { [weak self] in self?.fire(.recentFile($0)) }
        toolsGrid.onSelect     = { [weak self] in self?.fire($0) }

        continueCard.onOpen = { [weak self] url in self?.fire(.recentFile(url)) }
        continueCard.isHidden = true   // until real recents arrive

        // One-time introduction — explains what the app IS on first
        // open, then collapses forever once acknowledged.
        introCard.isHidden = UserDefaults.standard.bool(forKey: "dash.introSeen")
        introCard.onDismiss = { [weak self] in
            UserDefaults.standard.set(true, forKey: "dash.introSeen")
            UIView.animate(withDuration: 0.25) {
                self?.introCard.isHidden = true   // stack animates the collapse
                self?.introCard.alpha = 0
            }
        }

        contentStack.addArrangedSubview(heroView)
        contentStack.setCustomSpacing(20, after: heroView)
        contentStack.addArrangedSubview(introCard)
        contentStack.addArrangedSubview(continueCard)
        contentStack.addArrangedSubview(modelCard)
        contentStack.addArrangedSubview(insightsStrip)
        contentStack.addArrangedSubview(systemGraphs)
        contentStack.addArrangedSubview(recentSection)
        contentStack.addArrangedSubview(toolsGrid)

        // Closing signature — quiet trust line under everything.
        let info = Bundle.main.infoDictionary ?? [:]
        let ver = (info["CFBundleShortVersionString"] as? String) ?? "1.0"
        let footer = UILabel()
        footer.text = "BenchCode \(ver) · fully offline · no telemetry"
        footer.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        footer.textColor = UIColor(white: 0.32, alpha: 1)
        footer.textAlignment = .center
        contentStack.addArrangedSubview(footer)
        contentStack.setCustomSpacing(18, after: toolsGrid)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 28),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -28),
        ])
        // Side padding adapts to width: 28pt feels right on iPad but
        // wastes scarce columns on an iPhone — drop to 16pt there.
        padLeading = contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 28)
        padTrailing = contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -28)
        padWidth = contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -56)
        NSLayoutConstraint.activate([padLeading!, padTrailing!, padWidth!])
    }

    private var bgGradient: CAGradientLayer?
    private var padLeading: NSLayoutConstraint?
    private var padTrailing: NSLayoutConstraint?
    private var padWidth: NSLayoutConstraint?
    override func layoutSubviews() {
        super.layoutSubviews()
        bgGradient?.frame = bounds
        // Compact-width tune: tighter side padding + section rhythm.
        let compact = bounds.width < 500
        let pad: CGFloat = compact ? 16 : 28
        if padLeading?.constant != pad {
            padLeading?.constant = pad
            padTrailing?.constant = -pad
            padWidth?.constant = -2 * pad
            contentStack.spacing = compact ? 20 : 26
        }
    }

    private func fire(_ action: Action) {
        // Subtle haptic so card taps feel responsive even before the
        // dashboard fades out.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        delegate?.dashboardDidSelect(action)
    }

    // MARK: - Public API

    /// Host calls these around show/hide so the 1 Hz system sampling
    /// only ever runs while the dashboard is actually on screen.
    func startMetrics() { systemGraphs.start() }
    func pauseMetrics() { systemGraphs.pause() }

    func setModelStatus(name: String, state: ModelState) {
        switch state {
        case .loaded:        modelCard.set(name: name, state: .loaded)
        case .onDisk:        modelCard.set(name: name, state: .onDisk)
        case .notDownloaded: modelCard.set(name: name, state: .notDownloaded)
        }
    }

    func setRecentFiles(_ files: [URL]) {
        recentFiles = Array(files.prefix(8))
        // Most-recent file gets the big "Continue" card; the rest go
        // to the horizontal rail. Both hide when there's nothing real.
        if let first = recentFiles.first {
            continueCard.configure(url: first)
            continueCard.isHidden = false
        } else {
            continueCard.isHidden = true
        }
        let rest = Array(recentFiles.dropFirst())
        recentSection.setFiles(rest)
        recentSection.isHidden = rest.isEmpty
    }

    func refreshStats() {
        // Stats are best-effort. If anything fails, the badge silently
        // shows a placeholder; nothing here should ever break the
        // dashboard rendering.
        heroView.setStats(
            python: pythonVersionString(),
            gpu: gpuStatusString(),
            ram: ramUsageString()
        )
        computeInsights()
    }

    // ── Workspace insights (computed off-main, filled in async) ──────
    private func computeInsights() {
        let ws = AppPaths.workspaceURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            var fileCount = 0
            var totalBytes = 0
            var extCount: [String: Int] = [:]
            if let en = fm.enumerator(at: ws,
                                      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                      options: [.skipsHiddenFiles]) {
                var seen = 0
                for case let url as URL in en {
                    seen += 1
                    if seen > 4000 { break }   // safety cap for huge trees
                    guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          rv.isRegularFile == true else { continue }
                    fileCount += 1
                    totalBytes += rv.fileSize ?? 0
                    let ext = url.pathExtension.lowercased()
                    if !ext.isEmpty { extCount[ext, default: 0] += 1 }
                }
            }
            let topLangs = extCount.sorted { $0.value > $1.value }.prefix(3)
                .map { $0.key }.joined(separator: " · ")
            let free = (try? ws.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
            let freeStr = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            DispatchQueue.main.async {
                self?.insightsStrip.set(files: "\(fileCount)",
                                        size: sizeStr,
                                        langs: topLangs.isEmpty ? "—" : topLangs,
                                        free: freeStr)
            }
        }
    }

    // MARK: - Stat sources

    private func pythonVersionString() -> String {
        // The bundled Python.xcframework ships 3.14 from BeeWare.
        // Hard-coded rather than runtime-probed — querying Python's
        // sys.version requires initializing the embedded interpreter,
        // which the dashboard shouldn't trigger.
        return "Python 3.14"
    }

    private func gpuStatusString() -> String {
        // Metal device existence is a sufficient proxy. Apps that
        // can't create a default device fall back to CPU, which the
        // matmul bridge already handles transparently.
        return MTLCreateSystemDefaultDevice() != nil ? "Metal GPU" : "CPU"
    }

    private func ramUsageString() -> String {
        // Apple's `phys_footprint` matches Xcode's Memory gauge —
        // the same number Apple reviewers see in their dev tools.
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size /
                                            MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return "—" }
        let mb = Double(info.phys_footprint) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - HeroView

/// Top-of-screen hero: workspace name, path, and three live status
/// pills (Python version, GPU device, RAM). The hero spans the full
/// width of the dashboard with a colored side-rail accent that
/// shifts hue down the gradient stack — a unique visual signature.
private final class HeroView: UIView {

    private let railView = UIView()
    private let railGradient = CAGradientLayer()
    private let heroGlow = CAGradientLayer()
    private let greeting = UILabel()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let pythonPill = StatPill()
    private let gpuPill = StatPill()
    private let ramPill = StatPill()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        // Signature hero card — same surface treatment as the Hidden
        // Games launcher and Developer panel heroes (dark card, hairline
        // violet border, radial glow drifting from the top-left), so the
        // first thing the app shows carries the house style instead of
        // bare text floating on the background.
        backgroundColor = UIColor(red: 0.071, green: 0.071, blue: 0.102, alpha: 1)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 0.15).cgColor
        clipsToBounds = true

        heroGlow.type = .radial
        heroGlow.colors = [
            UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 0.22).cgColor,
            UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 0.00).cgColor,
        ]
        heroGlow.locations = [0.0, 1.0]
        heroGlow.startPoint = CGPoint(x: 0.15, y: 0.2)
        heroGlow.endPoint   = CGPoint(x: 0.9, y: 1.4)
        layer.insertSublayer(heroGlow, at: 0)
        // Gentle breathing pulse — animation-only (never touches model
        // opacity), and a single composited layer costs ~nothing.
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.65
        pulse.duration = 3.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        heroGlow.add(pulse, forKey: "heroGlowPulse")

        // Liquid Glass slab under the hero content (the violet glow
        // sits behind the glass and diffuses through it).
        LiquidGlass.apply(to: self, corner: 18, dim: 0.35)

        // Vertical gradient rail running down the left edge — the
        // hero's identifying mark. Same palette as the Libraries
        // category system so the dashboard feels visually unified
        // with the rest of the app.
        railView.translatesAutoresizingMaskIntoConstraints = false
        railView.clipsToBounds = true
        railView.layer.cornerRadius = 2
        railGradient.colors = [
            UIColor(red: 0.69, green: 0.51, blue: 0.95, alpha: 1).cgColor,  // ML purple
            UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1).cgColor,  // Sci blue
            UIColor(red: 0.40, green: 0.80, blue: 0.70, alpha: 1).cgColor,  // Data teal
            UIColor(red: 0.95, green: 0.60, blue: 0.30, alpha: 1).cgColor,  // Viz orange
        ]
        railGradient.startPoint = CGPoint(x: 0.5, y: 0)
        railGradient.endPoint   = CGPoint(x: 0.5, y: 1)
        railView.layer.addSublayer(railGradient)
        addSubview(railView)

        // Time-of-day greeting + date — gives the first-open page a
        // human anchor ("where am I, when is it") above the wordmark.
        greeting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(greeting)
        refreshGreeting()

        // ── Title with subtle letter-spacing for a custom feel ──
        title.translatesAutoresizingMaskIntoConstraints = false
        title.attributedText = NSAttributedString(
            string: "BenchCode",
            attributes: [
                .font: UIFont.systemFont(ofSize: 36, weight: .heavy).rounded,
                .foregroundColor: UIColor(white: 0.97, alpha: 1),
                .kern: -0.5,
            ])
        addSubview(title)

        // Path subtitle, monospaced for tech feel
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = UIColor(white: 0.55, alpha: 1)
        subtitle.text = "~/Documents/Workspace"
        addSubview(subtitle)

        // Stat pills row
        let pillRow = UIStackView(arrangedSubviews: [pythonPill, gpuPill, ramPill])
        pillRow.translatesAutoresizingMaskIntoConstraints = false
        pillRow.axis = .horizontal
        pillRow.spacing = 8
        pillRow.alignment = .center
        addSubview(pillRow)

        // Initial pill content (will get updated via setStats)
        pythonPill.configure(icon: "chevron.left.forwardslash.chevron.right",
                             text: "Python", tint: UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1))
        gpuPill.configure(icon: "memorychip.fill",
                          text: "GPU", tint: UIColor(red: 0.95, green: 0.45, blue: 0.70, alpha: 1))
        ramPill.configure(icon: "circle.grid.cross.fill",
                          text: "RAM", tint: UIColor(red: 0.40, green: 0.80, blue: 0.70, alpha: 1))

        NSLayoutConstraint.activate([
            railView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            railView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            railView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            railView.widthAnchor.constraint(equalToConstant: 4),

            greeting.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            greeting.leadingAnchor.constraint(equalTo: railView.trailingAnchor, constant: 16),
            greeting.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            title.topAnchor.constraint(equalTo: greeting.bottomAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: railView.trailingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            pillRow.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            pillRow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            pillRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            pillRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        railGradient.frame = railView.bounds
        heroGlow.frame = bounds
    }

    func setStats(python: String, gpu: String, ram: String) {
        pythonPill.setText(python)
        gpuPill.setText(gpu)
        ramPill.setText(ram)
        refreshGreeting()   // keep the greeting honest across long sessions
    }

    private func refreshGreeting() {
        let hour = Calendar.current.component(.hour, from: Date())
        let word: String
        switch hour {
        case 5..<12:  word = "GOOD MORNING"
        case 12..<18: word = "GOOD AFTERNOON"
        default:      word = "GOOD EVENING"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM d"
        greeting.attributedText = NSAttributedString(
            string: "\(word) · \(fmt.string(from: Date()).uppercased())",
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor(red: 0.69, green: 0.51, blue: 0.95, alpha: 0.9),
                .kern: 1.2,
            ])
    }
}

// MARK: - StatPill

/// Rounded pill with an SF Symbol icon + label. Used in the hero for
/// at-a-glance status (Python version / GPU device / RAM use).
/// Distinct visually from every other element: rounded ends, glassy
/// fill, hairline outline, tinted icon, white text.
private final class StatPill: UIView {

    private let icon = UIImageView()
    private let label = UILabel()
    private var tint: UIColor = .white

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
        backgroundColor = UIColor(white: 0.12, alpha: 1)

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        addSubview(icon)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = UIColor(white: 0.9, alpha: 1)
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(icon symbol: String, text: String, tint: UIColor) {
        self.tint = tint
        icon.image = UIImage(systemName: symbol)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        icon.tintColor = tint
        label.text = text
        layer.borderColor = tint.withAlphaComponent(0.4).cgColor
        backgroundColor = tint.withAlphaComponent(0.10)
    }

    func setText(_ s: String) { label.text = s }
}

// MARK: - SectionHeader

/// Letter-spaced caps label + colored accent dot — the small heading
/// used above each dashboard section ("QUICK ACTIONS", "RECENT",
/// "ALL TOOLS"). Distinct from stock UITableView headers.
private final class SectionHeader: UIView {

    private let dot = UIView()
    private let label = UILabel()
    private let line = UIView()

    init(title: String, accent: UIColor) {
        super.init(frame: .zero)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = accent
        dot.layer.cornerRadius = 3
        addSubview(dot)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.attributedText = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .heavy),
                .foregroundColor: UIColor(white: 0.55, alpha: 1),
                .kern: 2.0,
            ])
        addSubview(label)

        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = UIColor(white: 0.2, alpha: 1)
        addSubview(line)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: label.centerYAnchor),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),

            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - ModelStatusCard

/// The app's headline state, surfaced on Home: WHICH local LLM is
/// selected and whether it's actually ready. Replaced the old
/// quick-action buttons (redundant next to "Continue") with live
/// status only the home page can show, plus the right next step —
/// CHAT when loaded, LOAD when on disk, GET when not downloaded.
private final class ModelStatusCard: UIView {

    enum State { case loaded, onDisk, notDownloaded }

    var onTap: (() -> Void)?

    private let violet = UIColor(red: 0.78, green: 0.62, blue: 0.99, alpha: 1)
    private let header = SectionHeader(
        title: "AI model",
        accent: UIColor(red: 0.78, green: 0.62, blue: 0.99, alpha: 1))
    private let card = UIControl()
    private let iconBg = UIView()
    private let iconView = UIImageView()
    private let nameLbl = UILabel()
    private let stateDot = UIView()
    private let stateLbl = UILabel()
    private let chip = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = violet.withAlphaComponent(0.22).cgColor
        LiquidGlass.apply(to: card, corner: 16, dim: 0.30)
        card.addTarget(self, action: #selector(fired), for: .touchUpInside)
        card.addTarget(self, action: #selector(pressDown), for: [.touchDown, .touchDragEnter])
        card.addTarget(self, action: #selector(pressUp),
                       for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        addSubview(card)

        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.backgroundColor = violet.withAlphaComponent(0.16)
        iconBg.layer.cornerRadius = 10
        iconBg.layer.borderWidth = 1
        iconBg.layer.borderColor = violet.withAlphaComponent(0.4).cgColor
        iconBg.isUserInteractionEnabled = false
        card.addSubview(iconBg)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "brain.head.profile",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        iconView.tintColor = violet
        iconView.contentMode = .scaleAspectFit
        iconBg.addSubview(iconView)

        nameLbl.translatesAutoresizingMaskIntoConstraints = false
        nameLbl.font = UIFont.systemFont(ofSize: 16, weight: .bold).rounded
        nameLbl.textColor = UIColor(white: 0.97, alpha: 1)
        nameLbl.text = "No model"
        nameLbl.lineBreakMode = .byTruncatingTail
        card.addSubview(nameLbl)

        stateDot.translatesAutoresizingMaskIntoConstraints = false
        stateDot.layer.cornerRadius = 3
        card.addSubview(stateDot)

        stateLbl.translatesAutoresizingMaskIntoConstraints = false
        stateLbl.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        stateLbl.textColor = UIColor(white: 0.5, alpha: 1)
        stateLbl.lineBreakMode = .byTruncatingTail
        card.addSubview(stateLbl)

        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        chip.layer.cornerRadius = 8
        chip.layer.cornerCurve = .continuous
        chip.clipsToBounds = true
        card.addSubview(chip)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 18),

            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.heightAnchor.constraint(equalToConstant: 64),

            iconBg.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconBg.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            iconBg.widthAnchor.constraint(equalToConstant: 36),
            iconBg.heightAnchor.constraint(equalToConstant: 36),
            iconView.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            chip.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chip.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            chip.heightAnchor.constraint(equalToConstant: 22),

            nameLbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
            nameLbl.leadingAnchor.constraint(equalTo: iconBg.trailingAnchor, constant: 12),
            nameLbl.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -10),

            stateDot.widthAnchor.constraint(equalToConstant: 6),
            stateDot.heightAnchor.constraint(equalToConstant: 6),
            stateDot.leadingAnchor.constraint(equalTo: nameLbl.leadingAnchor),
            stateDot.centerYAnchor.constraint(equalTo: stateLbl.centerYAnchor),
            stateLbl.topAnchor.constraint(equalTo: nameLbl.bottomAnchor, constant: 3),
            stateLbl.leadingAnchor.constraint(equalTo: stateDot.trailingAnchor, constant: 5),
            stateLbl.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fired() { onTap?() }
    @objc private func pressDown() {
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction]) {
            self.card.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        }
    }
    @objc private func pressUp() {
        UIView.animate(withDuration: 0.16, delay: 0,
                       usingSpringWithDamping: 0.6, initialSpringVelocity: 0.6,
                       options: [.allowUserInteraction]) { self.card.transform = .identity }
    }

    func set(name: String, state: State) {
        nameLbl.text = name
        let green = UIColor(red: 0.32, green: 0.83, blue: 0.45, alpha: 1)
        let amber = UIColor(red: 0.95, green: 0.78, blue: 0.35, alpha: 1)
        let gray  = UIColor(white: 0.45, alpha: 1)
        switch state {
        case .loaded:
            stateDot.backgroundColor = green
            stateLbl.text = "LOADED · READY"
            chip.text = "  CHAT ▸  "
            chip.textColor = green
            chip.backgroundColor = green.withAlphaComponent(0.12)
        case .onDisk:
            stateDot.backgroundColor = amber
            stateLbl.text = "ON DISK · TAP TO LOAD"
            chip.text = "  LOAD ▸  "
            chip.textColor = amber
            chip.backgroundColor = amber.withAlphaComponent(0.12)
        case .notDownloaded:
            stateDot.backgroundColor = gray
            stateLbl.text = "NOT DOWNLOADED"
            chip.text = "  GET ▸  "
            chip.textColor = violet
            chip.backgroundColor = violet.withAlphaComponent(0.12)
        }
    }
}

// MARK: - RecentFilesSection

/// Horizontal scroll of cards representing recently opened files.
/// Larger / squarer than the tool grid cards so they read as a
/// distinct row. Visible only when there are recents.
private final class RecentFilesSection: UIView {

    var onSelect: ((URL) -> Void)?

    private let header = SectionHeader(
        title: "Recent",
        accent: UIColor(red: 0.40, green: 0.80, blue: 0.70, alpha: 1))
    private let scrollView = UIScrollView()
    private let row = UIStackView()
    private var files: [URL] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        addSubview(scrollView)

        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        scrollView.addSubview(row)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 18),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 84),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            row.topAnchor.constraint(equalTo: scrollView.topAnchor),
            row.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    func setFiles(_ files: [URL]) {
        self.files = files
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for url in files {
            let card = RecentFileCard(url: url)
            card.onTap = { [weak self] in self?.onSelect?(url) }
            row.addArrangedSubview(card)
        }
    }
}

// MARK: - RecentFileCard

private final class RecentFileCard: UIControl {

    var onTap: (() -> Void)?
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 160).isActive = true
        heightAnchor.constraint(equalToConstant: 80).isActive = true
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        LiquidGlass.apply(to: self, corner: 12, dim: 0.30)

        let (sym, tint) = iconAndTint(for: url.pathExtension)

        let iconBg = UIView()
        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.backgroundColor = tint.withAlphaComponent(0.18)
        iconBg.layer.cornerRadius = 7
        addSubview(iconBg)

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIImage(systemName: sym)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit
        iconBg.addSubview(icon)

        let name = UILabel()
        name.translatesAutoresizingMaskIntoConstraints = false
        name.text = url.lastPathComponent
        name.font = UIFont.systemFont(ofSize: 13, weight: .semibold).rounded
        name.textColor = UIColor(white: 0.96, alpha: 1)
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingMiddle
        addSubview(name)

        let path = UILabel()
        path.translatesAutoresizingMaskIntoConstraints = false
        path.text = url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        path.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        path.textColor = UIColor(white: 0.5, alpha: 1)
        path.numberOfLines = 1
        path.lineBreakMode = .byTruncatingMiddle
        addSubview(path)

        NSLayoutConstraint.activate([
            iconBg.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            iconBg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconBg.widthAnchor.constraint(equalToConstant: 26),
            iconBg.heightAnchor.constraint(equalToConstant: 26),
            icon.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.topAnchor.constraint(equalTo: iconBg.bottomAnchor, constant: 8),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.trailingAnchor.constraint(equalTo: name.trailingAnchor),
        ])

        addTarget(self, action: #selector(fired), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fired() { onTap?() }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12,
                           delay: 0,
                           usingSpringWithDamping: 0.6,
                           initialSpringVelocity: 0.8,
                           options: [.allowUserInteraction], animations: {
                self.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
            })
        }
    }

    private func iconAndTint(for ext: String) -> (String, UIColor) {
        switch ext.lowercased() {
        case "py":         return ("chevron.left.forwardslash.chevron.right",
                                   UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1))
        case "tex":        return ("x.squareroot",
                                   UIColor(red: 0.85, green: 0.72, blue: 0.35, alpha: 1))
        case "c", "cpp":   return ("c.square.fill",
                                   UIColor(red: 0.95, green: 0.45, blue: 0.45, alpha: 1))
        case "swift":      return ("swift",
                                   UIColor(red: 0.95, green: 0.60, blue: 0.30, alpha: 1))
        case "md", "txt":  return ("doc.text",
                                   UIColor(white: 0.7, alpha: 1))
        case "json":       return ("curlybraces.square",
                                   UIColor(red: 0.40, green: 0.80, blue: 0.70, alpha: 1))
        default:           return ("doc",
                                   UIColor(white: 0.6, alpha: 1))
        }
    }
}

// MARK: - ToolsGrid

private final class ToolsGrid: UIView {

    var onSelect: ((WorkspaceDashboardView.Action) -> Void)?

    private struct Tool {
        let title: String, subtitle: String, icon: String
        let tint: UIColor, action: WorkspaceDashboardView.Action
    }

    // Trimmed from 9 → 6 cards. Dropped:
    //   • AI Chat   — already in Quick Actions row
    //   • Run Script — same verb as "Run Last" in Quick Actions
    //   • GPU Lab    — specialized one-off (still reachable from
    //                  Settings; doesn't need first-tap real estate)
    private let tools: [Tool] = [
        Tool(title: "Code Editor",
             subtitle: "Monaco · IntelliSense",
             icon: "chevron.left.forwardslash.chevron.right",
             tint: UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1),
             action: .editor),
        Tool(title: "Files",
             subtitle: "Browse workspace",
             icon: "folder.fill",
             tint: UIColor(red: 0.40, green: 0.80, blue: 0.70, alpha: 1),
             action: .files),
        Tool(title: "Python REPL",
             subtitle: "Interactive shell",
             icon: "terminal.fill",
             tint: UIColor(red: 0.55, green: 0.65, blue: 0.95, alpha: 1),
             action: .terminal),
        Tool(title: "Libraries",
             subtitle: "115+ packages",
             icon: "books.vertical.fill",
             tint: UIColor(red: 0.95, green: 0.78, blue: 0.35, alpha: 1),
             action: .libraries),
        Tool(title: "LaTeX",
             subtitle: "Math · documents",
             icon: "x.squareroot",
             tint: UIColor(red: 0.85, green: 0.72, blue: 0.35, alpha: 1),
             action: .latex),
        Tool(title: "Settings",
             subtitle: "Themes · model",
             icon: "gearshape.2.fill",
             tint: UIColor(red: 0.65, green: 0.70, blue: 0.78, alpha: 1),
             action: .settings),
    ]

    private let header = SectionHeader(
        title: "All tools",
        accent: UIColor(red: 0.69, green: 0.51, blue: 0.95, alpha: 1))
    private let grid = UIStackView()  // vertical of rows

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.axis = .vertical
        grid.spacing = 12
        addSubview(grid)

        // Build rows lazily on layout (we don't know width yet)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 18),

            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private var lastColumnCount = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        let cols = optimalColumnCount(width: bounds.width)
        guard cols != lastColumnCount else { return }
        lastColumnCount = cols
        rebuildGrid(columns: cols)
    }

    private func optimalColumnCount(width: CGFloat) -> Int {
        switch width {
        case ..<420:  return 2
        case ..<780:  return 3
        case ..<1080: return 4
        default:      return 5
        }
    }

    private func rebuildGrid(columns: Int) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var i = 0
        while i < tools.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 12
            row.alignment = .fill
            for c in 0..<columns {
                let idx = i + c
                if idx < tools.count {
                    let t = tools[idx]
                    let card = ToolCard(tool: t)
                    card.onTap = { [weak self] in self?.onSelect?(t.action) }
                    row.addArrangedSubview(card)
                } else {
                    // Filler so the last row aligns with the grid
                    let spacer = UIView()
                    spacer.isUserInteractionEnabled = false
                    row.addArrangedSubview(spacer)
                }
            }
            grid.addArrangedSubview(row)
            i += columns
        }
    }

    // ── ToolCard ──
    private final class ToolCard: UIControl {

        var onTap: (() -> Void)?
        private let bgGradient = CAGradientLayer()
        private let cornerGlow = CAGradientLayer()

        init(tool: Tool) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: 116).isActive = true
            layer.cornerRadius = 16
            layer.cornerCurve = .continuous
            layer.borderWidth = 1
            layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
            clipsToBounds = true
            LiquidGlass.apply(to: self, corner: 16, dim: 0.25)

            // Subtle inner top-to-bottom darkening — gives depth. The
            // bottom stop is translucent now so the glass slab above
            // it stays visible instead of being painted out.
            bgGradient.colors = [
                tool.tint.withAlphaComponent(0.07).cgColor,
                UIColor(white: 0.10, alpha: 0.35).cgColor,
            ]
            bgGradient.startPoint = CGPoint(x: 0, y: 0)
            bgGradient.endPoint   = CGPoint(x: 0, y: 0.7)
            layer.insertSublayer(bgGradient, at: 0)

            // Corner glow flourish — top-left, fades into clear
            cornerGlow.colors = [
                tool.tint.withAlphaComponent(0.45).cgColor,
                UIColor.clear.cgColor,
            ]
            cornerGlow.startPoint = CGPoint(x: 0, y: 0)
            cornerGlow.endPoint   = CGPoint(x: 0.7, y: 0.7)
            cornerGlow.opacity = 0.55
            layer.insertSublayer(cornerGlow, at: 1)

            // Icon disc
            let iconBg = UIView()
            iconBg.translatesAutoresizingMaskIntoConstraints = false
            iconBg.backgroundColor = tool.tint.withAlphaComponent(0.22)
            iconBg.layer.cornerRadius = 11
            iconBg.layer.borderColor = tool.tint.withAlphaComponent(0.4).cgColor
            iconBg.layer.borderWidth = 1
            addSubview(iconBg)

            let icon = UIImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.image = UIImage(systemName: tool.icon)?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
            icon.tintColor = tool.tint
            icon.contentMode = .scaleAspectFit
            iconBg.addSubview(icon)

            // Title
            let title = UILabel()
            title.translatesAutoresizingMaskIntoConstraints = false
            title.text = tool.title
            title.font = UIFont.systemFont(ofSize: 16, weight: .bold).rounded
            title.textColor = UIColor(white: 0.97, alpha: 1)
            title.numberOfLines = 1
            addSubview(title)

            // Subtitle
            let subtitle = UILabel()
            subtitle.translatesAutoresizingMaskIntoConstraints = false
            subtitle.text = tool.subtitle
            subtitle.font = .systemFont(ofSize: 12, weight: .medium)
            subtitle.textColor = UIColor(white: 0.55, alpha: 1)
            subtitle.numberOfLines = 1
            subtitle.lineBreakMode = .byTruncatingTail
            addSubview(subtitle)

            // Trailing chevron — subtle navigation cue
            let chev = UIImageView()
            chev.translatesAutoresizingMaskIntoConstraints = false
            chev.image = UIImage(systemName: "arrow.up.forward")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            chev.tintColor = tool.tint.withAlphaComponent(0.7)
            chev.contentMode = .scaleAspectFit
            addSubview(chev)

            NSLayoutConstraint.activate([
                iconBg.topAnchor.constraint(equalTo: topAnchor, constant: 14),
                iconBg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                iconBg.widthAnchor.constraint(equalToConstant: 40),
                iconBg.heightAnchor.constraint(equalToConstant: 40),
                icon.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 22),
                icon.heightAnchor.constraint(equalToConstant: 22),

                chev.topAnchor.constraint(equalTo: topAnchor, constant: 16),
                chev.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                chev.widthAnchor.constraint(equalToConstant: 14),
                chev.heightAnchor.constraint(equalToConstant: 14),

                title.topAnchor.constraint(equalTo: iconBg.bottomAnchor, constant: 12),
                title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

                subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                subtitle.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            ])

            addTarget(self, action: #selector(fired), for: .touchUpInside)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            bgGradient.frame = bounds
            let glowSize = max(bounds.width, bounds.height) * 0.7
            cornerGlow.frame = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
        }

        @objc private func fired() { onTap?() }

        override var isHighlighted: Bool {
            didSet {
                UIView.animate(withDuration: 0.14,
                               delay: 0,
                               usingSpringWithDamping: 0.55,
                               initialSpringVelocity: 0.9,
                               options: [.allowUserInteraction], animations: {
                    self.transform = self.isHighlighted
                        ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
                    self.cornerGlow.opacity = self.isHighlighted ? 0.85 : 0.55
                })
            }
        }
    }
}

// MARK: - ContinueCard

/// "Jump back in" — the most-recently-edited workspace file as a wide,
/// information-dense card: language icon, filename, relative edit time
/// + size, and a dimmed preview of the first lines of code. One tap
/// reopens it in the editor. This (plus the insights strip) is what
/// turns the home page from a button launcher into a real dashboard.
private final class ContinueCard: UIView {

    var onOpen: ((URL) -> Void)?
    private var url: URL?

    private let header = SectionHeader(
        title: "Continue",
        accent: UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1))
    private let card = UIControl()
    private let iconBg = UIView()
    private let iconView = UIImageView()
    private let nameLbl = UILabel()
    private let metaLbl = UILabel()
    private let previewLbl = UILabel()
    private let openChip = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.addTarget(self, action: #selector(fired), for: .touchUpInside)
        LiquidGlass.apply(to: card, corner: 16, dim: 0.30)
        addSubview(card)

        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.layer.cornerRadius = 10
        iconBg.layer.borderWidth = 1
        iconBg.isUserInteractionEnabled = false
        card.addSubview(iconBg)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconBg.addSubview(iconView)

        nameLbl.translatesAutoresizingMaskIntoConstraints = false
        nameLbl.font = UIFont.systemFont(ofSize: 16, weight: .bold).rounded
        nameLbl.textColor = UIColor(white: 0.97, alpha: 1)
        nameLbl.lineBreakMode = .byTruncatingMiddle
        card.addSubview(nameLbl)

        metaLbl.translatesAutoresizingMaskIntoConstraints = false
        metaLbl.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        metaLbl.textColor = UIColor(white: 0.5, alpha: 1)
        card.addSubview(metaLbl)

        previewLbl.translatesAutoresizingMaskIntoConstraints = false
        previewLbl.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        previewLbl.textColor = UIColor(white: 0.45, alpha: 1)
        previewLbl.numberOfLines = 5
        previewLbl.lineBreakMode = .byTruncatingTail
        card.addSubview(previewLbl)

        openChip.translatesAutoresizingMaskIntoConstraints = false
        openChip.text = "  OPEN ▸  "
        openChip.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        openChip.layer.cornerRadius = 8
        openChip.layer.cornerCurve = .continuous
        openChip.clipsToBounds = true
        card.addSubview(openChip)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 18),

            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconBg.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            iconBg.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            iconBg.widthAnchor.constraint(equalToConstant: 36),
            iconBg.heightAnchor.constraint(equalToConstant: 36),
            iconView.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            openChip.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            openChip.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            openChip.heightAnchor.constraint(equalToConstant: 22),

            nameLbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            nameLbl.leadingAnchor.constraint(equalTo: iconBg.trailingAnchor, constant: 12),
            nameLbl.trailingAnchor.constraint(lessThanOrEqualTo: openChip.leadingAnchor, constant: -10),

            metaLbl.topAnchor.constraint(equalTo: nameLbl.bottomAnchor, constant: 2),
            metaLbl.leadingAnchor.constraint(equalTo: nameLbl.leadingAnchor),
            metaLbl.trailingAnchor.constraint(lessThanOrEqualTo: openChip.leadingAnchor, constant: -10),

            previewLbl.topAnchor.constraint(equalTo: iconBg.bottomAnchor, constant: 12),
            previewLbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            previewLbl.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            previewLbl.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])

        // Press feedback on the inner control.
        card.addTarget(self, action: #selector(pressDown), for: [.touchDown, .touchDragEnter])
        card.addTarget(self, action: #selector(pressUp),
                       for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fired() { if let url = url { onOpen?(url) } }
    @objc private func pressDown() {
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction]) {
            self.card.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        }
    }
    @objc private func pressUp() {
        UIView.animate(withDuration: 0.16, delay: 0,
                       usingSpringWithDamping: 0.6, initialSpringVelocity: 0.6,
                       options: [.allowUserInteraction]) { self.card.transform = .identity }
    }

    func configure(url: URL) {
        self.url = url
        let ext = url.pathExtension.lowercased()
        let (sym, tint) = Self.iconAndTint(for: ext)
        iconView.image = UIImage(systemName: sym)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        iconView.tintColor = tint
        iconBg.backgroundColor = tint.withAlphaComponent(0.16)
        iconBg.layer.borderColor = tint.withAlphaComponent(0.4).cgColor
        card.layer.borderColor = tint.withAlphaComponent(0.22).cgColor
        openChip.textColor = tint
        openChip.backgroundColor = tint.withAlphaComponent(0.12)
        nameLbl.text = url.lastPathComponent

        // Meta line: relative edit time + size — the "where was I" facts.
        var metaParts: [String] = []
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let mod = attrs[.modificationDate] as? Date {
                let fmt = RelativeDateTimeFormatter()
                fmt.unitsStyle = .abbreviated
                metaParts.append("EDITED \(fmt.localizedString(for: mod, relativeTo: Date()).uppercased())")
            }
            if let size = attrs[.size] as? Int {
                metaParts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
        }
        metaLbl.text = metaParts.joined(separator: " · ")

        // First lines of code, dimmed — enough context to recognize the
        // work without opening it. Skipped for big or non-text files.
        let previewable: Set<String> = ["py", "c", "cpp", "h", "hpp", "swift", "tex",
                                        "md", "txt", "json", "js", "html", "css", "sh", "f90"]
        var preview = ""
        if previewable.contains(ext),
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size < 262_144,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            preview = text.split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(5)
                .map { $0.replacingOccurrences(of: "\t", with: "  ") }
                .joined(separator: "\n")
        }
        previewLbl.text = preview.isEmpty ? "(no preview)" : preview
    }

    private static func iconAndTint(for ext: String) -> (String, UIColor) {
        switch ext {
        case "py":         return ("chevron.left.forwardslash.chevron.right",
                                   UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1))
        case "tex":        return ("x.squareroot",
                                   UIColor(red: 0.85, green: 0.72, blue: 0.35, alpha: 1))
        case "c", "cpp", "h", "hpp":
                           return ("c.square.fill",
                                   UIColor(red: 0.95, green: 0.45, blue: 0.45, alpha: 1))
        case "swift":      return ("swift",
                                   UIColor(red: 0.95, green: 0.60, blue: 0.30, alpha: 1))
        case "md", "txt":  return ("doc.text",
                                   UIColor(white: 0.7, alpha: 1))
        case "json":       return ("curlybraces.square",
                                   UIColor(red: 0.40, green: 0.80, blue: 0.70, alpha: 1))
        case "ipynb":      return ("book.closed.fill",
                                   UIColor(red: 0.95, green: 0.60, blue: 0.30, alpha: 1))
        default:           return ("doc",
                                   UIColor(white: 0.6, alpha: 1))
        }
    }
}

// MARK: - InsightsStrip

/// Four live facts about the workspace — file count, total size, top
/// languages, free disk — computed off-main by the dashboard and
/// filled in when ready. Answers "what's in here / do I have room"
/// without opening the Files browser or the System tab.
private final class InsightsStrip: UIView {

    private let header = SectionHeader(
        title: "Workspace",
        accent: UIColor(red: 0.95, green: 0.78, blue: 0.35, alpha: 1))
    private var values: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let captions = ["FILES", "SIZE", "LANGUAGES", "FREE DISK"]
        var tiles: [UIView] = []
        for cap in captions {
            let wrap = UIView()
            wrap.layer.cornerRadius = 12
            wrap.layer.cornerCurve = .continuous
            wrap.layer.borderWidth = 1
            wrap.layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
            LiquidGlass.apply(to: wrap, corner: 12, dim: 0.30)
            let capLbl = UILabel()
            capLbl.text = cap
            capLbl.font = .systemFont(ofSize: 9, weight: .heavy)
            capLbl.textColor = UIColor(white: 0.45, alpha: 1)
            let valLbl = UILabel()
            valLbl.text = "—"
            valLbl.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
            valLbl.textColor = UIColor(white: 0.92, alpha: 1)
            valLbl.adjustsFontSizeToFitWidth = true
            valLbl.minimumScaleFactor = 0.55
            values.append(valLbl)
            let col = UIStackView(arrangedSubviews: [capLbl, valLbl])
            col.axis = .vertical
            col.spacing = 2
            col.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(col)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 9),
                col.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 11),
                col.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -11),
                col.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -9),
            ])
            tiles.append(wrap)
        }

        let row = UIStackView(arrangedSubviews: tiles)
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 18),
            row.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(files: String, size: String, langs: String, free: String) {
        guard values.count == 4 else { return }
        values[0].text = files
        values[1].text = size
        values[2].text = langs
        values[3].text = free
    }
}

// MARK: - IntroCard

/// First-open introduction — tells a new user what BenchCode actually
/// IS before they face the tools. Dismisses with "Got it" and never
/// returns (UserDefaults-persisted); existing users who already
/// dismissed it never see it again.
private final class IntroCard: UIView {

    var onDismiss: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 0.30).cgColor
        LiquidGlass.apply(to: self, corner: 16, dim: 0.25)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Welcome to BenchCode 👋"
        title.font = UIFont.systemFont(ofSize: 16, weight: .bold).rounded
        title.textColor = UIColor(white: 0.97, alpha: 1)

        let body = UILabel()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.text = "Your iPad is now a complete offline dev workbench — "
            + "Python 3.14 with 130+ scientific libraries, C / C++ and LaTeX "
            + "toolchains, a real terminal, GPU-accelerated PyTorch, and a "
            + "local AI copilot. Everything runs on-device; nothing ever "
            + "leaves your iPad."
        body.font = .systemFont(ofSize: 12.5, weight: .regular)
        body.textColor = UIColor(white: 0.74, alpha: 1)
        body.numberOfLines = 0

        let dismiss = UIButton(type: .system)
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        dismiss.setTitle("  GOT IT ✓  ", for: .normal)
        dismiss.titleLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        dismiss.setTitleColor(UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1), for: .normal)
        dismiss.backgroundColor = UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 0.12)
        dismiss.layer.cornerRadius = 9
        dismiss.layer.cornerCurve = .continuous
        dismiss.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)

        addSubview(title)
        addSubview(body)
        addSubview(dismiss)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            dismiss.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 10),
            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            dismiss.heightAnchor.constraint(equalToConstant: 26),
            dismiss.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func dismissTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onDismiss?()
    }
}

// MARK: - SystemMetrics

/// REAL kernel counters only — no estimates, no fakes:
/// · CPU  — system-wide busy fraction from `host_processor_info` tick
///          deltas across all cores (the same source `top` reads).
/// · RAM  — active+wired+compressed pages from `host_statistics64`
///          against physical memory.
/// · GPU  — `MTLDevice.currentAllocatedSize`: bytes actually resident
///          on the Apple GPU for this app. iOS has NO public GPU
///          utilization API, so we graph the one genuine live GPU
///          number instead of inventing a percentage.
private final class SystemMetrics {

    static let gpuDevice = MTLCreateSystemDefaultDevice()
    private var prevBusy: UInt64 = 0
    private var prevTotal: UInt64 = 0

    /// 0…1 busy fraction since the previous call (nil on first sample).
    func cpuBusy() -> Double? {
        var numCpus: natural_t = 0
        var info: processor_info_array_t?
        var numInfo: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &numCpus, &info, &numInfo) == KERN_SUCCESS,
              let info = info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(numInfo) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(numCpus) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys  = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        let oldBusy = prevBusy
        let oldTotal = prevTotal
        prevBusy = busy
        prevTotal = total
        guard oldTotal > 0, total > oldTotal, busy >= oldBusy else { return nil }
        let frac = Double(busy - oldBusy) / Double(total - oldTotal)
        return min(1, max(0, frac))
    }

    /// System-wide RAM in use (fraction of physical, plus absolutes).
    func ramUsed() -> (fraction: Double, usedBytes: UInt64, totalBytes: UInt64)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_page_size)
        let used = (UInt64(stats.active_count)
                  + UInt64(stats.wire_count)
                  + UInt64(stats.compressor_page_count)) * page
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return (min(1, Double(used) / Double(total)), used, total)
    }

    /// Bytes currently allocated on the Metal device by this app.
    func gpuAllocatedBytes() -> UInt64? {
        guard let d = Self.gpuDevice else { return nil }
        return UInt64(d.currentAllocatedSize)
    }
}

// MARK: - MetricGraphCard

/// One glass card with a caption, a live value, and a 60-sample
/// sparkline (filled area + stroke). Rendering cost is one small
/// CAShapeLayer path update per second — no display links, no
/// per-frame drawing; CoreAnimation's implicit path animation gives
/// the smooth morph between samples for free.
private final class MetricGraphCard: UIView {

    enum Scale {
        case unit   // values are 0…1 (percentages) — fixed honest scale
        case auto   // arbitrary magnitudes — scale to the window max
    }

    private let scaleMode: Scale
    private let tint: UIColor
    private let valLbl = UILabel()
    private let strokeLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private var samples: [Double] = []
    private let maxSamples = 60

    init(caption: String, tint: UIColor, scale: Scale) {
        self.scaleMode = scale
        self.tint = tint
        super.init(frame: .zero)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
        clipsToBounds = true
        LiquidGlass.apply(to: self, corner: 12, dim: 0.30)
        heightAnchor.constraint(equalToConstant: 84).isActive = true

        fillLayer.fillColor = tint.withAlphaComponent(0.13).cgColor
        fillLayer.strokeColor = nil
        layer.addSublayer(fillLayer)
        strokeLayer.fillColor = nil
        strokeLayer.strokeColor = tint.cgColor
        strokeLayer.lineWidth = 1.5
        strokeLayer.lineJoin = .round
        strokeLayer.lineCap = .round
        layer.addSublayer(strokeLayer)

        let capLbl = UILabel()
        capLbl.text = caption
        capLbl.font = .systemFont(ofSize: 9, weight: .heavy)
        capLbl.textColor = UIColor(white: 0.45, alpha: 1)
        capLbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capLbl)

        valLbl.text = "—"
        valLbl.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        valLbl.textColor = UIColor(white: 0.94, alpha: 1)
        valLbl.adjustsFontSizeToFitWidth = true
        valLbl.minimumScaleFactor = 0.55
        valLbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valLbl)

        NSLayoutConstraint.activate([
            capLbl.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            capLbl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            valLbl.topAnchor.constraint(equalTo: capLbl.bottomAnchor, constant: 1),
            valLbl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            valLbl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -11),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func push(_ raw: Double, display: String) {
        samples.append(max(0, raw))
        if samples.count > maxSamples { samples.removeFirst() }
        valLbl.text = display
        rebuildPath()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildPath()
    }

    private func rebuildPath() {
        guard samples.count >= 2, bounds.width > 20, bounds.height > 50 else {
            strokeLayer.path = nil
            fillLayer.path = nil
            return
        }
        let maxV: Double
        switch scaleMode {
        case .unit: maxV = 1
        case .auto: maxV = max((samples.max() ?? 1) * 1.15, 0.0001)
        }
        let gx = bounds.minX + 8
        let gw = bounds.width - 16
        let gTop: CGFloat = 42
        let gBot = bounds.height - 8
        let gh = gBot - gTop
        let step = gw / CGFloat(maxSamples - 1)

        let stroke = UIBezierPath()
        var firstX: CGFloat = gx
        var lastX: CGFloat = gx
        for (i, s) in samples.enumerated() {
            let x = gx + gw - CGFloat(samples.count - 1 - i) * step
            let y = gBot - CGFloat(min(1, s / maxV)) * gh
            if i == 0 { stroke.move(to: CGPoint(x: x, y: y)); firstX = x }
            else { stroke.addLine(to: CGPoint(x: x, y: y)) }
            lastX = x
        }
        strokeLayer.path = stroke.cgPath

        guard let filled = stroke.copy() as? UIBezierPath else {
            fillLayer.path = nil
            return
        }
        filled.addLine(to: CGPoint(x: lastX, y: gBot))
        filled.addLine(to: CGPoint(x: firstX, y: gBot))
        filled.close()
        fillLayer.path = filled.cgPath
    }
}

// MARK: - SystemGraphsSection

/// CPU · GPU memory · RAM, live. Samples at 1 Hz with timer tolerance
/// (battery-friendly coalescing), ONLY while actually on screen: the
/// host pauses it when Home hides, it pauses itself on app background,
/// and the tick exits early if any ancestor is hidden. Idle cost when
/// not visible: zero.
private final class SystemGraphsSection: UIView {

    private let header = SectionHeader(
        title: "System · live",
        accent: UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1))
    private let cpuCard = MetricGraphCard(
        caption: "CPU",
        tint: UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1), scale: .unit)
    private let gpuCard = MetricGraphCard(
        caption: "GPU MEM",
        tint: UIColor(red: 0.78, green: 0.62, blue: 0.99, alpha: 1), scale: .auto)
    private let ramCard = MetricGraphCard(
        caption: "RAM",
        tint: UIColor(red: 0.40, green: 0.80, blue: 0.70, alpha: 1), scale: .unit)
    private let metrics = SystemMetrics()
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let row = UIStackView(arrangedSubviews: [cpuCard, gpuCard, ramCard])
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 18),
            row.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Background/foreground hygiene — never sample while suspended.
        NotificationCenter.default.addObserver(self, selector: #selector(appPaused),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appResumed),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appPaused() { pause() }
    @objc private func appResumed() { if effectivelyVisible { start() } }

    private var effectivelyVisible: Bool {
        guard window != nil else { return false }
        var v: UIView? = self
        while let cur = v {
            if cur.isHidden { return false }
            v = cur.superview
        }
        return true
    }

    func start() {
        guard timer == nil else { return }
        _ = metrics.cpuBusy()   // prime the tick-delta baseline
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.25      // let the OS coalesce wakeups
        timer = t
        tick()
    }

    func pause() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard effectivelyVisible else { return }
        if let c = metrics.cpuBusy() {
            cpuCard.push(c, display: String(format: "%.0f%%", c * 100))
        }
        if let g = metrics.gpuAllocatedBytes() {
            let mb = Double(g) / 1_048_576
            gpuCard.push(mb, display: mb >= 1024
                ? String(format: "%.2f GB", mb / 1024)
                : String(format: "%.0f MB", mb))
        }
        if let r = metrics.ramUsed() {
            ramCard.push(r.fraction, display: String(
                format: "%.0f%% · %.1f GB", r.fraction * 100,
                Double(r.usedBytes) / 1_073_741_824))
        }
    }
}
