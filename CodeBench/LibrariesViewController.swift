import UIKit

/// Small rounded tile with a diagonal gradient fill, used for library icons.
final class GradientTileView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var grad: CAGradientLayer { layer as! CAGradientLayer }
    func configure(tint: UIColor, corner: CGFloat) {
        grad.colors = [
            tint.withAlphaComponent(0.95).cgColor,
            tint.withAlphaComponent(0.55).cgColor,
        ]
        grad.startPoint = CGPoint(x: 0, y: 0)
        grad.endPoint = CGPoint(x: 1, y: 1)
        grad.cornerRadius = corner
        layer.cornerRadius = corner
        layer.masksToBounds = true
    }
}

/// Inset label used as a pill (version / badge). Replaces the prior
/// detail-view makePill for list use; the detail view keeps its own.
private final class PaddedLabel: UILabel {
    var inset = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
    func configure(font: UIFont) {
        self.font = font
        layer.cornerRadius = 5
        layer.masksToBounds = true
        textAlignment = .center
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    func setColors(text: UIColor, background: UIColor) {
        textColor = text
        backgroundColor = background
    }
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right,
                      height: s.height + inset.top + inset.bottom)
    }
}

/// Rich library card: gradient icon tile, name, version pill, one-line
/// blurb, and an origin badge. Replaces the prior tagged-subview cell.
final class LibraryCardCell: UICollectionViewCell {
    static let reuseID = "LibraryCardCell"

    private let card = UIView()
    private let accent = UIView()
    private var tileHost = UIView()
    private let nameLabel = UILabel()
    private let blurbLabel = UILabel()
    private let versionPill = PaddedLabel()
    private let badgePill = PaddedLabel()
    private let chevron = UIImageView()
    private let textStack: UIStackView

    override init(frame: CGRect) {
        let pillRow = UIStackView(arrangedSubviews: [versionPill, badgePill, UIView()])
        pillRow.axis = .horizontal
        pillRow.spacing = 6
        pillRow.alignment = .center
        textStack = UIStackView(arrangedSubviews: [nameLabel, blurbLabel, pillRow])
        super.init(frame: frame)
        contentView.addSubview(card)
        card.backgroundColor = UIColor(white: 0.12, alpha: 1)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 1, alpha: 0.06).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        accent.layer.cornerRadius = 2
        accent.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(accent)

        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.textColor = UIColor(white: 0.96, alpha: 1)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        blurbLabel.font = .systemFont(ofSize: 12, weight: .regular)
        blurbLabel.textColor = UIColor(white: 0.55, alpha: 1)
        blurbLabel.numberOfLines = 2
        blurbLabel.translatesAutoresizingMaskIntoConstraints = false

        versionPill.configure(font: .monospacedSystemFont(ofSize: 10, weight: .medium))
        badgePill.configure(font: .systemFont(ofSize: 9, weight: .bold))

        chevron.image = UIImage(systemName: "chevron.right")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        chevron.tintColor = UIColor(white: 0.40, alpha: 1)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.alignment = .fill
        textStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(textStack)
        card.addSubview(chevron)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            accent.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            accent.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            accent.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            accent.widthAnchor.constraint(equalToConstant: 4),

            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),

            textStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            textStack.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            // textStack.leading set in configure() relative to the tile
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var tileLeadingConstraint: NSLayoutConstraint?

    func configure(pkg: InstalledLibsViewController.Pkg) {
        let (symbol, tint) = InstalledLibsViewController.iconForPackage(name: pkg.name, origin: pkg.origin)
        accent.backgroundColor = tint

        // Rebuild the gradient tile (cheap; avoids stale-state on reuse).
        tileHost.removeFromSuperview()
        let tile = InstalledLibsViewController.makeIconTile(
            symbol: symbol, tint: tint, side: 40, corner: 11, pointSize: 19)
        tileHost = tile
        card.addSubview(tile)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 12),
            tile.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        // Link text stack to the tile's trailing edge.
        tileLeadingConstraint?.isActive = false
        tileLeadingConstraint = textStack.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12)
        tileLeadingConstraint?.isActive = true

        nameLabel.text = pkg.name
        blurbLabel.text = InstalledLibsViewController.shortBlurb(name: pkg.name, origin: pkg.origin)

        versionPill.text = pkg.version == "-" ? "—" : "v\(pkg.version)"
        let vTint: UIColor = pkg.origin == "User"
            ? UIColor(red: 0.4, green: 0.85, blue: 0.4, alpha: 1)
            : UIColor(white: 0.6, alpha: 1)
        versionPill.setColors(text: vTint, background: vTint.withAlphaComponent(0.14))

        if pkg.origin == "User" {
            badgePill.text = "PIP"
            badgePill.setColors(text: UIColor(white: 0.08, alpha: 1),
                                background: UIColor(red: 0.4, green: 0.85, blue: 0.4, alpha: 1))
        } else {
            badgePill.text = "BUNDLED"
            badgePill.setColors(text: tint, background: tint.withAlphaComponent(0.16))
        }
    }

    override var isHighlighted: Bool {
        didSet { card.alpha = isHighlighted ? 0.6 : 1.0 }
    }
}

/// Bold section header: tinted dot + category name + count.
final class LibrarySectionHeaderView: UICollectionReusableView {
    static let reuseID = "LibrarySectionHeaderView"
    private let dot = UIView()
    private let titleLabel = UILabel()
    private let countLabel = PaddedLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        countLabel.configure(font: .systemFont(ofSize: 11, weight: .semibold))
        addSubview(countLabel)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `title` is the existing Section.title (e.g. "Bundled — Machine Learning  (8)").
    func configure(title: String) {
        let isPip = title.hasPrefix("Pip installed")
        // Re-derive the bare category name exactly as the old header did.
        let catName: String = {
            if isPip { return "Pip installed" }
            var t = title
            if let r = t.range(of: "Bundled — ") { t.removeSubrange(t.startIndex..<r.upperBound) }
            if let r = t.range(of: "  (")        { t = String(t[..<r.lowerBound]) }
            return t
        }()
        let (_, tint) = InstalledLibsViewController.iconForCategory(catName)
        dot.backgroundColor = tint
        // Split "<name>  (N)" into label + count pill.
        if let r = title.range(of: "  (") {
            titleLabel.text = String(title[..<r.lowerBound]).uppercased()
            let n = title[r.upperBound...].dropLast()   // strip ")"
            countLabel.text = String(n)
        } else {
            titleLabel.text = title.uppercased()
            countLabel.text = ""
        }
        titleLabel.textColor = isPip
            ? UIColor(red: 0.4, green: 0.85, blue: 0.4, alpha: 1)
            : UIColor(white: 0.78, alpha: 1)
        countLabel.setColors(text: tint, background: tint.withAlphaComponent(0.16))
    }
}

// ─── Storage donut ──────────────────────────────────────────────────
// An interactive ring chart of per-package disk usage, shown as the
// collection view's global top header. Tap a slice (or a legend row) to
// read that library's size + share and filter the list to it; tap the
// center or the selected slice again to reset.

/// The ring itself + a centered readout. Draws annular sectors with Core
/// Graphics and hit-tests taps by angle/radius.
final class DonutRingView: UIView {
    struct Slice { let fraction: CGFloat; let color: UIColor }
    var slices: [Slice] = [] { didSet { setNeedsDisplay() } }
    var selected: Int? = nil { didSet { setNeedsDisplay() } }
    /// index, or nil for a center/reset tap.
    var onSelectIndex: ((Int?) -> Void)?

