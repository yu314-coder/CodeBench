import UIKit

/// Workspace Dashboard — a card-grid launcher that replaces the
/// "blank editor" first-impression most iPad code editors show
/// (Pythonista / Carnets / Pyto / VS-Code-clone pattern). The
/// dashboard is the first thing users see on app launch; tapping a
/// card transitions to that section's view (editor, terminal, AI
/// chat, etc.). Designed specifically to make the App Store 4.3
/// "looks like an existing dev tool" rejection vanish.
///
/// Visual identity matches the rest of CodeBench's category-color
/// system (the Libraries tab uses the same palette). Each card has:
///   • A tinted icon disc in the upper-left
///   • A title (large, semibold-rounded)
///   • A 1-line subtitle
///   • A gradient accent corner
///   • Rounded corners with subtle border
///
/// The grid auto-adapts: 2 columns on iPhone, 3 columns on iPad
/// portrait, 4 columns on iPad landscape.

protocol WorkspaceDashboardDelegate: AnyObject {
    func dashboardDidSelect(_ action: WorkspaceDashboardView.Action)
}

final class WorkspaceDashboardView: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {

    enum Action {
        case editor          // open the code editor
        case files           // file browser
        case terminal        // Python REPL / shell
        case aiChat          // local LLM chat
        case libraries       // installed Python packages
        case latex           // LaTeX workspace
        case runScript       // run currently-selected file
        case gpuLab          // PyTorch Metal GPU bench
        case settings        // app settings
        case recentFile(URL) // open a specific recent file
    }

    private struct Card {
        let title: String
        let subtitle: String
        let symbol: String
        let tint: UIColor
        let action: Action
    }

    weak var delegate: WorkspaceDashboardDelegate?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let collectionView: UICollectionView

    private var cards: [Card] = []
    private var recentFiles: [URL] = []

