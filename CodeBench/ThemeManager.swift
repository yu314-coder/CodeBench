import UIKit

// MARK: - Conversation (extracted from GameViewController)

struct Conversation: Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
    var isPinned: Bool

    init(id: UUID = UUID(), title: String, messages: [ChatMessage] = [], updatedAt: Date = Date(), isPinned: Bool = false) {
        self.id = id
        self.title = title
        self.messages = messages
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

// MARK: - Theme Manager

final class ThemeManager {
    static let shared = ThemeManager()
    static let themeDidChangeNotification = Notification.Name("CodeBenchThemeDidChange")

    enum Mode: Int {
        case system = 0
        case light = 1
        case dark = 2
    }

    private let modeKey = "theme.mode"

    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.integer(forKey: modeKey)) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            NotificationCenter.default.post(name: Self.themeDidChangeNotification, object: nil)
        }
    }

    var isDark: Bool {
        // Dark-only for now. The light-theme color variants are incomplete:
        // `solidBackground` (and friends) return white while the sidebar,
        // editor and dashboard stay hard-coded dark, so light / auto
        // appearance rendered the main content pane solid white. Force dark
        // until a complete light theme exists, so `solidBackground` etc. can
        // never be white. (Restore the `mode`-based switch below at that point.)
        return true
        // switch mode {
        // case .system: return UITraitCollection.current.userInterfaceStyle == .dark
        // case .light:  return false
        // case .dark:   return true
        // }
    }

    private init() {}
}

// MARK: - WorkspaceStyle (theme-aware)

struct WorkspaceStyle {
    static let spacing4: CGFloat = 4
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let radiusMedium: CGFloat = 18
    static let radiusLarge: CGFloat = 26
    static let borderWidth: CGFloat = 0.5
    static let shadowOpacity: Float = 0.12
    static let shadowRadius: CGFloat = 24
    static let shadowOffset = CGSize(width: 0, height: 8)

    static var glassFill: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(white: 0.12, alpha: 0.65)
            : UIColor(white: 1.0, alpha: 0.45)
    }

    static var glassStroke: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(white: 0.30, alpha: 0.40)
            : UIColor(white: 1.0, alpha: 0.65)
    }

    static var surfacePrimary: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(white: 0.08, alpha: 0.60)
            : UIColor(white: 1.0, alpha: 0.38)
    }

    static var surfaceElevated: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(white: 0.15, alpha: 0.55)
            : UIColor(white: 1.0, alpha: 0.52)
    }

    static var accent: UIColor {
        UIColor(red: 0.30, green: 0.52, blue: 1.0, alpha: 1.0)
    }

    static var accentGlow: UIColor {
        UIColor(red: 0.40, green: 0.65, blue: 1.0, alpha: 0.35)
    }

    static var mutedText: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(white: 0.65, alpha: 1.0)
            : UIColor(white: 0.35, alpha: 1.0)
    }

    static var primaryText: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(white: 0.95, alpha: 1.0)
            : UIColor(white: 0.10, alpha: 1.0)
    }

    static var secondaryText: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(white: 0.75, alpha: 1.0)
            : UIColor(white: 0.25, alpha: 1.0)
    }

    static var glassBlurStyle: UIBlurEffect.Style {
        ThemeManager.shared.isDark
            ? .systemUltraThinMaterialDark
            : .systemUltraThinMaterial
    }

    static var sidebarBlurStyle: UIBlurEffect.Style {
        ThemeManager.shared.isDark
            ? .systemChromeMaterialDark
            : .systemChromeMaterial
    }

    static var assistantBubbleBg: UIColor {
        .clear  // ChatGPT-style: no background for assistant
    }

    static var userBubbleBg: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(white: 0.26, alpha: 1.0)
            : UIColor(white: 0.93, alpha: 1.0)
    }

    static var codeBg: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(white: 0.08, alpha: 0.80)
            : UIColor(white: 0.92, alpha: 0.80)
    }

    static var codeText: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(red: 0.55, green: 0.85, blue: 0.65, alpha: 1.0)
            : UIColor(red: 0.80, green: 0.20, blue: 0.30, alpha: 1.0)
    }

    // Background solid color — deep dark for high-tech look
    static var solidBackground: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(red: 0.075, green: 0.078, blue: 0.090, alpha: 1.0) // #131417 — deep dark
            : UIColor.white
    }

    // Legacy gradient (now single solid color)
    static var gradientColors: [CGColor] {
        return [solidBackground.cgColor]
    }

    static var overlayGradientColors: [CGColor] {
        if ThemeManager.shared.isDark {
            return [
                UIColor(red: 0.10, green: 0.08, blue: 0.20, alpha: 0.40).cgColor,
                UIColor.clear.cgColor
            ]
        } else {
            return [
                UIColor(red: 1.0, green: 0.98, blue: 0.95, alpha: 0.40).cgColor,
                UIColor.clear.cgColor
            ]
        }
    }

    // ── VS Code Sidebar Colors (Activity Bar + Side Bar) ──

    /// Activity bar (icon rail) — darkest column, VS Code #2c2c2c / #e8e8e8
    static var activityBarBg: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(red: 0.173, green: 0.173, blue: 0.173, alpha: 1.0) // #2c2c2c
            : UIColor(red: 0.91, green: 0.91, blue: 0.92, alpha: 1.0)   // #E8E8EA
    }

    /// Activity bar icon — inactive (visible but muted)
    static var activityBarInactive: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(white: 0.55, alpha: 1.0)
            : UIColor(white: 0.45, alpha: 1.0)
    }

    /// Activity bar icon — active (bright white / dark black)
    static var activityBarActive: UIColor {
        ThemeManager.shared.isDark
            ? UIColor.white
            : UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
    }

    /// Activity bar active indicator — left border accent
    static var activityBarIndicator: UIColor {
        accent
    }

    /// Side bar background — deep dark
    static var sideBarBg: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(red: 0.090, green: 0.094, blue: 0.110, alpha: 1.0) // #171a1c
            : UIColor(red: 0.953, green: 0.953, blue: 0.953, alpha: 1.0)
    }

    /// Side bar section header
    static var sideBarHeaderText: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(red: 0.73, green: 0.73, blue: 0.73, alpha: 1.0) // #BBBBBB
            : UIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1.0)
    }

    /// Side bar border (between activity bar and sidebar, sidebar and editor)
    static var sideBarBorder: UIColor {
        ThemeManager.shared.isDark
            ? UIColor(red: 0.188, green: 0.188, blue: 0.192, alpha: 1.0) // #303032
            : UIColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1.0)
    }
}