    let valueLabel = UILabel()
    let captionLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        valueLabel.font = .systemFont(ofSize: 22, weight: .bold)
        valueLabel.textColor = UIColor(white: 0.97, alpha: 1)
        valueLabel.textAlignment = .center
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        captionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        captionLabel.textColor = UIColor(white: 0.55, alpha: 1)
        captionLabel.textAlignment = .center
        captionLabel.numberOfLines = 2
        for l in [valueLabel, captionLabel] {
            l.translatesAutoresizingMaskIntoConstraints = false
            addSubview(l)
        }
        NSLayoutConstraint.activate([
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            valueLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.52),
            captionLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 2),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.58),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var geom: (outerR: CGFloat, innerR: CGFloat) {
        let side = min(bounds.width, bounds.height)
        let outerR = side / 2 - 4
        return (outerR, outerR * 0.62)
    }

    override func draw(_ rect: CGRect) {
        let cx = bounds.midX, cy = bounds.midY
        let (outerR, innerR) = geom
        // Nothing to draw before the view has a real size (avoids negative
        // radius / NaN into CoreGraphics).
        guard outerR > 2, innerR > 0 else { return }
        let ringR = (outerR + innerR) / 2
        let ringW = outerR - innerR
        // Track ring under everything so a mostly-empty chart still reads.
        let track = UIBezierPath(arcCenter: CGPoint(x: cx, y: cy), radius: ringR,
                                 startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        track.lineWidth = ringW
        UIColor(white: 1, alpha: 0.06).setStroke()
        track.stroke()

        var startFrac: CGFloat = 0
        let gap: CGFloat = slices.count > 1 ? 0.010 : 0
        for (i, s) in slices.enumerated() {
            let a0 = -CGFloat.pi / 2 + 2 * .pi * startFrac
            let a1 = -CGFloat.pi / 2 + 2 * .pi * (startFrac + s.fraction)
            startFrac += s.fraction
            let isSel = selected == i
            let dim = selected != nil && !isSel
            let path = UIBezierPath(arcCenter: CGPoint(x: cx, y: cy),
                                    radius: ringR,
                                    startAngle: a0 + gap,
                                    endAngle: max(a0 + gap, a1 - gap),
                                    clockwise: true)
            path.lineWidth = isSel ? ringW + 7 : ringW
            path.lineCapStyle = .butt
            s.color.withAlphaComponent(dim ? 0.28 : 1).setStroke()
            path.stroke()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self) else { return }
        let dx = p.x - bounds.midX, dy = p.y - bounds.midY
        let dist = hypot(dx, dy)
        let (outerR, innerR) = geom
        guard outerR > 2, innerR > 0, !slices.isEmpty else { return }
        if dist < innerR * 0.92 { onSelectIndex?(nil); return }   // center = reset
        guard dist <= outerR + 10, dist >= innerR - 8 else { return }
        var a = atan2(dy, dx) + .pi / 2
        if a < 0 { a += 2 * .pi }
        let frac = a / (2 * .pi)
        var acc: CGFloat = 0
        for (i, s) in slices.enumerated() {
            if frac >= acc && frac < acc + s.fraction { onSelectIndex?(i); return }
            acc += s.fraction
        }
    }
}

/// The full header: title, the ring, and a two-column tappable legend.
final class StorageDonutHeaderView: UICollectionReusableView {
    static let reuseID = "StorageDonutHeaderView"
    static let kind = "storage-donut-header"

    /// Emits the tapped package name, or nil to reset (center / "Other").
    var onSelect: ((String?) -> Void)?

    private let titleLabel = UILabel()
    private let ring = DonutRingView()
    private let legendColL = UIStackView()
    private let legendColM = UIStackView()
    private let legendColR = UIStackView()
    static let legendCols = 3
    static let legendRowH: CGFloat = 19
    private var segs: [(name: String, bytes: Int64, color: UIColor)] = []
    private var total: Int64 = 0
    private var selected: Int?
    private var rows: [UIControl] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = UIColor(white: 0.55, alpha: 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.onSelectIndex = { [weak self] idx in self?.select(idx) }
        addSubview(ring)

        for col in [legendColL, legendColM, legendColR] {
            col.axis = .vertical
            col.spacing = 3
            col.alignment = .fill
            col.translatesAutoresizingMaskIntoConstraints = false
        }
        let legendRow = UIStackView(arrangedSubviews: [legendColL, legendColM, legendColR])
        legendRow.axis = .horizontal
        legendRow.spacing = 12
        legendRow.distribution = .fillEqually
        legendRow.alignment = .top
        legendRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(legendRow)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),

            ring.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.widthAnchor.constraint(equalToConstant: 158),
            ring.heightAnchor.constraint(equalToConstant: 158),

            legendRow.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 12),
            legendRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            legendRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            legendRow.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    static func sizeString(_ b: Int64) -> String {
        let x = Double(b)
        let gb = 1073741824.0, mb = 1048576.0, kb = 1024.0
        if x >= gb { return String(format: "%.2f GB", x / gb) }
        if x >= mb { return String(format: "%.0f MB", x / mb) }
        if x >= kb { return String(format: "%.0f KB", x / kb) }
        return "\(b) B"
    }

    /// Header height that fits `segmentCount` legend rows in the 3 columns.
    static func heightFor(segmentCount: Int) -> CGFloat {
        let rows = (max(segmentCount, 1) + legendCols - 1) / legendCols
        let legendH = CGFloat(rows) * (legendRowH + 3)   // row + inter-row spacing
        // title(6+16) + gap6 + ring158 + gap12 + legend + bottom10
        return 6 + 16 + 6 + 158 + 12 + legendH + 12
    }

    func configure(segments: [(name: String, bytes: Int64, color: UIColor)],
                   total: Int64, packageCount: Int) {
        self.segs = segments
        self.total = total
        self.selected = nil
        titleLabel.text = "STORAGE · \(Self.sizeString(total)) across \(packageCount) packages"
        let denom = max(total, 1)
        ring.slices = segments.map { .init(fraction: CGFloat(Double($0.bytes) / Double(denom)),
                                           color: $0.color) }
        ring.selected = nil
        buildLegend()
        showTotal()
    }

    private func buildLegend() {
        let cols = [legendColL, legendColM, legendColR]
        for c in cols { c.arrangedSubviews.forEach { $0.removeFromSuperview() } }
        rows = []
        // Fill column-major so packages read top-to-bottom, biggest first.
        let perCol = (segs.count + cols.count - 1) / max(cols.count, 1)
        for (i, s) in segs.enumerated() {
            let row = makeRow(index: i, name: s.name, bytes: s.bytes, color: s.color)
            rows.append(row)
            let colIdx = perCol > 0 ? min(i / perCol, cols.count - 1) : 0
            cols[colIdx].addArrangedSubview(row)
        }
    }

    private func makeRow(index: Int, name: String, bytes: Int64, color: UIColor) -> UIControl {
        let ctl = UIControl()
        ctl.tag = index
        ctl.translatesAutoresizingMaskIntoConstraints = false
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isUserInteractionEnabled = false
        let nameL = UILabel()
        nameL.font = .systemFont(ofSize: 11, weight: .medium)
        nameL.textColor = UIColor(white: 0.82, alpha: 1)
        nameL.text = name
        nameL.lineBreakMode = .byTruncatingTail
        nameL.translatesAutoresizingMaskIntoConstraints = false
        nameL.isUserInteractionEnabled = false
        nameL.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sizeL = UILabel()
        sizeL.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sizeL.textColor = UIColor(white: 0.5, alpha: 1)
        sizeL.text = Self.sizeString(bytes)
        sizeL.setContentHuggingPriority(.required, for: .horizontal)
        sizeL.setContentCompressionResistancePriority(.required, for: .horizontal)
        sizeL.translatesAutoresizingMaskIntoConstraints = false
        sizeL.isUserInteractionEnabled = false
        ctl.addSubview(dot); ctl.addSubview(nameL); ctl.addSubview(sizeL)
        NSLayoutConstraint.activate([
            ctl.heightAnchor.constraint(equalToConstant: Self.legendRowH),
            dot.leadingAnchor.constraint(equalTo: ctl.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: ctl.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            nameL.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            nameL.centerYAnchor.constraint(equalTo: ctl.centerYAnchor),
            sizeL.leadingAnchor.constraint(greaterThanOrEqualTo: nameL.trailingAnchor, constant: 4),
            sizeL.trailingAnchor.constraint(equalTo: ctl.trailingAnchor),
            sizeL.centerYAnchor.constraint(equalTo: ctl.centerYAnchor),
        ])
        ctl.addAction(UIAction { [weak self] _ in self?.select(index) },
                      for: .touchUpInside)
        return ctl
    }

    private func select(_ idx: Int?) {
        // Tapping the already-selected item toggles back to the total.
        let newSel = (idx == selected) ? nil : idx
        selected = newSel
        ring.selected = newSel
        if let i = newSel {
            let s = segs[i]
            let pct = total > 0 ? Int((Double(s.bytes) / Double(total) * 100).rounded()) : 0
            ring.valueLabel.text = Self.sizeString(s.bytes)
            ring.captionLabel.text = "\(s.name)\n\(pct)% of bundle"
            // "Other" is an aggregate — don't filter the list to it.
            onSelect?(s.name.hasPrefix("Other") ? nil : s.name)
        } else {
            showTotal()
            onSelect?(nil)
        }
        for (i, r) in rows.enumerated() {
            let on = (newSel == i)
            r.alpha = (newSel == nil || on) ? 1.0 : 0.45
            if let nameL = r.subviews.compactMap({ $0 as? UILabel }).first {
                nameL.font = .systemFont(ofSize: 12, weight: on ? .bold : .medium)
            }
        }
    }

    private func showTotal() {
        ring.valueLabel.text = Self.sizeString(total)
        ring.captionLabel.text = "total on disk"
    }
}

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