    // MARK: - Init

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 14
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        buildCards()
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildCards() {
        cards = [
            Card(title: "Code Editor",
                 subtitle: "Monaco with IntelliSense",
                 symbol: "doc.text.below.ecg",
                 tint: UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1),
                 action: .editor),
            Card(title: "Files",
                 subtitle: "Browse your workspace",
                 symbol: "folder.fill.badge.gearshape",
                 tint: UIColor(red: 0.40, green: 0.80, blue: 0.70, alpha: 1),
                 action: .files),
            Card(title: "Python REPL",
                 subtitle: "Interactive shell",
                 symbol: "terminal.fill",
                 tint: UIColor(red: 0.55, green: 0.65, blue: 0.95, alpha: 1),
                 action: .terminal),
            Card(title: "AI Chat",
                 subtitle: "Local on-device LLM",
                 symbol: "brain.head.profile",
                 tint: UIColor(red: 0.69, green: 0.51, blue: 0.95, alpha: 1),
                 action: .aiChat),
            Card(title: "Libraries",
                 subtitle: "115+ bundled packages",
                 symbol: "books.vertical.fill",
                 tint: UIColor(red: 0.95, green: 0.78, blue: 0.35, alpha: 1),
                 action: .libraries),
            Card(title: "LaTeX",
                 subtitle: "Math + full document",
                 symbol: "x.squareroot",
                 tint: UIColor(red: 0.85, green: 0.72, blue: 0.35, alpha: 1),
                 action: .latex),
            Card(title: "Run Script",
                 subtitle: "Execute current file",
                 symbol: "play.fill",
                 tint: UIColor(red: 0.32, green: 0.83, blue: 0.45, alpha: 1),
                 action: .runScript),
            Card(title: "GPU Lab",
                 subtitle: "Metal matmul benchmark",
                 symbol: "memorychip.fill",
                 tint: UIColor(red: 0.95, green: 0.45, blue: 0.70, alpha: 1),
                 action: .gpuLab),
            Card(title: "Settings",
                 subtitle: "Themes, model, etc.",
                 symbol: "gearshape.2.fill",
                 tint: UIColor(red: 0.65, green: 0.70, blue: 0.78, alpha: 1),
                 action: .settings),
        ]
    }

    private func setupUI() {
        backgroundColor = UIColor(red: 0.075, green: 0.078, blue: 0.090, alpha: 1)

        // ── Heading ──
        titleLabel.text = "Workspace"
        titleLabel.font = UIFont.systemFont(ofSize: 34, weight: .heavy).rounded
        titleLabel.textColor = UIColor(white: 0.96, alpha: 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.text = "Pick what you want to do."
        subtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 0.6, alpha: 1)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        // ── Collection view ──
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset = UIEdgeInsets(top: 4, left: 24, bottom: 28, right: 24)
        collectionView.register(CardCell.self, forCellWithReuseIdentifier: "card")
        collectionView.register(SectionHeader.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: "section")
        addSubview(collectionView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            collectionView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Update the recent-files list shown at the top of the dashboard.
    /// Called by the host VC whenever the workspace's recent list
    /// changes (file opened / saved).
    func setRecentFiles(_ files: [URL]) {
        recentFiles = Array(files.prefix(6))
        collectionView.reloadData()
    }

    // MARK: - UICollectionView data source

    func numberOfSections(in cv: UICollectionView) -> Int {
        return recentFiles.isEmpty ? 1 : 2
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int {
        if recentFiles.isEmpty { return cards.count }
        return s == 0 ? recentFiles.count : cards.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "card", for: ip) as! CardCell
        let isRecent = !recentFiles.isEmpty && ip.section == 0
        if isRecent {
            let url = recentFiles[ip.item]
            cell.configure(
                title: url.lastPathComponent,
                subtitle: url.deletingLastPathComponent().path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                symbol: iconForFileExtension(url.pathExtension),
                tint: UIColor(red: 0.60, green: 0.75, blue: 0.95, alpha: 1))
        } else {
            let card = cards[ip.item]
            cell.configure(title: card.title, subtitle: card.subtitle,
                           symbol: card.symbol, tint: card.tint)
        }
        return cell
    }

    func collectionView(_ cv: UICollectionView,
                       viewForSupplementaryElementOfKind kind: String,
                       at ip: IndexPath) -> UICollectionReusableView {
        let v = cv.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: "section", for: ip) as! SectionHeader
        if !recentFiles.isEmpty && ip.section == 0 {
            v.setTitle("Recent")
        } else {
            v.setTitle("Open")
        }
        return v
    }

    // MARK: - Layout

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                       sizeForItemAt ip: IndexPath) -> CGSize {
        let cols = optimalColumnCount(width: cv.bounds.width)
        let totalInset: CGFloat = 24 * 2  // matches contentInset above
        let totalGaps: CGFloat = 14 * CGFloat(cols - 1)
        let available = cv.bounds.width - totalInset - totalGaps
        let w = floor(available / CGFloat(cols))
        // Recent-file cards: slightly shorter; section cards: taller
        let isRecent = !recentFiles.isEmpty && ip.section == 0
        return CGSize(width: w, height: isRecent ? 92 : 116)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                       referenceSizeForHeaderInSection s: Int) -> CGSize {
        return CGSize(width: cv.bounds.width, height: 34)
    }

    private func optimalColumnCount(width: CGFloat) -> Int {
        switch width {
        case ..<480:   return 2
        case ..<840:   return 3
        case ..<1100:  return 4
        default:       return 5
        }
    }

    private func iconForFileExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "py":               return "chevron.left.forwardslash.chevron.right"
        case "c", "cpp", "cc":   return "c.square.fill"
        case "f", "f90", "f95":  return "f.square.fill"
        case "tex":              return "x.squareroot"
        case "txt", "md":        return "doc.text"
        case "json":             return "curlybraces.square"
        case "yml", "yaml":      return "list.bullet.indent"
        case "html", "htm":      return "doc.richtext"
        case "css":              return "paintbrush"
        case "js", "ts":         return "j.square.fill"
        case "swift":            return "swift"
        case "png", "jpg", "jpeg", "gif":  return "photo"
        default:                 return "doc"
        }
    }

    // MARK: - Tap handling

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: true)
        let isRecent = !recentFiles.isEmpty && ip.section == 0
        if isRecent {
            delegate?.dashboardDidSelect(.recentFile(recentFiles[ip.item]))
        } else {
            delegate?.dashboardDidSelect(cards[ip.item].action)
        }
    }

    // MARK: - Card cell

    private final class CardCell: UICollectionViewCell {
        private let iconDisc = UIView()
        private let iconView = UIImageView()
        private let titleLabel = UILabel()
        private let subtitleLabel = UILabel()
        private let cornerAccent = CAGradientLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            buildUI()
        }
        required init?(coder: NSCoder) { fatalError() }

        private func buildUI() {
            // Card chrome
            contentView.backgroundColor = UIColor(white: 0.13, alpha: 1)
            contentView.layer.cornerRadius = 16
            contentView.layer.borderWidth = 1
            contentView.layer.borderColor = UIColor(white: 0.22, alpha: 1).cgColor
            contentView.layer.masksToBounds = true

            // Corner gradient accent — top-left diagonal flourish that
            // signals the category, distinct from VS-Code-style cards.
            cornerAccent.startPoint = CGPoint(x: 0, y: 0)
            cornerAccent.endPoint = CGPoint(x: 0.7, y: 0.7)
            cornerAccent.opacity = 0.16
            contentView.layer.insertSublayer(cornerAccent, at: 0)

            // Icon disc
            iconDisc.translatesAutoresizingMaskIntoConstraints = false
            iconDisc.layer.cornerRadius = 10
            contentView.addSubview(iconDisc)

            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.contentMode = .scaleAspectFit
            iconDisc.addSubview(iconView)

            // Title
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .bold).rounded
            titleLabel.textColor = UIColor(white: 0.96, alpha: 1)
            titleLabel.numberOfLines = 1
            contentView.addSubview(titleLabel)

            // Subtitle
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
            subtitleLabel.textColor = UIColor(white: 0.6, alpha: 1)
            subtitleLabel.numberOfLines = 1
            subtitleLabel.lineBreakMode = .byTruncatingTail
            contentView.addSubview(subtitleLabel)

            NSLayoutConstraint.activate([
                iconDisc.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
                iconDisc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
                iconDisc.widthAnchor.constraint(equalToConstant: 38),
                iconDisc.heightAnchor.constraint(equalToConstant: 38),
                iconView.centerXAnchor.constraint(equalTo: iconDisc.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: iconDisc.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 22),
                iconView.heightAnchor.constraint(equalToConstant: 22),

                titleLabel.topAnchor.constraint(equalTo: iconDisc.bottomAnchor, constant: 10),
                titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
                titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),

                subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            ])
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Cover the top-left ~60% of the card with the diagonal
            // gradient — gives each card a colored corner flourish.
            let w = contentView.bounds.width
            cornerAccent.frame = CGRect(x: 0, y: 0, width: w * 0.7, height: w * 0.5)
        }

        override var isHighlighted: Bool {
            didSet {
                UIView.animate(withDuration: 0.12) {
                    self.contentView.transform = self.isHighlighted
                        ? CGAffineTransform(scaleX: 0.97, y: 0.97)
                        : .identity
                    self.contentView.alpha = self.isHighlighted ? 0.8 : 1
                }
            }
        }

        func configure(title: String, subtitle: String, symbol: String, tint: UIColor) {
            titleLabel.text = title
            subtitleLabel.text = subtitle
            iconView.image = UIImage(systemName: symbol)?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
            iconView.tintColor = tint
            iconDisc.backgroundColor = tint.withAlphaComponent(0.18)
            iconDisc.layer.borderColor = tint.withAlphaComponent(0.35).cgColor
            iconDisc.layer.borderWidth = 1
            cornerAccent.colors = [tint.cgColor, UIColor.clear.cgColor]
        }
    }

    private final class SectionHeader: UICollectionReusableView {
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 12, weight: .heavy)
            label.textColor = UIColor(white: 0.55, alpha: 1)
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }

        func setTitle(_ s: String) {
            // Letter-spaced caps for a custom typographic identity that
            // doesn't read as stock iOS section headers.
            label.attributedText = NSAttributedString(
                string: s.uppercased(),
                attributes: [.kern: 1.5])
        }
    }
}