// MARK: - Liquid Glass design system

/// One place for the app's glass chrome. On iOS 26+ this is Apple's
/// REAL Liquid Glass (`UIGlassEffect` — refractive, depth-aware); on
/// older systems it gracefully falls back to the closest dark material
/// blur, so every call site reads identically and never needs its own
/// availability dance.
///
/// Usage: `LiquidGlass.apply(to: card, corner: 16)` replaces a solid
/// `backgroundColor` — content stays in the host view, the glass slab
/// slides underneath it (subview index 0). Decorative CAGradientLayers
/// the host inserted at sublayer 0 (corner glows etc.) end up BEHIND
/// the glass and diffuse through it, which looks intentional and good.
enum LiquidGlass {

    /// True when the OS renders real Liquid Glass.
    static var isModern: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// The shared chrome effect: glass on 26+, ultra-thin dark material before.
    static func effect() -> UIVisualEffect {
        if #available(iOS 26.0, *) { return UIGlassEffect() }
        return UIBlurEffect(style: .systemUltraThinMaterialDark)
    }

    /// Mount a rounded glass slab under `host`'s content and clear the
    /// host's own background. `dim` adds a dark scrim inside the glass
    /// so text keeps contrast over busy backdrops (0 disables).
    @discardableResult
    static func apply(to host: UIView, corner: CGFloat, dim: CGFloat = 0.30) -> UIVisualEffectView {
        let ev = UIVisualEffectView(effect: effect())
        ev.translatesAutoresizingMaskIntoConstraints = false
        ev.layer.cornerRadius = corner
        ev.layer.cornerCurve = .continuous
        ev.clipsToBounds = true
        ev.isUserInteractionEnabled = false   // taps fall through to the host control
        host.insertSubview(ev, at: 0)
        NSLayoutConstraint.activate([
            ev.topAnchor.constraint(equalTo: host.topAnchor),
            ev.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            ev.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ev.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        if dim > 0 {
            let scrim = UIView()
            scrim.backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.06, alpha: dim)
            scrim.translatesAutoresizingMaskIntoConstraints = false
            scrim.isUserInteractionEnabled = false
            ev.contentView.addSubview(scrim)
            NSLayoutConstraint.activate([
                scrim.topAnchor.constraint(equalTo: ev.contentView.topAnchor),
                scrim.leadingAnchor.constraint(equalTo: ev.contentView.leadingAnchor),
                scrim.trailingAnchor.constraint(equalTo: ev.contentView.trailingAnchor),
                scrim.bottomAnchor.constraint(equalTo: ev.contentView.bottomAnchor),
            ])
        }
        host.backgroundColor = .clear
        return ev
    }
}