final class InstalledLibsViewController: UIViewController, UICollectionViewDelegate {

    // ── Collection view (replaces the prior insetGrouped UITableView) ──
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    // Header zone
    private let headerContainer = UIView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let searchField = UISearchTextField()
    private let chipScroll = UIScrollView()
    private let chipStack = UIStackView()

    private let emptyLabel = UILabel()
    private let refreshControl = UIRefreshControl()

    // Filter state
    private var searchText = ""
    private var activeCategory: String? = nil   // nil == "All"; else a Section.title

    struct Pkg: Hashable {
        let name: String
        let version: String
        let origin: String  // "Bundled" | "User"
        var id: String { "\(origin)|\(name)" }   // stable identity for diffable data source
    }

    struct Section {
        let title: String
        let rows: [Pkg]
    }

    private var allPackages: [Pkg] = []
    private var sections: [Section] = []   // current display (post-filter)
    private var isLoading = false

    // Storage donut state
    private var donutSegments: [(name: String, bytes: Int64, color: UIColor)] = []
    private var totalBundleBytes: Int64 = 0
    private weak var donutHeader: StorageDonutHeaderView?
    private static let donutPalette: [UIColor] = [
        UIColor(red: 0.35, green: 0.55, blue: 0.98, alpha: 1),  // blue
        UIColor(red: 0.30, green: 0.78, blue: 0.52, alpha: 1),  // green
        UIColor(red: 0.98, green: 0.62, blue: 0.20, alpha: 1),  // orange
        UIColor(red: 0.66, green: 0.50, blue: 0.95, alpha: 1),  // purple
        UIColor(red: 0.25, green: 0.80, blue: 0.82, alpha: 1),  // teal
        UIColor(red: 0.95, green: 0.45, blue: 0.62, alpha: 1),  // pink
        UIColor(red: 0.90, green: 0.78, blue: 0.30, alpha: 1),  // yellow
        UIColor(red: 0.55, green: 0.70, blue: 0.42, alpha: 1),  // olive
        UIColor(red: 0.40, green: 0.72, blue: 0.98, alpha: 1),  // sky
        UIColor(red: 0.80, green: 0.55, blue: 0.35, alpha: 1),  // tan
        UIColor(red: 0.62, green: 0.80, blue: 0.35, alpha: 1),  // lime
        UIColor(red: 0.95, green: 0.55, blue: 0.45, alpha: 1),  // salmon
        UIColor(red: 0.50, green: 0.62, blue: 0.90, alpha: 1),  // periwinkle
        UIColor(red: 0.85, green: 0.42, blue: 0.85, alpha: 1),  // magenta
    ]
    private static let donutOtherColor = UIColor(white: 0.44, alpha: 1)

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
        "torch_metal":       "Machine Learning",
        "transformers":      "Machine Learning",
        "accelerate":        "Machine Learning",
        "peft":              "Machine Learning",
        "tokenizers":        "Machine Learning",
        "safetensors":       "Machine Learning",
        "huggingface_hub":   "Machine Learning",
        "sklearn":           "Machine Learning",
        "torchgen":          "Machine Learning",
        "faiss":             "Machine Learning",
        "sentencepiece":     "Machine Learning",
        "datasets":          "Machine Learning",
        "evaluate":          "Machine Learning",
        "tensorboard":       "Machine Learning",
        "flash_attn":        "Machine Learning",
        "xformers":          "Machine Learning",

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
        "cv2":               "Media (image / video / audio / docs)",
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

    /// PyPI/dist display names → the import-name key used in CATEGORY_MAP /
    /// PACKAGE_INFO. The `.dist-info` shipped for the cross-built C/C++ libs makes
    /// the libs tab show the PyPI name (opencv-python, faiss-cpu) instead of the
    /// import name, so map those back to one curated entry keyed by import name.
    private static let KEY_ALIASES: [String: String] = [
        "opencv_python": "cv2",
        "faiss_cpu":     "faiss",
    ]

    /// Normalize a displayed package name to its curated lookup key.
    fileprivate static func canonicalKey(_ name: String) -> String {
        let k = name.lowercased().replacingOccurrences(of: "-", with: "_")
        return KEY_ALIASES[k] ?? k
    }

