import UIKit

/// A horizontal, browser-style tab strip for the iPad output/preview panel.
///
/// Self-contained on purpose: it renders chips (type icon + title + ×),
/// scrolls horizontally when they overflow, highlights the active one, and
/// reports taps via the `onSelect` / `onClose` callbacks. It holds no model
/// of its own — the owning controller (`CodeEditorViewController`) keeps the
/// list of preview sources and re-renders content on selection, so this view
/// stays a dumb, testable presenter.
///
/// Identity is a plain string (the file path or URL) so the controller can
/// dedupe "one tab per file/URL".
final class PreviewTabsBar: UIView {

    struct Tab {
        let id: String          // identity key — the file path or URL
        let title: String       // chip label
        let systemIcon: String  // SF Symbol name (kind hint)
    }

    /// Tapped a chip body. Argument is `Tab.id`.
    var onSelect: ((String) -> Void)?
    /// Tapped a chip's × button. Argument is `Tab.id`.
    var onClose: ((String) -> Void)?

    /// Active-chip accent (matches the editor's indigo).
    var accentColor: UIColor = UIColor(red: 0x6c/255.0, green: 0x6c/255.0,
                                       blue: 0xff/255.0, alpha: 1.0)

    private let scroll = UIScrollView()
    private let row = UIStackView()
    private var tabs: [Tab] = []
    private var activeID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.clipsToBounds = true
        addSubview(scroll)

        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        scroll.addSubview(row)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isEmpty: Bool { tabs.isEmpty }

    /// Replace the full tab set and highlight `active` (nil = none).
    func setTabs(_ tabs: [Tab], active: String?) {
        self.tabs = tabs
        self.activeID = active
        rebuild()
    }

    // MARK: - Rendering

    private func rebuild() {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tab in tabs {
            row.addArrangedSubview(makeChip(tab))
        }
        // Bring the active chip into view after layout settles.
        if let idx = tabs.firstIndex(where: { $0.id == activeID }),
           idx < row.arrangedSubviews.count {
            let chip = row.arrangedSubviews[idx]
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.layoutIfNeeded()
                self.scroll.scrollRectToVisible(
                    chip.convert(chip.bounds, to: self.scroll), animated: true)
            }
        }
    }

    private func makeChip(_ tab: Tab) -> UIView {
        let isActive = (tab.id == activeID)

        // The chip body is a UIControl so a tap on it (anywhere not covered
        // by the close button) fires `onSelect`. Non-interactive icon/label
        // let the touch fall through to the control; the close UIButton, being
        // a control itself, takes precedence in its own frame.
        let chip = TabChip(id: tab.id)
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.backgroundColor = isActive
            ? UIColor(red: 0x2b/255.0, green: 0x2b/255.0, blue: 0x40/255.0, alpha: 1.0)
            : UIColor(red: 0x18/255.0, green: 0x18/255.0, blue: 0x24/255.0, alpha: 1.0)
        chip.layer.cornerRadius = 6
        chip.layer.cornerCurve = .continuous
        chip.layer.borderWidth = 1
        chip.layer.borderColor = isActive
            ? accentColor.withAlphaComponent(0.9).cgColor
            : UIColor.white.withAlphaComponent(0.06).cgColor
        chip.addAction(UIAction { [weak self] _ in self?.onSelect?(tab.id) },
                       for: .touchUpInside)

        let icon = UIImageView(image: UIImage(systemName: tab.systemIcon))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.isUserInteractionEnabled = false
        icon.tintColor = isActive ? .white : UIColor(white: 0.60, alpha: 1)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = tab.title
        label.font = .systemFont(ofSize: 11, weight: isActive ? .semibold : .regular)
        label.textColor = isActive ? .white : UIColor(white: 0.66, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.isUserInteractionEnabled = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)

        let close = UIButton(type: .system)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.setImage(UIImage(systemName: "xmark", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)), for: .normal)
        close.tintColor = isActive ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.5, alpha: 1)
        close.addAction(UIAction { [weak self] _ in self?.onClose?(tab.id) },
                        for: .touchUpInside)

        chip.addSubview(icon)
        chip.addSubview(label)
        chip.addSubview(close)

        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalToConstant: 24),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 190),

            icon.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),

            close.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18),
            close.heightAnchor.constraint(equalToConstant: 18),
        ])
        return chip
    }

    /// Chip body — a UIControl so taps anywhere on it (outside the close
    /// button) fire `.touchUpInside`. Holds its identity for debugging.
    private final class TabChip: UIControl {
        let id: String
        init(id: String) { self.id = id; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
