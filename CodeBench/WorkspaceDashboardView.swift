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
        // Quick actions
        case runLast, newPyFile
    }

    weak var delegate: WorkspaceDashboardDelegate?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let heroView = HeroView()
    private let quickActionsRow = QuickActionsRow()
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
        quickActionsRow.onSelect = { [weak self] in self?.fire($0) }
        recentSection.onSelect   = { [weak self] in self?.fire(.recentFile($0)) }
        toolsGrid.onSelect       = { [weak self] in self?.fire($0) }

        contentStack.addArrangedSubview(heroView)
        contentStack.setCustomSpacing(20, after: heroView)
        contentStack.addArrangedSubview(quickActionsRow)
        contentStack.addArrangedSubview(recentSection)
        contentStack.addArrangedSubview(toolsGrid)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 28),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -28),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -28),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -56),
        ])
    }

    private var bgGradient: CAGradientLayer?
    override func layoutSubviews() {
        super.layoutSubviews()
        bgGradient?.frame = bounds
    }

    private func fire(_ action: Action) {
        // Subtle haptic so card taps feel responsive even before the
        // dashboard fades out.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        delegate?.dashboardDidSelect(action)
    }

    // MARK: - Public API

    func setRecentFiles(_ files: [URL]) {
        recentFiles = Array(files.prefix(8))
        recentSection.setFiles(recentFiles)
        recentSection.isHidden = recentFiles.isEmpty
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
        backgroundColor = .clear

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
            railView.topAnchor.constraint(equalTo: topAnchor),
            railView.bottomAnchor.constraint(equalTo: bottomAnchor),
            railView.leadingAnchor.constraint(equalTo: leadingAnchor),
            railView.widthAnchor.constraint(equalToConstant: 4),

            title.topAnchor.constraint(equalTo: topAnchor),
            title.leadingAnchor.constraint(equalTo: railView.trailingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            pillRow.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            pillRow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            pillRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            pillRow.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        railGradient.frame = railView.bounds
    }

    func setStats(python: String, gpu: String, ram: String) {
        pythonPill.setText(python)
        gpuPill.setText(gpu)
        ramPill.setText(ram)
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

// MARK: - QuickActionsRow

/// Three wide pill-buttons for the most common one-tap actions:
/// Run Last, New File, AI Chat. Visually distinct from the smaller
/// tool cards below — these are LARGER and read as "main verbs."
///
/// Editor is intentionally NOT here — it's the largest card in the
/// tools grid right below, and showing both was a duplication users
/// noticed. Three is also a better fit at iPhone-compact widths.
private final class QuickActionsRow: UIView {

    var onSelect: ((WorkspaceDashboardView.Action) -> Void)?

    private let actions: [(title: String, icon: String, tint: UIColor, action: WorkspaceDashboardView.Action)] = [
        ("Run Last",   "play.fill",
         UIColor(red: 0.32, green: 0.83, blue: 0.45, alpha: 1), .runLast),
        ("New File",   "plus.app.fill",
         UIColor(red: 0.95, green: 0.78, blue: 0.35, alpha: 1), .newPyFile),
        ("AI Chat",    "sparkles",
         UIColor(red: 0.78, green: 0.62, blue: 0.99, alpha: 1), .aiChat),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let header = SectionHeader(title: "Quick actions",
                                    accent: UIColor(red: 0.32, green: 0.83, blue: 0.45, alpha: 1))
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let row = UIStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 10
        addSubview(row)

        for (i, a) in actions.enumerated() {
            let btn = QuickActionButton(title: a.title, icon: a.icon, tint: a.tint)
            btn.tag = i
            btn.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
            row.addArrangedSubview(btn)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 18),

            row.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.heightAnchor.constraint(equalToConstant: 66),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func tap(_ sender: UIButton) {
        onSelect?(actions[sender.tag].action)
    }
}

// MARK: - QuickActionButton

private final class QuickActionButton: UIControl {

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let bgLayer = CAGradientLayer()
    private let glowLayer = CAGradientLayer()
    private let tint: UIColor

    init(title: String, icon: String, tint: UIColor) {
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = tint.withAlphaComponent(0.35).cgColor
        clipsToBounds = true

        // Inner gradient — subtle tint, brighter at top, fades down
        bgLayer.colors = [
            tint.withAlphaComponent(0.22).cgColor,
            tint.withAlphaComponent(0.08).cgColor,
        ]
        bgLayer.startPoint = CGPoint(x: 0.2, y: 0)
        bgLayer.endPoint   = CGPoint(x: 0.8, y: 1)
        layer.insertSublayer(bgLayer, at: 0)

        // Glow accent in upper-left corner — adds depth, makes the
        // button feel more premium than a flat-color fill.
        glowLayer.colors = [
            tint.withAlphaComponent(0.45).cgColor,
            UIColor.clear.cgColor,
        ]
        glowLayer.startPoint = CGPoint(x: 0, y: 0)
        glowLayer.endPoint   = CGPoint(x: 0.65, y: 0.65)
        glowLayer.opacity = 0.8
        layer.insertSublayer(glowLayer, at: 1)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: icon)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        iconView.tintColor = tint
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .bold).rounded
        titleLabel.textColor = UIColor(white: 0.97, alpha: 1)
        titleLabel.textAlignment = .left
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        bgLayer.frame = bounds
        let glowSize = max(bounds.width, bounds.height) * 0.65
        glowLayer.frame = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12,
                           delay: 0,
                           usingSpringWithDamping: 0.6,
                           initialSpringVelocity: 0.8,
                           options: [.allowUserInteraction],
                           animations: {
                self.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: 0.96, y: 0.96)
                    : .identity
                self.alpha = self.isHighlighted ? 0.85 : 1
            })
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
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.22, alpha: 1).cgColor
        backgroundColor = UIColor(white: 0.10, alpha: 1)

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
            layer.borderWidth = 1
            layer.borderColor = UIColor(white: 0.22, alpha: 1).cgColor
            clipsToBounds = true
            backgroundColor = UIColor(white: 0.10, alpha: 1)

            // Subtle inner top-to-bottom darkening — gives depth
            bgGradient.colors = [
                tool.tint.withAlphaComponent(0.07).cgColor,
                UIColor(white: 0.10, alpha: 1).cgColor,
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