    /// Accessible to PackageDetailViewController in this file so the
    /// detail view's hero header can pick the same category icon.
    fileprivate static func categorize(_ name: String) -> String {
        return CATEGORY_MAP[canonicalKey(name)] ?? "Other"
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

    /// First sentence of a package's curated summary, for the card subtitle.
    /// Reuses the existing PACKAGE_INFO data — no new content source.
    static func shortBlurb(name: String, origin: String) -> String {
        if origin == "User" { return "Installed via pip" }
        guard let summary = PackageDetailViewController.blurbSummary(for: name) else {
            return "Bundled dependency"
        }
        // Take up to the first sentence-ending period followed by a space.
        if let dot = summary.range(of: ". ") {
            return String(summary[..<dot.lowerBound])
        }
        // Or up to the first period at the very end.
        if summary.hasSuffix(".") { return String(summary.dropLast()) }
        return summary
    }

    /// Builds the small gradient icon tile used on each card and header.
    static func makeIconTile(symbol: String, tint: UIColor, side: CGFloat,
                             corner: CGFloat, pointSize: CGFloat) -> UIView {
        let tile = GradientTileView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.configure(tint: tint, corner: corner)

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIImage(systemName: symbol)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        tile.addSubview(icon)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: side),
            tile.heightAnchor.constraint(equalToConstant: side),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: side * 0.56),
            icon.heightAnchor.constraint(equalToConstant: side * 0.56),
        ])
        return tile
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        buildHeader()
        buildCollectionView()
        configureDataSource()

        // Empty / loading label (unchanged behavior)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.text = "Loading…"
        emptyLabel.textColor = UIColor(white: 0.55, alpha: 1)
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            collectionView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        refresh()
    }

    private func buildHeader() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.backgroundColor = .clear
        view.addSubview(headerContainer)

        titleLabel.text = "Libraries"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = UIColor(white: 0.97, alpha: 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(titleLabel)

        countLabel.font = .systemFont(ofSize: 13, weight: .medium)
        countLabel.textColor = UIColor(white: 0.50, alpha: 1)
        countLabel.text = " "
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(countLabel)

        // Modern search field (no private-API KVC).
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "Search installed packages"
        searchField.backgroundColor = UIColor(white: 0.14, alpha: 1)
        searchField.textColor = UIColor(white: 0.95, alpha: 1)
        searchField.tintColor = .systemBlue
        searchField.attributedPlaceholder = NSAttributedString(
            string: "Search installed packages",
            attributes: [.foregroundColor: UIColor(white: 0.5, alpha: 1)])
        searchField.layer.cornerRadius = 10
        searchField.clipsToBounds = true
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.addTarget(self, action: #selector(searchChanged(_:)), for: .editingChanged)
        headerContainer.addSubview(searchField)

        // Category chip strip
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.backgroundColor = .clear
        headerContainer.addSubview(chipScroll)

        chipStack.axis = .horizontal
        chipStack.spacing = 8
        chipStack.alignment = .center
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.addSubview(chipStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 18),

            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerContainer.trailingAnchor, constant: -18),

            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 40),

            chipScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            chipScroll.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            chipScroll.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            chipScroll.heightAnchor.constraint(equalToConstant: 34),
            chipScroll.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -10),

            chipStack.topAnchor.constraint(equalTo: chipScroll.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipScroll.bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipScroll.leadingAnchor, constant: 16),
            chipStack.trailingAnchor.constraint(equalTo: chipScroll.trailingAnchor, constant: -16),
            chipStack.heightAnchor.constraint(equalTo: chipScroll.heightAnchor),
        ])
    }

    // The donut header's height is FIXED per layout (.absolute) — self-sizing
    // (.estimated) crashed with "!isinf(contentSize.height)". Since the legend
    // now lists every >=10 MB package, the row count (and height) varies, so we
    // recompute the layout when the segment count changes.
    private var donutHeaderHeight: CGFloat = StorageDonutHeaderView.heightFor(segmentCount: 9)

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(76)))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(76)), subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 10
            section.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 16, trailing: 16)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1.0),
                                  heightDimension: .absolute(34)),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top)
            header.pinToVisibleBounds = false
            section.boundarySupplementaryItems = [header]
            return section
        }
        // Global top donut header, sized to fit its legend.
        let donutHead = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1.0),
                              heightDimension: .absolute(donutHeaderHeight)),
            elementKind: StorageDonutHeaderView.kind,
            alignment: .top)
        donutHead.pinToVisibleBounds = false
        let cfg = UICollectionViewCompositionalLayoutConfiguration()
        cfg.boundarySupplementaryItems = [donutHead]
        layout.configuration = cfg
        return layout
    }

    /// Resize the donut header to fit the current slice count, re-laying the
    /// collection view only when the height actually changed.
    private func syncDonutHeaderHeight() {
        let h = StorageDonutHeaderView.heightFor(
            segmentCount: max(donutSegments.count, 1))
        guard abs(h - donutHeaderHeight) > 0.5 else { return }
        donutHeaderHeight = h
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
    }

    private func buildCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.register(LibraryCardCell.self,
                                forCellWithReuseIdentifier: LibraryCardCell.reuseID)
        collectionView.register(LibrarySectionHeaderView.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: LibrarySectionHeaderView.reuseID)
        collectionView.register(StorageDonutHeaderView.self,
                                forSupplementaryViewOfKind: StorageDonutHeaderView.kind,
                                withReuseIdentifier: StorageDonutHeaderView.reuseID)
        refreshControl.tintColor = UIColor(white: 0.65, alpha: 1)
        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        collectionView.refreshControl = refreshControl
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { [weak self] (cv: UICollectionView, indexPath: IndexPath, _: String) in
            let cell = cv.dequeueReusableCell(
                withReuseIdentifier: LibraryCardCell.reuseID, for: indexPath) as! LibraryCardCell
            if let pkg = self?.sections[indexPath.section].rows[indexPath.row] {
                cell.configure(pkg: pkg)
            }
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] cv, kind, indexPath in
            if kind == StorageDonutHeaderView.kind {
                let head = cv.dequeueReusableSupplementaryView(
                    ofKind: kind, withReuseIdentifier: StorageDonutHeaderView.reuseID,
                    for: indexPath) as! StorageDonutHeaderView
                self?.donutHeader = head
                head.onSelect = { [weak self] name in self?.focusPackage(name) }
                if let self = self, !self.donutSegments.isEmpty {
                    head.configure(segments: self.donutSegments,
                                   total: self.totalBundleBytes,
                                   packageCount: self.allPackages.count)
                }
                return head
            }
            let header = cv.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: LibrarySectionHeaderView.reuseID,
                for: indexPath) as! LibrarySectionHeaderView
            if let title = self?.sections[indexPath.section].title {
                header.configure(title: title)
            }
            return header
        }
    }

    /// Donut → list bridge: tapping a slice filters the list to that package;
    /// resetting clears the filter. (Selection state lives in the donut.)
    private func focusPackage(_ name: String?) {
        let text = name ?? ""
        searchField.text = text
        searchText = text
        applyAndSync(animatingDifferences: true)
    }

    @objc private func pullToRefresh() { refresh() }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        emptyLabel.text = "Loading…"
        emptyLabel.isHidden = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pkgs = Self.scanInstalledPackages()
            let (sizes, total) = Self.computePackageSizes()   // dir walk — bg only
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.allPackages = pkgs
                self.packageSizes = sizes
                self.totalBundleBytes = total
                self.rebuildDonutSegments()
                self.syncDonutHeaderHeight()   // grow/shrink to fit the legend
                self.searchText = self.searchField.text ?? ""
                self.applyAndSync(animatingDifferences: false)
                if !self.donutSegments.isEmpty {
                    self.donutHeader?.configure(segments: self.donutSegments,
                                                total: self.totalBundleBytes,
                                                packageCount: self.allPackages.count)
                }
                self.isLoading = false
                self.refreshControl.endRefreshing()
            }
        }
    }

    // MARK: - Storage sizing

    /// Recursively sum the byte size of a directory tree (best-effort).
    private static func dirSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    /// Per top-level package byte size. Because App-Store packaging wraps
    /// each bundled `.so` into `Frameworks/site-packages.<pkg>.<mod>.framework`,
    /// a package's real footprint = its site-packages tree + every framework
    /// whose name starts `site-packages.<pkg>.`. Returns (sizes, grandTotal).
    private static func computePackageSizes() -> ([String: Int64], Int64) {
        let fm = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let siteURL = bundleURL.appendingPathComponent("app_packages/site-packages", isDirectory: true)
        let userSiteURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("site-packages", isDirectory: true)
        var sizes: [String: Int64] = [:]

        func addSitePackages(_ root: URL) {
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return }
            for e in entries {
                let name = e.lastPathComponent
                if name == "__pycache__" || name.hasSuffix(".dist-info")
                    || name.hasSuffix(".egg-info") { continue }
                // Top-level key: strip a trailing ".py" / ".so" so single-file
                // modules attribute to their own name.
                var key = name
                for suf in [".cpython-314-iphoneos.so", ".cpython-314-iphoneos.fwork",
                            ".py", ".so", ".fwork"] where key.hasSuffix(suf) {
                    key = String(key.dropLast(suf.count)); break
                }
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: e.path, isDirectory: &isDir)
                let sz = isDir.boolValue ? dirSize(e)
                    : Int64((try? e.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                sizes[key, default: 0] += sz
            }
        }
        addSitePackages(siteURL)
        if let u = userSiteURL { addSitePackages(u) }

        // Attribute EVERY framework to its owning package. Two kinds:
        //  1. site-packages.<pkg>.<mod>.framework  -> <pkg>  (wrapped exts)
        //  2. bare native libs with opaque names (libtorch_python = 99 MB,
        //     libusd_ms = 66 MB, libav* …) -> mapped via nativeFrameworkOwner.
        // Interpreter + stdlib C-extensions bucket as "Python runtime".
        // Without this the biggest libraries (torch, bpy) looked tiny because
        // their mass lives in a non-site-packages framework.
        let fwURL = bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        if let fws = try? fm.contentsOfDirectory(
            at: fwURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let prefix = "site-packages."
            for fw in fws where fw.pathExtension == "framework" {
                let base = fw.deletingPathExtension().lastPathComponent
                let sz = dirSize(fw)
                if base.hasPrefix(prefix) {
                    // "site-packages.pyarrow._parquet" -> "pyarrow"
                    let pkg = String(base.dropFirst(prefix.count)
                        .split(separator: ".").first ?? "")
                    if !pkg.isEmpty { sizes[pkg, default: 0] += sz }
                } else if let owner = Self.nativeFrameworkOwner(base) {
                    sizes[owner, default: 0] += sz
                } else {
                    sizes[Self.pythonRuntimeKey, default: 0] += sz
                }
            }
        }

        let total = sizes.values.reduce(0, +)
        return (sizes, total)
    }

    static let pythonRuntimeKey = "Python runtime"

    /// Map a bare native-lib framework (no `site-packages.` prefix) to the
    /// library it belongs to, or nil for interpreter/stdlib pieces.
    private static func nativeFrameworkOwner(_ base: String) -> String? {
        let b = base.lowercased()
        if b.hasPrefix("libtorch") || b == "libshm" || b == "libc10" { return "torch" }
        if b == "libusd_ms" || b.hasPrefix("libbf_intern") || b.hasPrefix("libopenvdb")
            || b.hasPrefix("libosd") { return "bpy" }
        if b.hasPrefix("libav") || b.hasPrefix("libsw") || b.hasPrefix("libpostproc") { return "av" }
        if b.hasPrefix("libscipy_") || b == "libsf_error_state"
            || b == "libfortran_io_stubs" { return "scipy" }
        if b.hasPrefix("libcairo") || b.hasPrefix("libpango") || b.hasPrefix("libpixman")
            || b.hasPrefix("libharfbuzz") || b.hasPrefix("libfreetype")
            || b.hasPrefix("libfontconfig") || b.hasPrefix("libglib")
            || b.hasPrefix("libgobject") || b.hasPrefix("libgio") { return "cairo" }
        if b == "libllama" || b == "llama" || b.hasPrefix("libggml") { return "llama_cpp" }
        if b == "pdftex" || b == "kpathsea" || b.hasPrefix("libkpathsea") { return "latex" }
        if b.hasPrefix("libonnxruntime") { return "onnxruntime" }
        return nil   // Python.framework, _ssl, _hashlib, math, array, mmap, …
    }

    /// Donut slices: every library >= 10 MB gets its own named slice; the
    /// long tail of smaller packages (+ build residue) folds into "Other".
    private func rebuildDonutSegments() {
        // Chart real package cards plus the synthetic "Python runtime"
        // bucket (interpreter + stdlib C-extensions); fold everything else
        // (build residue) into Other so percentages stay honest.
        let chartable = Set(allPackages.map { $0.name.lowercased() })
            .union([Self.pythonRuntimeKey.lowercased()])
        var perPkg: [(String, Int64)] = []
        var residue: Int64 = 0
        for (k, v) in packageSizes {
            if chartable.contains(k.lowercased()) { perPkg.append((k, v)) }
            else { residue += v }
        }
        perPkg.sort { $0.1 > $1.1 }
        let threshold: Int64 = 10 * 1024 * 1024   // 10 MB — its own slice
        var segs: [(name: String, bytes: Int64, color: UIColor)] = []
        var otherBytes = residue
        for (name, bytes) in perPkg {
            if bytes >= threshold {
                segs.append((name, bytes,
                             Self.donutPalette[segs.count % Self.donutPalette.count]))
            } else {
                otherBytes += bytes
            }
        }
        if otherBytes > 0 {
            segs.append(("Other  (<10 MB each)", otherBytes, Self.donutOtherColor))
        }
        donutSegments = segs
    }

    private var packageSizes: [String: Int64] = [:]

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
                    // Prefer the IMPORT name from top_level.txt over the
                    // distribution name — that's what the code, the size
                    // computation (dir/framework names), CATEGORY_MAP and
                    // PACKAGE_INFO are all keyed by. e.g. dist "opencv-python"
                    // -> import "cv2" (so its 12 MB framework matches the
                    // card), "scikit-learn" -> "sklearn", "pillow" -> "PIL".
                    var displayName = name
                    let topPath = (path as NSString)
                        .appendingPathComponent("\(entry)/top_level.txt")
                    if let top = try? String(contentsOfFile: topPath, encoding: .utf8),
                       let imp = top.split(whereSeparator: { $0.isNewline })
                        .map({ $0.trimmingCharacters(in: .whitespaces) })
                        .first(where: { !$0.isEmpty && !$0.hasPrefix("_") }) {
                        displayName = imp
                    }
                    if !displayName.isEmpty {
                        pkgs.append(Pkg(name: displayName, version: version.isEmpty ? "?" : version, origin: origin))
                        haveName.insert(displayName.lowercased())
                        haveName.insert(name.lowercased())   // block the dist-name dir too
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
                // Count as a package if it has __init__.py, __init__.pyc, or a
                // compiled entry — a *.so, or its *.fwork pointer once the
                // App-Store wrapper has moved the .so into Frameworks. Purely
                // compiled packages like bpy (bpy/__init__.so, no __init__.py)
                // are ONLY visible via the .fwork on device — without this
                // they vanished from the list (and the storage donut).
                let full_ns = full as NSString
                let hasInit = fm.fileExists(atPath: full_ns.appendingPathComponent("__init__.py"))
                    || fm.fileExists(atPath: full_ns.appendingPathComponent("__init__.pyc"))
                    || fm.fileExists(atPath: full_ns.appendingPathComponent("__init__.fwork"))
                let hasSO = (try? fm.contentsOfDirectory(atPath: full))?.contains(where: {
                    $0.hasSuffix(".so") || $0.hasSuffix(".fwork")
                }) ?? false
                guard hasInit || hasSO else { continue }
                if haveName.contains(entry.lowercased()) { continue }
                pkgs.append(Pkg(name: entry, version: "-", origin: origin))
            }
        }

        scan(bundleSite, origin: "Bundled")
        if let userSite = userSite { scan(userSite, origin: "User") }

        // torch(metal) ships as top-level files (torch_metal*.so +
        // torchmetal.py), NOT a package directory, so the directory
        // scan above misses it. Surface it as a card whenever the
        // Metal extension is actually bundled.
        let hasTorchMetal = (try? fm.contentsOfDirectory(atPath: bundleSite))?
            .contains { $0.hasPrefix("torch_metal") && $0.hasSuffix(".so") } ?? false
        if hasTorchMetal, !pkgs.contains(where: { $0.name.lowercased() == "torch_metal" }) {
            pkgs.append(Pkg(name: "torch_metal", version: "MPS", origin: "Bundled"))
        }

        // De-dup by identity. A package can legitimately appear twice —
        // most often a stale + current dist-info for the same name (e.g. an
        // upgraded matplotlib leaving matplotlib-3.9.0.dist-info next to
        // 3.11.0). Two identical `Pkg.id`s would crash the diffable data
        // source ("supplied item identifiers are not unique"), so collapse
        // them here, keeping the first seen.
        var seenIDs = Set<String>()
        pkgs = pkgs.filter { seenIDs.insert($0.id).inserted }

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

    // MARK: - Snapshot + category chips

    /// Rebuild `sections` from the current search, honor the active
    /// category chip, push a diffable snapshot, refresh chips + empty state.
    private func applyAndSync(animatingDifferences: Bool = false) {
        // Same call the old code used — search semantics unchanged.
        var built = Self.buildSections(from: allPackages, search: searchText)

        // Reconcile the active-category chip against the current search
        // universe *before* filtering: if a search has narrowed results
        // so the active category no longer matches, fall back to "All"
        // (so the list never goes empty just because a filter went stale).
        if let active = activeCategory, !built.contains(where: { $0.title == active }) {
            activeCategory = nil
        }

        // Layer the category chip on top (browsing affordance only).
        if let active = activeCategory {
            built = built.filter { $0.title == active }
        }
        sections = built

        var snap = NSDiffableDataSourceSnapshot<Int, String>()
        for (idx, sec) in sections.enumerated() {
            snap.appendSections([idx])
            snap.appendItems(sec.rows.map { $0.id }, toSection: idx)
        }
        dataSource.apply(snap, animatingDifferences: animatingDifferences)

        rebuildChips()
        updateEmptyState()
    }

    private func updateEmptyState() {
        let total = sections.reduce(0) { $0 + $1.rows.count }
        emptyLabel.isHidden = total > 0
        if total == 0 {
            emptyLabel.text = searchText.trimmingCharacters(in: .whitespaces).isEmpty
                ? "No packages found."
                : "No matches for \"\(searchText)\""
        }
        // Summary count in the header.
        let shown = allPackages.count
        countLabel.text = shown == 0 ? " " : "\(shown) packages"
    }

    /// Chips reflect the categories present for the *current search*
    /// (ignoring the active-category filter), so users can switch among
    /// whatever matched. "All" clears the category filter.
    private func rebuildChips() {
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // `activeCategory` is already reconciled against this same universe
        // in applyAndSync (our only caller) before we get here.
        let universe = Self.buildSections(from: allPackages, search: searchText)
        chipStack.addArrangedSubview(makeChip(title: "All", category: nil,
                                              selected: activeCategory == nil, tint: .systemBlue))
        for sec in universe {
            let isPip = sec.title.hasPrefix("Pip installed")
            let catName: String = {
                if isPip { return "Pip installed" }
                var t = sec.title
                if let r = t.range(of: "Bundled — ") { t.removeSubrange(t.startIndex..<r.upperBound) }
                if let r = t.range(of: "  (")        { t = String(t[..<r.lowerBound]) }
                return t
            }()
            let (_, tint) = Self.iconForCategory(catName)
            chipStack.addArrangedSubview(
                makeChip(title: catName, category: sec.title,
                         selected: activeCategory == sec.title, tint: tint))
        }
    }

    private func makeChip(title: String, category: String?, selected: Bool, tint: UIColor) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.baseForegroundColor = selected ? UIColor(white: 0.05, alpha: 1) : tint
        cfg.background.backgroundColor = selected ? tint : tint.withAlphaComponent(0.16)
        cfg.background.cornerRadius = 16
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        var ac = AttributeContainer()
        ac.font = .systemFont(ofSize: 12, weight: .semibold)
        cfg.attributedTitle = AttributedString(title, attributes: ac)
        let btn = UIButton(configuration: cfg)
        btn.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.activeCategory = (self.activeCategory == category) ? nil : category
            self.applyAndSync(animatingDifferences: true)
        }, for: .touchUpInside)
        return btn
    }

    // MARK: - Selection (ported verbatim from didSelectRowAt)
    //
    //   - Bundled package → open in-app detail view with summary,
    //     iOS-specific notes, example code, and import helper. We
    //     own this content so we can call out iPad-specific gotchas.
    //   - Pip-installed package → action sheet with PyPI link (we
    //     don't know what arbitrary user-installed packages do).
    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        cv.deselectItem(at: indexPath, animated: true)
        let pkg = sections[indexPath.section].rows[indexPath.row]
        if pkg.origin == "User" {
            presentPyPIActionSheet(for: pkg, anchor: cv.cellForItem(at: indexPath))
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
        let modName = InstalledLibsViewController.canonicalKey(pkg.name)
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

    // MARK: - Search (same semantics as the old searchBar delegate)

    @objc private func searchChanged(_ field: UISearchTextField) {
        searchText = field.text ?? ""
        applyAndSync(animatingDifferences: false)
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
        // Hero banner: large gradient category tile on the left + the
        // package name, version, and category / BUNDLED pills on the
        // right. Replaces the prior flat-disc row with a gradient tile
        // and surfaces the name in-banner (previously only the nav title).
        let row = UIView()
        let category = InstalledLibsViewController.categorize(pkg.name)
        let (symbol, tint) = InstalledLibsViewController.iconForCategory(category)

        let tile = InstalledLibsViewController.makeIconTile(
            symbol: symbol, tint: tint, side: 60, corner: 16, pointSize: 28)
        row.addSubview(tile)

        let nameLabel = UILabel()
        nameLabel.text = pkg.name
        nameLabel.font = .systemFont(ofSize: 22, weight: .bold)
        nameLabel.textColor = UIColor(white: 0.97, alpha: 1)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let version = UILabel()
        version.text = "v\(pkg.version)"
        version.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        version.textColor = UIColor(white: 0.6, alpha: 1)
        version.translatesAutoresizingMaskIntoConstraints = false

        let pillRow = UIStackView()
        pillRow.axis = .horizontal
        pillRow.spacing = 6
        pillRow.alignment = .center
        pillRow.addArrangedSubview(Self.makePill(text: category, tint: tint, filled: false))
        pillRow.addArrangedSubview(Self.makePill(text: "BUNDLED",
                                                 tint: UIColor(white: 0.65, alpha: 1), filled: true))
        pillRow.addArrangedSubview(UIView())

        let textStack = UIStackView(arrangedSubviews: [nameLabel, version, pillRow])
        textStack.axis = .vertical
        textStack.spacing = 6
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(textStack)

        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            tile.topAnchor.constraint(equalTo: row.topAnchor),
            textStack.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualTo: tile.heightAnchor),
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
        v.spacing = 8

        // Header row: section title + (for code blocks) a trailing Copy button.
        let header = UILabel()
        header.text = title.uppercased()
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = accentColor ?? UIColor(white: 0.5, alpha: 1)
        header.setContentCompressionResistancePriority(.required, for: .vertical)
        header.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8
        headerRow.addArrangedSubview(header)
        headerRow.addArrangedSubview(UIView())   // flexible spacer
        if mono {
            var copyCfg = UIButton.Configuration.plain()
            var ac = AttributeContainer()
            ac.font = .systemFont(ofSize: 11, weight: .semibold)
            copyCfg.attributedTitle = AttributedString("Copy", attributes: ac)
            copyCfg.image = UIImage(systemName: "doc.on.doc")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            copyCfg.imagePadding = 4
            copyCfg.baseForegroundColor = .systemBlue
            copyCfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
            let copyBtn = UIButton(configuration: copyCfg)
            copyBtn.setContentHuggingPriority(.required, for: .horizontal)
            copyBtn.addAction(UIAction { _ in
                UIPasteboard.general.string = body
            }, for: .touchUpInside)
            headerRow.addArrangedSubview(copyBtn)
        }
        v.addArrangedSubview(headerRow)

        let text = UILabel()
        text.text = body
        text.numberOfLines = 0
        if mono {
            text.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            text.textColor = UIColor(red: 0.78, green: 0.95, blue: 0.78, alpha: 1)
            // Code block: inset label inside a bordered card.
            let pad = UIView()
            pad.backgroundColor = UIColor(white: 0.13, alpha: 1)
            pad.layer.cornerRadius = 10
            pad.layer.cornerCurve = .continuous
            pad.layer.masksToBounds = true
            pad.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
            pad.layer.borderWidth = 1
            pad.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            pad.addSubview(text)
            NSLayoutConstraint.activate([
                text.topAnchor.constraint(equalTo: pad.topAnchor, constant: 12),
                text.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 14),
                text.trailingAnchor.constraint(equalTo: pad.trailingAnchor, constant: -14),
                text.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -12),
            ])
            v.addArrangedSubview(pad)
        } else {
            text.font = .systemFont(ofSize: 15, weight: .regular)
            text.textColor = UIColor(white: 0.92, alpha: 1)
            // Prose: wrap the body in a subtle rounded card for hierarchy.
            let card = UIView()
            card.backgroundColor = UIColor(white: 0.10, alpha: 1)
            card.layer.cornerRadius = 12
            card.layer.cornerCurve = .continuous
            card.layer.masksToBounds = true
            card.layer.borderColor = (accentColor ?? UIColor(white: 1, alpha: 0.06))
                .withAlphaComponent(accentColor == nil ? 0.06 : 0.30).cgColor
            card.layer.borderWidth = 1
            card.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(text)
            NSLayoutConstraint.activate([
                text.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                text.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                text.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            ])
            v.addArrangedSubview(card)
        }
        return v
    }

    private func makeButtonsRow() -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 10
        stack.distribution = .fillEqually

        // canonicalKey maps PyPI display names → import names (opencv-python→cv2,
        // faiss-cpu→faiss) so the copied statement is actually importable.
        let modName = InstalledLibsViewController.canonicalKey(pkg.name)
        var copyCfg = UIButton.Configuration.gray()
        copyCfg.baseBackgroundColor = UIColor(white: 0.18, alpha: 1)
        copyCfg.baseForegroundColor = UIColor(white: 0.95, alpha: 1)
        copyCfg.cornerStyle = .medium
        copyCfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        var copyAC = AttributeContainer()
        copyAC.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        copyCfg.attributedTitle = AttributedString("Copy  import \(modName)", attributes: copyAC)
        let copyBtn = UIButton(configuration: copyCfg)
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

        var pypiCfg = UIButton.Configuration.gray()
        pypiCfg.baseBackgroundColor = UIColor(white: 0.18, alpha: 1)
        pypiCfg.baseForegroundColor = .systemBlue
        pypiCfg.cornerStyle = .medium
        pypiCfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        var pypiAC = AttributeContainer()
        pypiAC.font = .systemFont(ofSize: 13, weight: .semibold)
        pypiCfg.attributedTitle = AttributedString("Open on PyPI", attributes: pypiAC)
        let pypiBtn = UIButton(configuration: pypiCfg)
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

    /// Read-only peek at a curated summary (for the list's card subtitle).
    /// Returns nil when the package has no curated entry.
    fileprivate static func blurbSummary(for name: String) -> String? {
        return PACKAGE_INFO[InstalledLibsViewController.canonicalKey(name)]?.summary
    }

    private static func lookup(_ name: String) -> Info {
        let key = InstalledLibsViewController.canonicalKey(name)
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
            summary: "PyTorch 2.1.0 native iOS arm64 build. Provides "
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
                + "• GPU (Metal): heavy ops — matmul / mm / bmm / addmm, "
                + "F.linear / softmax / layer_norm / gelu / SDPA — run on "
                + "the Apple GPU. Two routes: the always-on bridge, and the "
                + "explicit `torchmetal` router (import torchmetal; "
                + "torchmetal.enable() — see the torch_metal card). Biggest "
                + "win: fp16 matmul (CPU torch has no fast fp16 GEMM).",
            example: """
            import torch
            x = torch.randn(64, 128)
            y = x @ x.T        # auto-dispatched to Metal GPU
            print(y.shape)     # torch.Size([64, 64])
            """
        ),
        "torch_metal": Info(
            summary: "torch(metal) — GPU acceleration for PyTorch via "
                + "Apple Metal (MPS). A thin routing layer: call "
                + "torchmetal.enable() and heavy torch ops (matmul, "
                + "linear, softmax, layer_norm, gelu, scaled_dot_"
                + "product_attention) run on the GPU through MPSMatrix"
                + "Multiplication + custom Metal kernels, with automatic "
                + "CPU fallback for small or unsupported ops. App-Store-"
                + "safe (uses only public MPS).",
            iosNotes: "• Turn it on with `import torchmetal; torchmetal."
                + "enable()` — no other code changes; it monkey-patches "
                + "torch.matmul / mm / bmm / addmm, Tensor.__matmul__, "
                + "and F.linear / softmax / layer_norm / gelu / scaled_"
                + "dot_product_attention.\n"
                + "• Drop-in: your code is unchanged — keep using `torch` "
                + "exactly as normal (no `.to('mps')`, no device juggling). "
                + "Anything it doesn't handle falls back, so results match "
                + "stock torch (within fp tolerance).\n"
                + "• Accelerates INFERENCE; under autograd (training) it "
                + "falls back to CPU torch — wrap in torch.no_grad() / "
                + "model.eval() for the GPU path.\n"
                + "• Biggest win is fp16 matmul — stock CPU torch has no "
                + "fast fp16 GEMM, so this is hundreds of × faster.\n"
                + "• Size + dtype gated: tiny ops stay on CPU (kernel-"
                + "launch overhead). Call torchmetal.disable() to turn "
                + "routing back off.\n"
                + "• The Metal library loads automatically from the app "
                + "bundle — no setup needed.",
            example: """
            import torch, torchmetal
            torchmetal.enable()          # route heavy ops to the Metal GPU

            a = torch.randn(2048, 2048, dtype=torch.float16)
            b = torch.randn(2048, 2048, dtype=torch.float16)
            c = a @ b                    # runs on the GPU (MPS)
            print(c.shape)

            torchmetal.disable()         # back to stock CPU torch
            """
        ),
        "cv2": Info(
            summary: "OpenCV 4.10.0 — computer vision, cross-compiled "
                + "native for iOS arm64. A curated module set: core, "
                + "imgproc, imgcodecs, photo, features2d, calib3d, "
                + "objdetect, video, ml, flann (no dnn / gui / videoio — "
                + "those need a desktop GUI + codec stack). Image read/"
                + "write, filtering, transforms, feature detection, "
                + "contours, classic object detection.",
            iosNotes: "• CPU only. OpenCV's GPU code is CUDA / OpenCL — "
                + "neither exists on iOS, and OpenCV has no Metal backend — "
                + "so it uses multi-core (GCD) + NEON SIMD instead.\n"
                + "• No cv2.imshow / highgui (no desktop windows): write to "
                + "a file or hand a numpy array to the preview.\n"
                + "• `import cv2` reports 4.10.0; pip sees it as "
                + "opencv-python (dist-info installed).",
            example: """
            import cv2, numpy as np
            img = np.zeros((120, 240, 3), np.uint8)
            cv2.circle(img, (120, 60), 40, (0, 200, 255), -1)
            cv2.imwrite("Documents/circle.png", img)
            """
        ),
        "faiss": Info(
            summary: "FAISS 1.9.0 (CPU) — vector similarity search, "
                + "cross-compiled native for iOS arm64. Build vector "
                + "indexes (IndexFlat, IVF, HNSW, PQ) and run fast nearest-"
                + "neighbour search over embeddings — the retrieval half of "
                + "on-device RAG.",
            iosNotes: "• CPU build (faiss-cpu); the GPU index is CUDA-only "
                + "and does not exist on iOS. Distance math runs on Apple "
                + "Accelerate BLAS.\n"
                + "• Single-threaded — iOS has no libomp, so OpenMP calls "
                + "are served by a serial shim.\n"
                + "• pip sees it as faiss-cpu (dist-info installed).",
            example: """
            import faiss, numpy as np
            x = np.random.rand(1000, 64).astype("float32")
            index = faiss.IndexFlatL2(64)
            index.add(x)
            D, I = index.search(x[:5], 4)   # 4 nearest neighbours each
            print(I)
            """
        ),
        "sentencepiece": Info(
            summary: "SentencePiece 0.2.0 — Google's unsupervised text "
                + "tokenizer (BPE / unigram), cross-compiled native for "
                + "iOS arm64. The tokenizer behind Llama, T5, Gemma and "
                + "many other models: encode text ↔ ids and load .model "
                + "files. Training a new model on-device works too.",
            iosNotes: "• Pure CPU, no special iOS caveats — encode / decode "
                + "and loading a trained .model behave as upstream.\n"
                + "• pip sees it as sentencepiece (dist-info installed).",
            example: """
            import sentencepiece as spm
            sp = spm.SentencePieceProcessor()
            # sp.load("tokenizer.model")        # a model from Llama / T5 / …
            # print(sp.encode("hello world"))   # → token ids
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
                + "• `datasets` (4.0.0), `evaluate`, and TensorBoard "
                + "logging ARE bundled — local load / map / split, "
                + "metric compute, and SummaryWriter all work (see their "
                + "own cards; datasets `.parquet` is the one gap).\n"
                + "• Llama / T5 / BART tokenizers work — `sentencepiece` "
                + "is bundled (see its card).\n"
                + "• `attn_implementation=\"flash_attention_2\"` is auto-"
                + "remapped to sdpa/eager, so it no longer crashes; "
                + "`flash_attn` / `xformers` are importable SDPA shims "
                + "(GPU via the Metal bridge).\n"
                + "• Real gaps: DeepSpeed / FSDP / multi-GPU (one "
                + "device), BitsAndBytes (CUDA-only — use GGUF).",
            example: """
            from transformers import AutoModelForCausalLM, AutoTokenizer
            tok = AutoTokenizer.from_pretrained("gpt2")
            model = AutoModelForCausalLM.from_pretrained("gpt2")
            ids = tok("hello", return_tensors="pt").input_ids
            print(tok.decode(model.generate(ids, max_new_tokens=10)[0]))
            """
        ),
        "datasets": Info(
            summary: "HuggingFace Datasets 4.0.0 — the data half of the "
                + "training loop. Build datasets from dicts / pandas / "
                + "local JSON & CSV, then map / filter / shuffle / "
                + "train_test_split with the Arrow-backed cache.",
            iosNotes: "• Local ops are device-verified: from_dict, "
                + "from_pandas, map, filter, train_test_split, "
                + "load_dataset(\"json\"|\"csv\").\n"
                + "• `.parquet` is the one gap — the bundled pyarrow 15 "
                + "has no Parquet C++ component; convert to JSON/CSV/"
                + "Arrow (a shim keeps the import working).\n"
                + "• `load_dataset(\"<hub-id>\")` needs network; ship the "
                + "files and load them locally instead.\n"
                + "• Version 4.0.0 specifically — 5.0.0 needs pyarrow 21.",
            example: """
            from datasets import Dataset
            d = Dataset.from_dict({"text": ["a", "bb", "ccc"], "y": [0, 1, 0]})
            d = d.map(lambda e: {"n": len(e["text"])})
            print(d["n"], d.train_test_split(test_size=0.34)["test"][0])
            """
        ),
        "evaluate": Info(
            summary: "HuggingFace Evaluate 0.4.6 — metrics for training / "
                + "eval loops (accuracy, F1, precision, recall, …).",
            iosNotes: "• Local metric compute is device-verified.\n"
                + "• `evaluate.load(\"accuracy\")` downloads the metric "
                + "script once (needs network), then runs offline.\n"
                + "• Pure-Python metrics only — ones pulling extra C/Rust "
                + "deps (sacrebleu, bleurt) may not import.",
            example: """
            import evaluate
            acc = evaluate.load("accuracy")   # network on first call
            print(acc.compute(references=[0, 1, 1, 0], predictions=[0, 1, 0, 0]))
            """
        ),
        "tensorboard": Info(
            summary: "TensorBoard 2.19.0 — writes real training-log event "
                + "files offline via SummaryWriter (scalars, histograms, "
                + "images, hparams).",
            iosNotes: "• The WRITER works: torch.utils.tensorboard."
                + "SummaryWriter and Trainer(report_to=\"tensorboard\").\n"
                + "• The VIEWER server (`tensorboard --logdir`) is NOT "
                + "available — it needs grpcio + a background HTTP server. "
                + "Copy the events.out.tfevents.* files off-device to "
                + "view, or use _cb_training.TrainingMonitor in-terminal.\n"
                + "• Version 2.19 — 2.21 needs protobuf 6.31; bundle has "
                + "5.29.6.",
            example: """
            from torch.utils.tensorboard import SummaryWriter
            w = SummaryWriter("Documents/runs/exp1")
            for i in range(10): w.add_scalar("loss", 1.0 / (i + 1), i)
            w.close()   # writes events.out.tfevents.* — copy off-device to view
            """
        ),
        "flash_attn": Info(
            summary: "flash-attn — SDPA-backed shim. Real flash-attn is "
                + "CUDA/Triton-only, so this bundles a pure-Python shim "
                + "that implements its API on F.scaled_dot_product_"
                + "attention — code that hard-imports flash_attn runs "
                + "unchanged and gets GPU attention via the Metal bridge.",
            iosNotes: "• Provides flash_attn_func / flash_attn_varlen_"
                + "func / bert_padding with flash-attn ≥2.1 semantics "
                + "(bottom-right causal for decode, GQA/MQA, varlen). "
                + "Device-verified numerically correct.\n"
                + "• Not implemented (CUDA-only): sliding-window "
                + "attention, ALiBi slopes, return_attn_probs — they "
                + "raise a clear error.\n"
                + "• transformers' attn_implementation=\"flash_attention_"
                + "2\" is auto-remapped to sdpa/eager.",
            example: """
            from flash_attn import flash_attn_func
            import torch
            q = k = v = torch.randn(1, 128, 8, 64)   # (batch, seq, heads, dim)
            out = flash_attn_func(q, k, v, causal=True)   # GPU via SDPA
            print(out.shape)
            """
        ),
        "xformers": Info(
            summary: "xformers — SDPA-backed shim. The one API third-party "
                + "code hard-imports, ops.memory_efficient_attention, is "
                + "implemented on F.scaled_dot_product_attention (GPU via "
                + "the Metal bridge). Lets diffusers etc. import + run.",
            iosNotes: "• Provides ops.memory_efficient_attention (BMHK + "
                + "3-D BMK) and LowerTriangularMask, with GQA/MQA + "
                + "float attn_bias.\n"
                + "• Block-diagonal masks / fmha low-level ops / Triton "
                + "kernels are not shimmed — use F.scaled_dot_product_"
                + "attention directly.",
            example: """
            import torch, xformers.ops as xo
            q = torch.randn(1, 128, 8, 64)
            out = xo.memory_efficient_attention(q, q, q,
                      attn_bias=xo.LowerTriangularMask())   # GPU via SDPA
            print(out.shape)
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
            summary: "NumPy 2.3.5 — native iOS arm64 build, accelerated "
                + "by Apple's Accelerate framework (hardware BLAS + LAPACK "
                + "on the AMX matrix coprocessor). Full ndarray, fast "
                + "linear algebra (matmul, solve, svd, eig), FFT, random, "
                + "broadcasting. Cross-compiled from upstream (see numpy_ios/).",
            iosNotes: "• matmul / @ and np.linalg.* run on the AMX "
                + "coprocessor via Accelerate — this is CPU, not GPU, and "
                + "needs no other library: numpy alone is fully accelerated.\n"
                + "• Behavior matches upstream NumPy at the API level.\n"
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
            iosNotes: "• Default `import cairo` (pycairo) renders on the "
                + "CPU (software image backend).\n"
                + "• GPU option: `import cairo_metal as cairo` is a "
                + "pycairo-compatible GPU cairo on Apple Metal (stencil-"
                + "then-cover, IOSurface-backed), pixel-diffed against real "
                + "cairo. Standalone repo: github.com/yu314-coder/cairometal.\n"
                + "• GPU cairo does NOT speed up manim — manim's bottleneck "
                + "is single-threaded Python (mobject interpolation), not "
                + "cairo fill (~5% of a frame).",
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
