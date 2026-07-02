import UIKit
import QuartzCore

/// Long-press recognizer that also carries the launcher selector to run
/// on release — lets `makeGameCard` give every card press a scale +
/// haptic without a per-card UIControl subclass.
private final class HGPressGesture: UILongPressGestureRecognizer {
    var gameSelector: Selector?
}

/// UILabel with fixed horizontal padding, used for self-removing toasts.
private final class PaddedLabel: UILabel {
    var inset = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right, height: s.height)
    }
}

// ════════════════════════════════════════════════════════════════════
// Hidden games launcher
// ════════════════════════════════════════════════════════════════════
//
// Six full-UI mini-games reachable only via a hidden 3-finger
// swipe-UP gesture on the editor (paired symmetrically with the
// 3-finger swipe-DOWN that cycles secret themes). Each game lives
// in its own UIViewController, fully self-contained: a campaign with
// a real finish line, auto-saved progress, touch + hardware keyboard.

/// Shared persistent storage for the 3 mini-games. Stored as plain
/// `Int` under `UserDefaults` so the launcher can show a "best" badge
/// per game without each game class needing its own persistence layer.
enum HiddenGameScores {
    private static let d = UserDefaults.standard
    static func best(_ key: String) -> Int { d.integer(forKey: "hg.best.\(key)") }
    static func recordIfHigher(_ key: String, _ value: Int) {
        if value > best(key) { d.set(value, forKey: "hg.best.\(key)") }
    }
    /// True only when `value` strictly beats the stored best. Lets a
    /// caller record AND learn "is this a new record?" in one shot,
    /// so games can fire a celebratory toast without a second lookup.
    @discardableResult
    static func recordIfHigherWasRecord(_ key: String, _ value: Int) -> Bool {
        let isRecord = value > best(key)
        if isRecord { d.set(value, forKey: "hg.best.\(key)") }
        return isRecord
    }
    /// Per-game lifetime play counter, namespaced like the bests.
    static func plays(_ key: String) -> Int { d.integer(forKey: "hg.plays.\(key)") }
    static func bumpPlays(_ key: String) { d.set(plays(key) + 1, forKey: "hg.plays.\(key)") }
    /// Wipe every hidden-game best + play count + saved game. Iterates the
    /// standard domain so we never have to hard-code the per-game key list.
    static func resetAll() {
        for k in d.dictionaryRepresentation().keys
        where k.hasPrefix("hg.best.") || k.hasPrefix("hg.plays.") || k.hasPrefix("hg.save.") {
            d.removeObject(forKey: k)
        }
    }

    // ── Resumable-game save slots ─────────────────────────────────────
    // Small JSON blobs so a long game (a 2048 run, a half-cleared
    // Minesweeper board, a Sokoban campaign) survives app relaunches.
    static func saveBlob(_ key: String, _ obj: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            d.set(data, forKey: "hg.save.\(key)")
        }
    }
    static func loadBlob(_ key: String) -> [String: Any]? {
        guard let raw = d.data(forKey: "hg.save.\(key)"),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return nil }
        return obj
    }
    static func clearBlob(_ key: String) { d.removeObject(forKey: "hg.save.\(key)") }
}

/// Base for every keyboard-playable hidden game. Centralises the
/// "keep the hardware keyboard alive through a long session" logic so
/// no individual game can forget a case. A plain UIViewController that
/// becomes first responder SILENTLY loses it when the app is
/// backgrounded or after a presented alert (win / next-level / game
/// over) dismisses — which kills key input mid-game. This base:
///   • becomes first responder on appear (required for both
///     `keyCommands` and `pressesBegan` to fire);
///   • RECLAIMS it when the app returns from the background, and
///   • RECLAIMS it after any alert dismisses (UIKit routes the alert's
///     dismissal through its presenter — this game);
///   • disables the nav back-swipe while a board is up so edge swipes
///     don't pop the screen instead of moving a piece.
/// Touch play is untouched — this only governs keyboard input. Games
/// keep their own viewDidAppear/viewWillDisappear; because those call
/// super, this runs underneath them.
class HGKeyboardGame: UIViewController {

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        reclaimKeyboard()
        // Register exactly once even though viewDidAppear can re-fire
        // (e.g. popping back from the level picker).
        NotificationCenter.default.removeObserver(
            self, name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(hgAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        super.dismiss(animated: flag) { [weak self] in
            completion?()
            self?.reclaimKeyboard()
        }
    }

    @objc private func hgAppDidBecomeActive() { reclaimKeyboard() }

    /// Re-grab first responder on the next runloop (so it lands after
    /// any in-flight dismissal/animation), but only while on screen and
    /// not already holding it.
    func reclaimKeyboard() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.viewIfLoaded?.window != nil, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

final class HiddenGamesLauncher: UIViewController {
    private let bg = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1.0)  // #0a0a0f
    private let fg = UIColor(red: 0.941, green: 0.941, blue: 0.961, alpha: 1.0)  // #f0f0f5
    private let muted = UIColor(red: 0.420, green: 0.420, blue: 0.502, alpha: 1.0)  // #6b6b80
    private weak var cardsStackRef: UIStackView?
    private var gameSlots: [GameSlot] = []

    private struct GameSlot {
        let key: String
        let title: String
        let blurb: String
        let glyph: String          // SF Symbol
        let tint: UIColor
        let glowRGB: (CGFloat, CGFloat, CGFloat)
        let scoreKey: String
        let scoreFormat: (Int) -> String   // "2048" board ⇒ Best 4096, etc.
        let selector: Selector
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        title = ""
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))

        // Hero header — bigger than a navbar title can be.
        let heroCard = UIView()
        heroCard.translatesAutoresizingMaskIntoConstraints = false
        heroCard.layer.cornerRadius = 18
        heroCard.layer.cornerCurve = .continuous
        heroCard.layer.borderColor = UIColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 0.15).cgColor
        heroCard.layer.borderWidth = 1
        LiquidGlass.apply(to: heroCard, corner: 18, dim: 0.30)

        let heroGlow = CAGradientLayer()
        heroGlow.name = "hg.heroGlow"
        heroGlow.type = .radial
        heroGlow.colors = [
            UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 0.30).cgColor,
            UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 0.00).cgColor,
        ]
        heroGlow.locations = [0.0, 1.0]
        heroGlow.startPoint = CGPoint(x: 0.18, y: 0.5)
        heroGlow.endPoint   = CGPoint(x: 0.9, y: 1.5)
        heroCard.layer.insertSublayer(heroGlow, at: 0)

        let heroIcon = UIImageView()
        heroIcon.translatesAutoresizingMaskIntoConstraints = false
        heroIcon.image = UIImage(systemName: "gamecontroller.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold))
        heroIcon.tintColor = UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 1.0) // violet
        heroIcon.layer.shadowColor = heroIcon.tintColor.cgColor
        heroIcon.layer.shadowOpacity = 0.55
        heroIcon.layer.shadowRadius = 8
        heroIcon.layer.shadowOffset = .zero

        let heroTitle = UILabel()
        heroTitle.translatesAutoresizingMaskIntoConstraints = false
        heroTitle.text = "Hidden Games"
        heroTitle.font = .systemFont(ofSize: 26, weight: .bold).rounded
        heroTitle.textColor = fg

        let heroSub = UILabel()
        heroSub.translatesAutoresizingMaskIntoConstraints = false
        heroSub.text = "Real goals, saved progress — leave any time, resume later."
        heroSub.font = .systemFont(ofSize: 13, weight: .regular)
        heroSub.textColor = muted

        let heroText = UIStackView(arrangedSubviews: [heroTitle, heroSub])
        heroText.axis = .vertical
        heroText.spacing = 4
        heroText.translatesAutoresizingMaskIntoConstraints = false

        heroCard.addSubview(heroIcon)
        heroCard.addSubview(heroText)

        // Game cards.
        let games: [GameSlot] = [
            GameSlot(
                key: "2048", title: "2048", blurb: "Slide tiles · 4×4 up to 16×16 · resumes where you left off",
                glyph: "square.grid.4x3.fill",
                tint: UIColor(red: 0.93, green: 0.76, blue: 0.18, alpha: 1.0),
                glowRGB: (237, 194, 46),
                scoreKey: "g2048.bestTile",
                scoreFormat: { $0 == 0 ? "—" : "best tile \($0)" },
                selector: #selector(open2048)),
            GameSlot(
                key: "Mines", title: "Minesweeper", blurb: "Clear every safe tile · 24-level campaign",
                glyph: "flag.checkered",
                tint: UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1.0),
                glowRGB: (52, 211, 153),
                scoreKey: "mines.levels",
                scoreFormat: { $0 == 0 ? "—" : "\($0)/\(MinesweeperViewController.totalLevels) levels" },
                selector: #selector(openMines)),
            GameSlot(
                key: "Sokoban", title: "Sokoban", blurb: "Push crates onto goals · 20 puzzles, all solvable",
                glyph: "shippingbox.fill",
                tint: UIColor(red: 0.95, green: 0.62, blue: 0.26, alpha: 1.0),
                glowRGB: (242, 158, 66),
                scoreKey: "soko.levels",
                scoreFormat: { $0 == 0 ? "—" : "\($0)/\(SokobanViewController.totalLevels) solved" },
                selector: #selector(openSokoban)),
            GameSlot(
                key: "Codle", title: "Codle", blurb: "Guess the programming word · 6 tries · 20 words",
                glyph: "textformat",
                tint: UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1.0),
                glowRGB: (102, 166, 242),
                scoreKey: "codle.levels",
                scoreFormat: { $0 == 0 ? "—" : "\($0)/\(CodleViewController.totalLevels) words" },
                selector: #selector(openCodle)),
            GameSlot(
                key: "Lights", title: "Lights Out", blurb: "Toggle logic · turn every light off · 24 boards",
                glyph: "lightbulb.fill",
                tint: UIColor(red: 0.95, green: 0.78, blue: 0.35, alpha: 1.0),
                glowRGB: (242, 199, 89),
                scoreKey: "lights.levels",
                scoreFormat: { $0 == 0 ? "—" : "\($0)/\(LightsOutViewController.totalLevels) boards" },
                selector: #selector(openLights)),
            GameSlot(
                key: "Slide", title: "Slide 15", blurb: "Order the tiles · 3×3 → 5×5 · 18 boards",
                glyph: "square.grid.3x3.fill",
                tint: UIColor(red: 0.95, green: 0.45, blue: 0.55, alpha: 1.0),
                glowRGB: (242, 115, 140),
                scoreKey: "slide.levels",
                scoreFormat: { $0 == 0 ? "—" : "\($0)/\(SlidePuzzleViewController.totalLevels) solved" },
                selector: #selector(openSlide)),
        ]

        let cardsStack = UIStackView()
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        cardsStack.axis = .vertical
        cardsStack.spacing = 14

        gameSlots = games
        cardsStackRef = cardsStack
        for g in games {
            cardsStack.addArrangedSubview(makeGameCard(g))
        }

        // Footer hint.
        let footer = UILabel()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.text = "Long-press the BC badge in the sidebar to reveal the developer tools."
        footer.font = .systemFont(ofSize: 11, weight: .regular)
        footer.textColor = UIColor(white: 0.35, alpha: 1)
        footer.textAlignment = .center
        footer.numberOfLines = 0

        // Six cards no longer fit an iPhone screen — the card list
        // scrolls between the fixed hero and footer.
        let cardsScroll = UIScrollView()
        cardsScroll.translatesAutoresizingMaskIntoConstraints = false
        cardsScroll.showsVerticalScrollIndicator = false
        cardsScroll.alwaysBounceVertical = true
        view.addSubview(heroCard)
        view.addSubview(cardsScroll)
        cardsScroll.addSubview(cardsStack)
        view.addSubview(footer)

        let resetBtn = UIButton(type: .system)
        resetBtn.translatesAutoresizingMaskIntoConstraints = false
        resetBtn.setTitle("Reset high scores", for: .normal)
        resetBtn.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        resetBtn.setTitleColor(UIColor(white: 0.45, alpha: 1), for: .normal)
        resetBtn.addTarget(self, action: #selector(confirmResetScores), for: .touchUpInside)
        view.addSubview(resetBtn)

        NSLayoutConstraint.activate([
            heroCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            heroCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            heroCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            heroCard.heightAnchor.constraint(equalToConstant: 96),

            heroIcon.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor, constant: 22),
            heroIcon.centerYAnchor.constraint(equalTo: heroCard.centerYAnchor),
            heroIcon.widthAnchor.constraint(equalToConstant: 36),
            heroIcon.heightAnchor.constraint(equalToConstant: 36),

            heroText.leadingAnchor.constraint(equalTo: heroIcon.trailingAnchor, constant: 16),
            heroText.trailingAnchor.constraint(equalTo: heroCard.trailingAnchor, constant: -20),
            heroText.centerYAnchor.constraint(equalTo: heroCard.centerYAnchor),

            cardsScroll.topAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: 18),
            cardsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cardsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cardsScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            cardsStack.topAnchor.constraint(equalTo: cardsScroll.topAnchor, constant: 4),
            cardsStack.leadingAnchor.constraint(equalTo: cardsScroll.leadingAnchor, constant: 20),
            cardsStack.trailingAnchor.constraint(equalTo: cardsScroll.trailingAnchor, constant: -20),
            cardsStack.bottomAnchor.constraint(equalTo: cardsScroll.bottomAnchor, constant: -8),
            cardsStack.widthAnchor.constraint(equalTo: cardsScroll.widthAnchor, constant: -40),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: resetBtn.topAnchor, constant: -8),
            resetBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            resetBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])

        // Stash the hero glow + repaint frame when the layout settles.
        view.layoutIfNeeded()
        heroGlow.frame = heroCard.bounds
        Self.addGlowPulse(to: heroGlow, lo: 0.7, hi: 1.0, duration: 3.4)
    }

    private func makeGameCard(_ g: GameSlot) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.06).cgColor
        card.layer.borderWidth = 1
        card.isUserInteractionEnabled = true
        LiquidGlass.apply(to: card, corner: 14, dim: 0.30)

        // Subtle corner glow tinted to the game's accent.
        let glow = CAGradientLayer()
        glow.name = "hg.cardGlow"
        glow.type = .radial
        let (r8, g8, b8) = g.glowRGB
        let glowColor = UIColor(red: r8/255.0, green: g8/255.0, blue: b8/255.0, alpha: 1.0)
        glow.colors = [
            glowColor.withAlphaComponent(0.18).cgColor,
            glowColor.withAlphaComponent(0).cgColor,
        ]
        glow.locations = [0.0, 1.0]
        glow.startPoint = CGPoint(x: 1, y: 0)
        glow.endPoint   = CGPoint(x: 0.2, y: 1.4)
        card.layer.insertSublayer(glow, at: 0)

        // Left icon disc.
        let iconWrap = UIView()
        iconWrap.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.backgroundColor = g.tint.withAlphaComponent(0.10)
        iconWrap.layer.cornerRadius = 12
        iconWrap.layer.borderColor = g.tint.withAlphaComponent(0.28).cgColor
        iconWrap.layer.borderWidth = 1

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIImage(systemName: g.glyph,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        icon.tintColor = g.tint
        icon.contentMode = .scaleAspectFit
        iconWrap.addSubview(icon)

        // Right-side text stack.
        let titleLbl = UILabel()
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.text = g.title
        titleLbl.font = .systemFont(ofSize: 18, weight: .semibold).rounded
        titleLbl.textColor = fg

        let blurbLbl = UILabel()
        blurbLbl.translatesAutoresizingMaskIntoConstraints = false
        blurbLbl.text = g.blurb
        blurbLbl.font = .systemFont(ofSize: 12, weight: .regular)
        blurbLbl.textColor = muted

        let bestVal = HiddenGameScores.best(g.scoreKey)
        let bestLbl = UILabel()
        bestLbl.translatesAutoresizingMaskIntoConstraints = false
        bestLbl.text = "  " + g.scoreFormat(bestVal).uppercased() + "  "
        bestLbl.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        bestLbl.textColor = g.tint
        bestLbl.backgroundColor = g.tint.withAlphaComponent(0.10)
        bestLbl.layer.cornerRadius = 5
        bestLbl.layer.cornerCurve = .continuous
        bestLbl.layer.borderColor = g.tint.withAlphaComponent(0.30).cgColor
        bestLbl.layer.borderWidth = 0.5
        bestLbl.clipsToBounds = true

        // Secondary play-count chip (only once the game's been opened).
        let playsCount = HiddenGameScores.plays(g.scoreKey)
        let playsLbl = UILabel()
        playsLbl.translatesAutoresizingMaskIntoConstraints = false
        playsLbl.text = playsCount == 1 ? "1 PLAY" : "\(playsCount) PLAYS"
        playsLbl.font = .monospacedSystemFont(ofSize: 8, weight: .semibold)
        playsLbl.textColor = muted
        playsLbl.isHidden = (playsCount == 0)

        let textCol = UIStackView(arrangedSubviews: [titleLbl, blurbLbl])
        textCol.translatesAutoresizingMaskIntoConstraints = false
        textCol.axis = .vertical
        textCol.spacing = 3

        let chev = UIImageView()
        chev.translatesAutoresizingMaskIntoConstraints = false
        chev.image = UIImage(systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        chev.tintColor = UIColor(white: 0.35, alpha: 1)

        card.addSubview(iconWrap)
        card.addSubview(textCol)
        card.addSubview(bestLbl)
        card.addSubview(playsLbl)
        card.addSubview(chev)

        // Press feedback via a 0-duration long-press: scale the card down
        // on touch-down, restore + fire the game's selector on release.
        // Selector still runs once per tap, so push behavior is unchanged.
        let press = HGPressGesture(target: self, action: #selector(cardPressed(_:)))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = false
        press.gameSelector = g.selector
        card.addGestureRecognizer(press)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 84),

            iconWrap.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            iconWrap.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconWrap.widthAnchor.constraint(equalToConstant: 52),
            iconWrap.heightAnchor.constraint(equalToConstant: 52),

            icon.centerXAnchor.constraint(equalTo: iconWrap.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWrap.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),

            textCol.leadingAnchor.constraint(equalTo: iconWrap.trailingAnchor, constant: 14),
            textCol.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            textCol.trailingAnchor.constraint(lessThanOrEqualTo: bestLbl.leadingAnchor, constant: -10),

            bestLbl.trailingAnchor.constraint(equalTo: chev.leadingAnchor, constant: -10),
            bestLbl.centerYAnchor.constraint(equalTo: card.centerYAnchor, constant: playsCount == 0 ? 0 : -10),
            bestLbl.heightAnchor.constraint(equalToConstant: 18),
            playsLbl.trailingAnchor.constraint(equalTo: bestLbl.trailingAnchor, constant: -2),
            playsLbl.topAnchor.constraint(equalTo: bestLbl.bottomAnchor, constant: 2),

            chev.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            chev.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chev.widthAnchor.constraint(equalToConstant: 14),
            chev.heightAnchor.constraint(equalToConstant: 14),
        ])

        // Resize the glow once layout settles.
        DispatchQueue.main.async { glow.frame = card.bounds }
        Self.addGlowPulse(to: glow, lo: 0.55, hi: 1.0, duration: 4.0)
        return card
    }

    @objc private func cardPressed(_ g: HGPressGesture) {
        guard let card = g.view else { return }
        switch g.state {
        case .began:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            UIView.animate(withDuration: 0.10, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
                card.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
                card.alpha = 0.92
            }
        case .ended:
            UIView.animate(withDuration: 0.16, delay: 0,
                           usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5,
                           options: [.allowUserInteraction]) {
                card.transform = .identity
                card.alpha = 1
            }
            // Only fire if the touch lifted inside the card (a real tap).
            let p = g.location(in: card)
            if card.bounds.contains(p), let sel = g.gameSelector {
                perform(sel, with: nil, afterDelay: 0.02)
            }
        case .cancelled, .failed:
            UIView.animate(withDuration: 0.16) { card.transform = .identity; card.alpha = 1 }
        default: break
        }
    }

    @objc private func confirmResetScores() {
        let a = UIAlertController(
            title: "Reset all game progress?",
            message: "This clears best scores, play counts, campaign progress and saved games for all hidden games.",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            HiddenGameScores.resetAll()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            self?.rebuildCards()
        })
        present(a, animated: true)
    }
    private func rebuildCards() {
        guard let stack = cardsStackRef else { return }
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        for g in gameSlots { stack.addArrangedSubview(makeGameCard(g)) }
    }

    /// Gentle autoreversing opacity pulse for a decorative glow layer.
    /// Animation-only: never changes the layer's model opacity, so if it
    /// were stripped the glow just reverts to its original static look.
    private static func addGlowPulse(to layer: CALayer, lo: Float, hi: Float, duration: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = hi
        a.toValue = lo
        a.duration = duration
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "glowPulse")
    }

    @objc private func close()       { dismiss(animated: true) }
    @objc private func open2048() {
        HiddenGameScores.bumpPlays("g2048.bestTile")
        let n = UserDefaults.standard.object(forKey: "g2048.size") as? Int ?? 4
        navigationController?.pushViewController(Game2048ViewController(size: n), animated: true)
    }
    @objc private func openMines()   { HiddenGameScores.bumpPlays("mines.levels");   navigationController?.pushViewController(MinesweeperViewController(), animated: true) }
    @objc private func openSokoban() { HiddenGameScores.bumpPlays("soko.levels");    navigationController?.pushViewController(SokobanViewController(), animated: true) }
    @objc private func openCodle()   { HiddenGameScores.bumpPlays("codle.levels");   navigationController?.pushViewController(CodleViewController(), animated: true) }
    @objc private func openLights()  { HiddenGameScores.bumpPlays("lights.levels");  navigationController?.pushViewController(LightsOutViewController(), animated: true) }
    @objc private func openSlide()   { HiddenGameScores.bumpPlays("slide.levels");   navigationController?.pushViewController(SlidePuzzleViewController(), animated: true) }
}

// ════════════════════════════════════════════════════════════════════
// 1. 2048
// ════════════════════════════════════════════════════════════════════

final class Game2048ViewController: HGKeyboardGame {
    // Board is N×N, selectable 4…16. The classic game is 4×4; bigger
    // boards are simply a longer climb (same merge rules). The expectimax
    // "Win" solver is a 4×4 bitboard so it's offered on 4×4 only — the
    // LLM "AI" plays any size (it just reads the board as text).
    private var size: Int
    /// Per-size resume slot, so each board size keeps its own saved game.
    private var saveKey: String { "g2048.\(size)" }
    private var board: [[Int]] = []
    private var tiles: [[UILabel]] = []
    private let titleLabel = UILabel()
    private let scoreValueLabel = UILabel()
    private let bestValueLabel = UILabel()
    private var cellSide: CGFloat = 0
    private var score = 0
    private let grid = UIView()

    // ── Auto-play: "Win" (expectimax solver) + "AI" (installed LLM) ──
    private enum AutoPlay { case off, solver, ai }
    private var autoPlay: AutoPlay = .off
    private var performingAutoMove = false      // distinguishes solver/AI moves from a human swipe
    private var aiThinking = false              // single-flight guard for the LLM
    private var sawWin = false                  // fire the 2048 alert at most once
    private let statusLabel = UILabel()
    private let bg = UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
    private let gridBg = UIColor(red: 0.733, green: 0.678, blue: 0.627, alpha: 1)
    private let emptyTile = UIColor(red: 0.804, green: 0.749, blue: 0.694, alpha: 1)

    /// `size` is clamped to 4…16. Default 4 keeps the classic game and the
    /// existing call sites valid.
    init(size: Int = 4) {
        self.size = min(16, max(4, size))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) {
        self.size = 4
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        title = "2048 · \(size)×\(size)"
        // Reset · AI (LLM auto-play) · Win (expectimax solver → 16384).
        // Shown right-to-left, so the visible order from the edge is Win, AI, Reset.
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Reset", style: .plain, target: self, action: #selector(reset)),
            UIBarButtonItem(title: "AI",  style: .plain, target: self, action: #selector(toggleAI)),
            // "Win" runs the solver on every size: 4×4 uses the fast bitboard
            // expectimax, larger boards use the generic heuristic expectimax.
            UIBarButtonItem(title: "Win", style: .done, target: self, action: #selector(toggleSolver)),
        ]
        // Size picker sits next to the back button (doesn't replace it).
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(title: "\(size)×\(size)", style: .plain, target: self, action: #selector(chooseSize)),
        ]

        // Auto-play status banner (hidden unless the solver/AI is running).
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = UIColor(red: 0.93, green: 0.76, blue: 0.18, alpha: 1)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Tap anywhere on the board to stop auto-play (so touch users can take over).
        let stopTap = UITapGestureRecognizer(target: self, action: #selector(stopTapped))
        view.addGestureRecognizer(stopTap)

        // ── Header: big "2048" wordmark + SCORE / BEST cards ──────────
        titleLabel.text = "2048"
        titleLabel.font = .systemFont(ofSize: 36, weight: .heavy)
        titleLabel.textColor = UIColor(red: 0.93, green: 0.76, blue: 0.18, alpha: 1)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let cardsRow = UIStackView(arrangedSubviews: [
            makeScoreCard(caption: "SCORE", value: scoreValueLabel),
            makeScoreCard(caption: "BEST",  value: bestValueLabel),
        ])
        cardsRow.axis = .horizontal
        cardsRow.spacing = 8
        cardsRow.distribution = .fillEqually

        let header = UIStackView(arrangedSubviews: [titleLabel, cardsRow])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        grid.backgroundColor = gridBg
        grid.layer.cornerRadius = 12
        grid.layer.cornerCurve = .continuous
        grid.layer.shadowColor = UIColor.black.cgColor
        grid.layer.shadowOpacity = 0.35
        grid.layer.shadowRadius = 16
        grid.layer.shadowOffset = CGSize(width: 0, height: 8)
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)

        for r in 0..<size {
            var rowTiles: [UILabel] = []
            for c in 0..<size {
                let lbl = UILabel()
                lbl.textAlignment = .center
                lbl.font = .systemFont(ofSize: 32, weight: .bold)
                // Guarantee digits fit at any board size (16×16 tiles are tiny).
                lbl.adjustsFontSizeToFitWidth = true
                lbl.minimumScaleFactor = 0.3
                lbl.baselineAdjustment = .alignCenters
                lbl.layer.cornerRadius = 6
                lbl.layer.cornerCurve = .continuous
                lbl.layer.masksToBounds = true
                // Frame-positioned in viewDidLayoutSubviews — keep autoresizing
                // translation ON so the manual frame is respected (not zeroed
                // by Auto Layout, which would clump every tile into a corner).
                lbl.translatesAutoresizingMaskIntoConstraints = true
                grid.addSubview(lbl)
                _ = r; _ = c
                rowTiles.append(lbl)
            }
            tiles.append(rowTiles)
        }

        // Simple, conflict-free TOP-ANCHORED layout: header pinned near the
        // top, board directly below it, centered horizontally. Board width
        // targets 90% of the screen but is bounded to [240, 430] pt — the
        // required floor guarantees the board can NEVER collapse (which is
        // what made tiles clump into a corner), and the cap keeps it sane on
        // iPad. Height == width. No centerY / no over-constraint.
        let gridWidth = grid.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.9)
        gridWidth.priority = .defaultHigh
        // Let bigger boards use more of a wide screen (iPad) so 12×12 / 16×16
        // tiles stay playable; small boards keep the classic compact look.
        let maxBoard: CGFloat = size <= 6 ? 430 : 560
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: grid.leadingAnchor, constant: 2),
            header.trailingAnchor.constraint(equalTo: grid.trailingAnchor, constant: -2),

            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gridWidth,
            grid.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            grid.widthAnchor.constraint(lessThanOrEqualToConstant: maxBoard),
            grid.heightAnchor.constraint(equalTo: grid.widthAnchor),

            statusLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
        ])

        for dir in [UISwipeGestureRecognizer.Direction.left, .right, .up, .down] {
            let g = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            g.direction = dir
            view.addGestureRecognizer(g)
        }

        // Resume the saved game if one exists (long runs survive app
        // relaunches); otherwise deal a fresh board.
        if !restoreSavedGame() { reset() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard grid.bounds.width > 0 else { return }
        // Gap shrinks as the board grows so cells don't vanish on 16×16.
        let padFrac: CGFloat = size <= 5 ? 0.028 : (size <= 8 ? 0.016 : 0.009)
        let pad = max(2, grid.bounds.width * padFrac)
        let cellSize = (grid.bounds.width - pad * CGFloat(size + 1)) / CGFloat(size)
        guard cellSize > 0 else { return }   // board not yet sized — don't lay tiles into a corner
        cellSide = cellSize
        for r in 0..<size {
            for c in 0..<size {
                let t = tiles[r][c]
                t.frame = CGRect(
                    x: pad + CGFloat(c) * (cellSize + pad),
                    y: pad + CGFloat(r) * (cellSize + pad),
                    width: cellSize, height: cellSize)
                t.layer.cornerRadius = max(3, cellSize * 0.12)
                t.font = tileFont(for: Int(t.text ?? "") ?? 0)
            }
        }
    }

    /// Font that scales with the cell size and shrinks for longer numbers,
    /// so digits always fit no matter how big/small the board is laid out.
    private func tileFont(for n: Int) -> UIFont {
        let base = cellSide > 0 ? cellSide : 64
        let frac: CGFloat = n < 100 ? 0.46 : (n < 1000 ? 0.36 : 0.28)
        // Low floor + the label's adjustsFontSizeToFitWidth handles big boards.
        return .systemFont(ofSize: max(9, base * frac), weight: .bold)
    }

    /// A "SCORE"/"BEST" header card; `value` is wired so render() can update it.
    private func makeScoreCard(caption: String, value: UILabel) -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor(red: 0.071, green: 0.071, blue: 0.102, alpha: 1)
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.layer.borderColor = UIColor(red: 0.93, green: 0.76, blue: 0.18, alpha: 0.22).cgColor
        card.layer.borderWidth = 1

        let cap = UILabel()
        cap.text = caption
        cap.font = .systemFont(ofSize: 10, weight: .bold)
        cap.textColor = UIColor(white: 0.6, alpha: 1)
        cap.textAlignment = .center

        value.text = "0"
        value.font = .monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        value.textColor = .white
        value.textAlignment = .center

        let s = UIStackView(arrangedSubviews: [cap, value])
        s.axis = .vertical
        s.alignment = .center
        s.spacing = 1
        s.isLayoutMarginsRelativeArrangement = true
        s.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        s.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: card.topAnchor),
            s.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            s.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    @objc private func reset() {
        stopAutoPlay()
        sawWin = false
        // Persist the highest tile reached before wiping — beats just
        // tracking the raw score because "I made 2048" is the genuine
        // win condition.
        let priorMax = board.flatMap { $0 }.max() ?? 0
        HiddenGameScores.recordIfHigher("g2048.bestTile", priorMax)
        board = Array(repeating: Array(repeating: 0, count: size), count: size)
        score = 0
        spawn(); spawn()
        render()
        persistState(force: true)
    }

    // ── Long-game persistence ─────────────────────────────────────────
    // The board + score auto-save (throttled — solver-speed play would
    // otherwise hammer UserDefaults every frame) and restore on open, so
    // a long run isn't lost to an app relaunch or jetsam.
    private var lastPersist = Date.distantPast
    private func persistState(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPersist) > 0.4 else { return }
        lastPersist = Date()
        HiddenGameScores.saveBlob(saveKey, ["board": board, "score": score, "sawWin": sawWin])
    }

    @discardableResult
    private func restoreSavedGame() -> Bool {
        guard let o = HiddenGameScores.loadBlob(saveKey),
              let b = o["board"] as? [[Int]],
              b.count == size, b.allSatisfy({ $0.count == size }),
              b.flatMap({ $0 }).contains(where: { $0 != 0 })
        else { return false }
        board = b
        score = o["score"] as? Int ?? 0
        sawWin = o["sawWin"] as? Bool ?? false
        render()
        return true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persistState(force: true)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        // A human swipe/arrow during auto-play hands control back to the user.
        if !performingAutoMove && autoPlay != .off { stopAutoPlay() }
        let before = board
        let scoreBefore = score
        switch g.direction {
        case .left:  for r in 0..<size { board[r] = merge(board[r]) }
        case .right: for r in 0..<size { board[r] = merge(board[r].reversed()).reversed() }
        case .up:    for c in 0..<size {
            var col = (0..<size).map { board[$0][c] }
            col = merge(col)
            for r in 0..<size { board[r][c] = col[r] }
        }
        case .down:  for c in 0..<size {
            var col = (0..<size).map { board[$0][c] }
            col = merge(col.reversed()).reversed()
            for r in 0..<size { board[r][c] = col[r] }
        }
        default: break
        }
        if board != before {
            // Haptics for human play only — rapid auto-play would buzz nonstop.
            if autoPlay == .off {
                let merged = score > scoreBefore
                UIImpactFeedbackGenerator(style: merged ? .medium : .light).impactOccurred()
            }
            spawn()
            render()
            // Track the highest tile reached (covers 2048 / 4096 / 8192 / 16384).
            HiddenGameScores.recordIfHigher("g2048.bestTile", board.flatMap { $0 }.max() ?? 0)
            persistState()

            if isLost() {
                let wasAuto = autoPlay != .off
                stopAutoPlay()
                // A dead board shouldn't resume on next open.
                HiddenGameScores.clearBlob(saveKey)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                let topTile = board.flatMap { $0 }.max() ?? 0
                let a = UIAlertController(
                    title: wasAuto ? "Auto-play finished" : "Game over",
                    message: "No moves left. Best tile \(topTile) · score \(score).",
                    preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "Reset", style: .default) { _ in self.reset() })
                present(a, animated: true)
            } else if !sawWin && board.flatMap({ $0 }).contains(2048) {
                sawWin = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // While auto-playing, keep going silently toward 16384 — the
                // alert only interrupts a human player.
                if autoPlay == .off {
                    let a = UIAlertController(title: "🎉 2048!",
                                              message: "Score \(score). Keep going?",
                                              preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: "Keep going", style: .default))
                    a.addAction(UIAlertAction(title: "Reset", style: .cancel) { _ in self.reset() })
                    present(a, animated: true)
                }
            }
        }
    }

    private func merge(_ row: [Int]) -> [Int] {
        var nums = row.filter { $0 != 0 }
        var i = 0
        while i + 1 < nums.count {
            if nums[i] == nums[i + 1] {
                nums[i] *= 2
                score += nums[i]
                nums.remove(at: i + 1)
            }
            i += 1
        }
        while nums.count < size { nums.append(0) }
        return nums
    }

    private func spawn() {
        var empties: [(Int, Int)] = []
        for r in 0..<size { for c in 0..<size where board[r][c] == 0 { empties.append((r, c)) } }
        guard let cell = empties.randomElement() else { return }
        board[cell.0][cell.1] = Int.random(in: 0..<10) < 9 ? 2 : 4
    }

    private func isLost() -> Bool {
        for r in 0..<size { for c in 0..<size {
            if board[r][c] == 0 { return false }
            if c + 1 < size && board[r][c] == board[r][c+1] { return false }
            if r + 1 < size && board[r][c] == board[r+1][c] { return false }
        } }
        return true
    }

    private func render() {
        scoreValueLabel.text = "\(score)"
        bestValueLabel.text = "\(HiddenGameScores.best("g2048.bestTile"))"
        for r in 0..<size { for c in 0..<size {
            let n = board[r][c]
            let t = tiles[r][c]
            let prev = Int(t.text ?? "") ?? 0
            if n == 0 {
                t.text = ""
                t.backgroundColor = emptyTile
                t.transform = .identity
            } else {
                t.text = "\(n)"
                t.backgroundColor = tileColor(n)
                t.textColor = n <= 4 ? UIColor(red: 0.46, green: 0.43, blue: 0.40, alpha: 1) : .white
                t.font = tileFont(for: n)
                if autoPlay != .off {
                    // Auto-play: snap instantly (no per-tile spring/pulse) so
                    // the solver/AI can rip through moves fast.
                    t.transform = .identity
                } else if prev == 0 {
                    // Pop-in on tile spawn so swipes feel responsive.
                    t.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
                    UIView.animate(withDuration: 0.18, delay: 0,
                                   usingSpringWithDamping: 0.65,
                                   initialSpringVelocity: 0.8,
                                   options: [], animations: {
                        t.transform = .identity
                    })
                } else if n > prev {
                    // Merge pulse — tile value just doubled. A quick
                    // 1.15× bump-and-settle makes merges feel impactful
                    // without redoing the whole layout-tracking refactor
                    // that real movement animations would need.
                    t.transform = .identity
                    UIView.animate(withDuration: 0.12, delay: 0,
                                   options: [.curveEaseOut], animations: {
                        t.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
                    }, completion: { _ in
                        UIView.animate(withDuration: 0.10, delay: 0,
                                       options: [.curveEaseIn]) {
                            t.transform = .identity
                        }
                    })
                }
            }
        } }
    }

    private func tileColor(_ n: Int) -> UIColor {
        switch n {
        case 2:    return UIColor(red: 0.93, green: 0.89, blue: 0.85, alpha: 1)
        case 4:    return UIColor(red: 0.93, green: 0.88, blue: 0.78, alpha: 1)
        case 8:    return UIColor(red: 0.95, green: 0.69, blue: 0.47, alpha: 1)
        case 16:   return UIColor(red: 0.96, green: 0.58, blue: 0.39, alpha: 1)
        case 32:   return UIColor(red: 0.96, green: 0.49, blue: 0.37, alpha: 1)
        case 64:   return UIColor(red: 0.96, green: 0.37, blue: 0.23, alpha: 1)
        case 128:  return UIColor(red: 0.93, green: 0.81, blue: 0.45, alpha: 1)
        case 256:  return UIColor(red: 0.93, green: 0.80, blue: 0.38, alpha: 1)
        case 512:  return UIColor(red: 0.93, green: 0.78, blue: 0.31, alpha: 1)
        case 1024: return UIColor(red: 0.93, green: 0.77, blue: 0.25, alpha: 1)
        case 2048: return UIColor(red: 0.93, green: 0.76, blue: 0.18, alpha: 1)
        default:   return UIColor(red: 0.24, green: 0.22, blue: 0.20, alpha: 1)
        }
    }

    // MARK: - Magic Keyboard

    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        // Keep the nav pop-swipe from eating board swipes near the edge.
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override var keyCommands: [UIKeyCommand]? {
        // Arrow keys mirror the swipe gestures; R restarts.
        // wantsPriorityOverSystemBehavior = true so the editor's
        // global ⌘/ shortcut doesn't try to handle them while the
        // game is on screen.
        let cmds: [(String, Selector)] = [
            (UIKeyCommand.inputLeftArrow,  #selector(kbLeft)),
            (UIKeyCommand.inputRightArrow, #selector(kbRight)),
            (UIKeyCommand.inputUpArrow,    #selector(kbUp)),
            (UIKeyCommand.inputDownArrow,  #selector(kbDown)),
            ("r",                          #selector(reset)),
            ("R",                          #selector(reset)),
            ("w",                          #selector(toggleSolver)),  // Win = expectimax solver
            ("a",                          #selector(toggleAI)),      // AI  = installed LLM
            ("s",                          #selector(stopTapped)),    // stop auto-play
        ]
        return cmds.map { (input, sel) in
            let c = UIKeyCommand(input: input, modifierFlags: [], action: sel)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
    }

    @objc private func kbLeft()  { synthesizeSwipe(.left) }
    @objc private func kbRight() { synthesizeSwipe(.right) }
    @objc private func kbUp()    { synthesizeSwipe(.up) }
    @objc private func kbDown()  { synthesizeSwipe(.down) }

    /// Reuse the gesture-recognizer handler so keyboard and touch
    /// share the same merge / spawn / end-state logic. The swipe
    /// recognizer's `direction` is the only field `swiped(_:)`
    /// touches, so we can fake one.
    private func synthesizeSwipe(_ dir: UISwipeGestureRecognizer.Direction) {
        let fake = UISwipeGestureRecognizer()
        fake.direction = dir
        swiped(fake)
    }

    // MARK: - Auto-play control ("Win" solver + "AI" LLM)

    @objc private func stopTapped() { if autoPlay != .off { stopAutoPlay() } }

    @objc private func toggleSolver() {
        if autoPlay == .solver { stopAutoPlay() } else { startAutoPlay(.solver) }
    }

    // ── Board-size picker ─────────────────────────────────────────────
    @objc private func chooseSize() {
        stopAutoPlay()
        let sheet = UIAlertController(
            title: "Board size",
            message: "Pick a grid. Bigger boards are a longer climb; tiles auto-fit. Each size keeps its own saved game.",
            preferredStyle: .actionSheet)
        for n in [4, 5, 6, 8, 10, 12, 16] {
            var label = "\(n)×\(n)"
            if n == 4 { label += "  · classic" }
            if n == size { label = "✓ " + label }
            sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                self?.switchToSize(n)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController {   // iPad anchor
            pop.barButtonItem = navigationItem.leftBarButtonItems?.first
        }
        present(sheet, animated: true)
    }

    private func switchToSize(_ n: Int) {
        let clamped = min(16, max(4, n))
        UserDefaults.standard.set(clamped, forKey: "g2048.size")   // remembered default
        guard clamped != size else { return }
        persistState(force: true)   // keep this size's game before swapping
        let fresh = Game2048ViewController(size: clamped)
        if let nav = navigationController, !nav.viewControllers.isEmpty {
            var vcs = nav.viewControllers
            vcs[vcs.count - 1] = fresh   // replace the top VC in place
            nav.setViewControllers(vcs, animated: false)
        }
    }

    @objc private func toggleAI() {
        guard AIEngine.shared.runner != nil else {
            showAutoBanner("⚠️ No AI model loaded — load one from the AI tab first.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                if self?.autoPlay == .off { self?.statusLabel.isHidden = true }
            }
            return
        }
        if autoPlay == .ai { stopAutoPlay() } else { startAutoPlay(.ai) }
    }

    private func startAutoPlay(_ mode: AutoPlay) {
        autoPlay = mode
        sawWin = false   // let the run climb past 2048 without the win alert
        showAutoBanner(mode == .solver
            ? "🏆 Solver running — climbing toward 16384.   (tap board / press S to stop)"
            : "🤖 AI playing — the installed model picks each move.   (tap board / press S to stop)")
        if mode == .solver { stepSolver() } else { stepAI() }
    }

    private func stopAutoPlay() {
        autoPlay = .off
        statusLabel.isHidden = true
    }

    private func showAutoBanner(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }

    /// Apply a solver/AI-chosen move through the same merge/spawn/render path
    /// a human swipe uses, flagged so `swiped` doesn't treat it as a takeover.
    private func applyAutoMove(_ m: G2048Solver.Move) {
        performingAutoMove = true
        switch m {
        case .left:  synthesizeSwipe(.left)
        case .right: synthesizeSwipe(.right)
        case .up:    synthesizeSwipe(.up)
        case .down:  synthesizeSwipe(.down)
        }
        performingAutoMove = false
    }

    /// "Win": run the expectimax search OFF the main thread, apply on main,
    /// then schedule the next move after a short visible delay.
    private func stepSolver() {
        guard autoPlay == .solver else { return }
        let snapshot = board
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let mv = G2048Solver.bestMove(snapshot)
            DispatchQueue.main.async {
                guard let self, self.autoPlay == .solver else { return }
                guard let mv = mv else { self.stopAutoPlay(); return }
                self.applyAutoMove(mv)
                guard self.autoPlay == .solver else { return }   // loss / takeover may have stopped it
                // A tiny FIXED delay paces the moves. In solver mode tiles
                // snap instantly (no per-tile animation) and the search is now
                // a few ms, so 0.01 s ≈ 100 moves/s stays smooth (one render
                // per move) while running visibly faster. Lower still risks
                // CoreAnimation batching ("freeze, then a flurry").
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.stepSolver() }
            }
        }
    }

    /// "AI": the installed LLM picks each move; falls back to the solver when
    /// the model is slow / returns an illegal move, so the run never stalls.
    private func stepAI() {
        guard autoPlay == .ai, !aiThinking else { return }
        guard let runner = AIEngine.shared.runner else { stopAutoPlay(); return }
        aiThinking = true
        let snapshot = board
        let sys = ChatMessage(role: .system, content:
            "You are an expert 2048 player. Keep the largest tile pinned in one corner and keep rows/columns monotonic so tiles merge. Reply with EXACTLY one word — up, down, left, or right — nothing else.")
        let usr = ChatMessage(role: .user, content: G2048Solver.prompt(snapshot))
        // Speed knobs: tiny prompt + maxTokens 4 + stop at newline so the model
        // emits only the move word; the call is async so the UI stays smooth.
        runner.generate(messages: [sys, usr], maxTokens: 4, grammar: nil,
                        stopSequences: ["\n"], onToken: { _ in }) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.autoPlay == .ai else { return }
                self.aiThinking = false
                let parsed = G2048Solver.parseMove(try? result.get())
                if let mv = parsed, G2048Solver.move(self.board, mv).moved {
                    // Valid LLM move — apply it directly (cheap).
                    self.applyAutoMove(mv)
                    guard self.autoPlay == .ai else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.stepAI() }
                } else {
                    // Illegal/unparseable reply → compute the solver fallback
                    // OFF the main thread so it never hitches the UI.
                    let snap = self.board
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        let mv = G2048Solver.bestMove(snap)
                        DispatchQueue.main.async {
                            guard let self, self.autoPlay == .ai else { return }
                            guard let mv = mv else { self.stopAutoPlay(); return }
                            self.applyAutoMove(mv)
                            guard self.autoPlay == .ai else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.stepAI() }
                        }
                    }
                }
            }
        }
    }
}

// ════════════════════════════════════════════════════════════════════
// 2048 expectimax solver — pure, board-only. Powers the "Win" auto-play
// (and the AI mode's fallback). A monotonicity + smoothness + free-cells +
// max-value heuristic with depth-adaptive search reliably climbs to 16384.
// ════════════════════════════════════════════════════════════════════
fileprivate enum G2048Solver {
    enum Move: CaseIterable { case left, right, up, down }
    static let N = 4

    /// Slide + merge one line toward index 0 (the "left" primitive).
    private static func slide(_ line: [Int]) -> (line: [Int], gained: Int) {
        var nums = line.filter { $0 != 0 }
        var gained = 0
        var i = 0
        while i + 1 < nums.count {
            if nums[i] == nums[i + 1] {
                nums[i] *= 2
                gained += nums[i]
                nums.remove(at: i + 1)
            }
            i += 1
        }
        while nums.count < line.count { nums.append(0) }   // pad to the line's own length (any N)
        return (nums, gained)
    }

    /// Apply a move to a board copy → (new board, score gained, did-it-move).
    /// Size-agnostic: derives N from the board, so it's correct for 4×4…16×16
    /// (used by the generic solver AND the AI move-validity check).
    static func move(_ b: [[Int]], _ m: Move) -> (board: [[Int]], gained: Int, moved: Bool) {
        var nb = b
        var gained = 0
        let n = b.count
        switch m {
        case .left:
            for r in 0..<n { let s = slide(b[r]); nb[r] = s.line; gained += s.gained }
        case .right:
            for r in 0..<n { let s = slide(b[r].reversed()); nb[r] = Array(s.line.reversed()); gained += s.gained }
        case .up:
            for c in 0..<n {
                let col = (0..<n).map { b[$0][c] }
                let s = slide(col); gained += s.gained
                for r in 0..<n { nb[r][c] = s.line[r] }
            }
        case .down:
            for c in 0..<n {
                let col = (0..<n).map { b[$0][c] }
                let s = slide(col.reversed()); gained += s.gained
                let rev = Array(s.line.reversed())
                for r in 0..<n { nb[r][c] = rev[r] }
            }
        }
        return (nb, gained, nb != b)
    }

    // ════════════════════════════════════════════════════════════════
    // Generic Monte-Carlo solver — drives "Win" on every board size EXCEPT
    // 4×4 (which keeps the faster, stronger bitboard expectimax below). Pure
    // rollouts need NO hand-tuned evaluation function: for each legal first
    // move we play many short RANDOM games to a depth cap and average their
    // score; the move with the best average wins. Rollouts are "heavy" (half
    // greedy-by-merge, half random) so fewer are needed. This scales cleanly
    // to 16×16 with bounded cost and, unlike a deep expectimax, can never
    // hang — the random playouts do the evaluating. (Ronald's MC method; see
    // the well-known 2048-AI write-ups.)
    // ════════════════════════════════════════════════════════════════
    static func bestMoveGeneric(_ b: [[Int]]) -> Move? {
        let n = b.count
        // Flatten to a 1-D board (index r*n+c). The rollout hot loop runs on a
        // flat [Int] with in-place, allocation-free moves — ~6× faster than the
        // nested [[Int]] path (allocation is the dominant cost in MC rollouts).
        // dir codes: 0=up 1=down 2=left 3=right.
        var flat = [Int](repeating: 0, count: n * n)
        for r in 0..<n { for c in 0..<n { flat[r * n + c] = b[r][c] } }
        // Budget shrinks as the board grows so each decision stays fast.
        let rollouts = n <= 6 ? 25 : (n <= 10 ? 16 : 10)
        let depthCap = n <= 6 ? 70 : (n <= 10 ? 50 : 40)
        let dirToMove: [Move] = [.up, .down, .left, .right]
        // Evaluate the 4 first moves on separate cores. Each is fully
        // independent — its own board copies, and Swift's system RNG is
        // thread-safe — and results are written to DISTINCT buffer slots, so
        // there's no shared mutable state and no data race. concurrentPerform
        // is synchronous, so `buf` stays valid for the whole fan-out.
        let snapshot = flat
        var avg = [Double](repeating: -1, count: 4)
        avg.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: 4) { dir in
                var fb = snapshot
                let (g0, moved) = applyFlat(&fb, n, dir)
                if !moved { return }            // illegal first move → slot stays -1
                var total = 0.0
                for _ in 0..<rollouts { total += Double(rolloutFlat(fb, n, depthCap)) }
                buf[dir] = total / Double(rollouts) + Double(g0)
            }
        }
        var best: Move?
        var bestAvg = -1.0
        for dir in 0..<4 where avg[dir] > bestAvg { bestAvg = avg[dir]; best = dirToMove[dir] }
        return best
    }

    // Merge a strided line a[lo], a[lo+stride], … (n cells) toward index 0
    // (mergeLeft) or n-1 (mergeRight), in place, returning merge score. No
    // allocation — this is the allocation-free core the rollouts hammer.
    @inline(__always)
    private static func mergeLeftStrided(_ a: inout [Int], _ lo: Int, _ stride: Int, _ n: Int) -> Int {
        var gained = 0, write = 0, lastMerge = -1, read = 0
        while read < n {
            let v = a[lo + read * stride]
            if v == 0 { read += 1; continue }
            if write > 0 && a[lo + (write - 1) * stride] == v && lastMerge != write - 1 {
                let nv = v << 1; a[lo + (write - 1) * stride] = nv; gained += nv; lastMerge = write - 1
            } else {
                a[lo + write * stride] = v; write += 1
            }
            read += 1
        }
        while write < n { a[lo + write * stride] = 0; write += 1 }
        return gained
    }
    @inline(__always)
    private static func mergeRightStrided(_ a: inout [Int], _ lo: Int, _ stride: Int, _ n: Int) -> Int {
        var gained = 0, write = n - 1, lastMerge = -1, read = n - 1
        while read >= 0 {
            let v = a[lo + read * stride]
            if v == 0 { read -= 1; continue }
            if write < n - 1 && a[lo + (write + 1) * stride] == v && lastMerge != write + 1 {
                let nv = v << 1; a[lo + (write + 1) * stride] = nv; gained += nv; lastMerge = write + 1
            } else {
                a[lo + write * stride] = v; write -= 1
            }
            read -= 1
        }
        while write >= 0 { a[lo + write * stride] = 0; write -= 1 }
        return gained
    }

    /// Apply dir to a flat board IN PLACE → (gained, moved). 0=up 1=down 2=left 3=right.
    private static func applyFlat(_ b: inout [Int], _ n: Int, _ dir: Int) -> (Int, Bool) {
        let before = b
        var gained = 0
        switch dir {
        case 2: for r in 0..<n { gained += mergeLeftStrided(&b,  r * n, 1, n) }   // left
        case 3: for r in 0..<n { gained += mergeRightStrided(&b, r * n, 1, n) }   // right
        case 0: for c in 0..<n { gained += mergeLeftStrided(&b,  c,     n, n) }   // up
        default: for c in 0..<n { gained += mergeRightStrided(&b, c,    n, n) }   // down
        }
        return (gained, b != before)
    }

    /// Place a random tile (90% "2", 10% "4") in a random empty cell (flat).
    @inline(__always)
    private static func spawnFlat(_ b: inout [Int], _ n: Int) {
        var count = 0
        for v in b where v == 0 { count += 1 }
        if count == 0 { return }
        var pick = Int.random(in: 0..<count)
        for i in 0..<b.count where b[i] == 0 {
            if pick == 0 { b[i] = Int.random(in: 0..<10) < 9 ? 2 : 4; return }
            pick -= 1
        }
    }

    /// One heavy random playout (half greedy-by-merge, half random) on a flat
    /// board. Returns merge score + a small live-board bonus so a cut-short
    /// but still-playable board outranks a dead one of equal score.
    private static func rolloutFlat(_ start: [Int], _ n: Int, _ depthCap: Int) -> Int {
        var b = start
        spawnFlat(&b, n)
        var trial = [Int](repeating: 0, count: n * n)
        var score = 0, steps = 0
        while steps < depthCap {
            var bestGained = -1, bestDir = -1, legalCount = 0, legalMask = 0
            for d in 0..<4 {
                for i in 0..<b.count { trial[i] = b[i] }
                let (g, moved) = applyFlat(&trial, n, d)
                if moved { legalMask |= (1 << d); legalCount += 1; if g > bestGained { bestGained = g; bestDir = d } }
            }
            if legalCount == 0 { break }   // dead end
            var dir = bestDir
            if Double.random(in: 0..<1) >= 0.5 {     // random half among legal dirs
                var k = Int.random(in: 0..<legalCount)
                for d in 0..<4 where (legalMask & (1 << d)) != 0 { if k == 0 { dir = d; break }; k -= 1 }
            }
            score += applyFlat(&b, n, dir).0
            spawnFlat(&b, n)
            steps += 1
        }
        var empties = 0, maxTile = 0
        for v in b { if v == 0 { empties += 1 } else if v > maxTile { maxTile = v } }
        return score + empties * 4 + maxTile
    }

    // ════════════════════════════════════════════════════════════════
    // nneonneo bitboard expectimax — the reference strong 2048 AI.
    // Board = one UInt64, cell (r,c) at bits 16*r+4*c holding the log2
    // RANK (0 = empty, 1 = "2", 2 = "4", … 14 = 16384). Moves + the
    // heuristic are O(1) table lookups over precomputed 65536-row tables,
    // so it's allocation-free and fast enough to search deep (→ reaches
    // 8192 reliably and 16384 most games; ~94% per nneonneo). The exact
    // heuristic weights below are nneonneo's CMA-ES-tuned constants.
    // Reference: https://github.com/nneonneo/2048-ai
    // ════════════════════════════════════════════════════════════════

    private struct BBTables {
        var rowLeft  = [UInt16](repeating: 0, count: 65536)
        var rowRight = [UInt16](repeating: 0, count: 65536)
        var colUp    = [UInt64](repeating: 0, count: 65536)
        var colDown  = [UInt64](repeating: 0, count: 65536)
        var heur     = [Float](repeating: 0, count: 65536)
    }
    // Built once, lazily + thread-safely (static let). ~65k iterations.
    private static let T: BBTables = buildBBTables()

    private static func reverseRow(_ r: UInt16) -> UInt16 {
        (r >> 12) | ((r >> 4) & 0x00F0) | ((r << 4) & 0x0F00) | ((r << 12) & 0xF000)
    }
    private static func unpackCol(_ r: UInt16) -> UInt64 {
        let t = UInt64(r)
        return (t | (t << 12) | (t << 24) | (t << 36)) & 0x000F000F000F000F
    }
    private static func transpose(_ x: UInt64) -> UInt64 {
        let a1 = x & 0xF0F00F0FF0F00F0F
        let a2 = x & 0x0000F0F00000F0F0
        let a3 = x & 0x0F0F00000F0F0000
        let a  = a1 | (a2 << 12) | (a3 >> 12)
        let b1 = a & 0xFF00FF0000FF00FF
        let b2 = a & 0x00FF00FF00000000
        let b3 = a & 0x00000000FF00FF00
        return b1 | (b2 >> 24) | (b3 << 24)
    }

    /// Slide+merge a 4-rank line toward index 0 (the "left" primitive).
    private static func slideRanks(_ line0: [Int]) -> [Int] {
        var line = line0
        var i = 0
        while i < 3 {
            var j = i + 1
            while j < 4 && line[j] == 0 { j += 1 }
            if j == 4 { break }
            if line[i] == 0 {
                line[i] = line[j]; line[j] = 0; i -= 1
            } else if line[i] == line[j] && line[i] != 0xf {
                line[i] += 1; line[j] = 0
            }
            i += 1
        }
        return line
    }

    private static func buildBBTables() -> BBTables {
        var t = BBTables()
        for row in 0..<65536 {
            let line = [row & 0xf, (row >> 4) & 0xf, (row >> 8) & 0xf, (row >> 12) & 0xf]
            // ── heuristic (nneonneo) ──
            var sum: Float = 0
            var empty = 0, merges = 0, prev = 0, counter = 0
            for rank in line {
                sum += powf(Float(rank), 3.5)             // SCORE_SUM_POWER
                if rank == 0 { empty += 1 }
                else {
                    if prev == rank { counter += 1 }
                    else if counter > 0 { merges += 1 + counter; counter = 0 }
                    prev = rank
                }
            }
            if counter > 0 { merges += 1 + counter }
            var ml: Float = 0, mr: Float = 0
            for i in 1..<4 {
                let a = line[i - 1], b = line[i]
                if a > b { ml += powf(Float(a), 4) - powf(Float(b), 4) }   // SCORE_MONOTONICITY_POWER = 4
                else      { mr += powf(Float(b), 4) - powf(Float(a), 4) }
            }
            t.heur[row] = 200000.0                                // SCORE_LOST_PENALTY
                + 270.0 * Float(empty)                            // SCORE_EMPTY_WEIGHT
                + 700.0 * Float(merges)                           // SCORE_MERGES_WEIGHT
                - 47.0 * min(ml, mr)                              // SCORE_MONOTONICITY_WEIGHT
                - 11.0 * sum                                      // SCORE_SUM_WEIGHT
            // ── move tables (XOR deltas) ──
            let res = slideRanks(line)
            let urow = UInt16(truncatingIfNeeded: row)
            let rres = UInt16(truncatingIfNeeded: res[0] | (res[1] << 4) | (res[2] << 8) | (res[3] << 12))
            let rev = reverseRow(urow), revres = reverseRow(rres)
            t.rowLeft[row]        = urow ^ rres
            t.rowRight[Int(rev)]  = rev ^ revres
            t.colUp[row]          = unpackCol(urow) ^ unpackCol(rres)
            t.colDown[Int(rev)]   = unpackCol(rev) ^ unpackCol(revres)
        }
        return t
    }

    private static func execLeft(_ b: UInt64) -> UInt64 {
        b ^ (UInt64(T.rowLeft[Int((b >> 0) & 0xFFFF)]) << 0)
          ^ (UInt64(T.rowLeft[Int((b >> 16) & 0xFFFF)]) << 16)
          ^ (UInt64(T.rowLeft[Int((b >> 32) & 0xFFFF)]) << 32)
          ^ (UInt64(T.rowLeft[Int((b >> 48) & 0xFFFF)]) << 48)
    }
    private static func execRight(_ b: UInt64) -> UInt64 {
        b ^ (UInt64(T.rowRight[Int((b >> 0) & 0xFFFF)]) << 0)
          ^ (UInt64(T.rowRight[Int((b >> 16) & 0xFFFF)]) << 16)
          ^ (UInt64(T.rowRight[Int((b >> 32) & 0xFFFF)]) << 32)
          ^ (UInt64(T.rowRight[Int((b >> 48) & 0xFFFF)]) << 48)
    }
    private static func execUp(_ b: UInt64) -> UInt64 {
        let t = transpose(b)
        return b ^ (T.colUp[Int((t >> 0) & 0xFFFF)] << 0)
                 ^ (T.colUp[Int((t >> 16) & 0xFFFF)] << 4)
                 ^ (T.colUp[Int((t >> 32) & 0xFFFF)] << 8)
                 ^ (T.colUp[Int((t >> 48) & 0xFFFF)] << 12)
    }
    private static func execDown(_ b: UInt64) -> UInt64 {
        let t = transpose(b)
        return b ^ (T.colDown[Int((t >> 0) & 0xFFFF)] << 0)
                 ^ (T.colDown[Int((t >> 16) & 0xFFFF)] << 4)
                 ^ (T.colDown[Int((t >> 32) & 0xFFFF)] << 8)
                 ^ (T.colDown[Int((t >> 48) & 0xFFFF)] << 12)
    }

    private static func heurBoard(_ b: UInt64) -> Float {
        let t = transpose(b)
        return T.heur[Int((b >> 0) & 0xFFFF)] + T.heur[Int((b >> 16) & 0xFFFF)]
             + T.heur[Int((b >> 32) & 0xFFFF)] + T.heur[Int((b >> 48) & 0xFFFF)]
             + T.heur[Int((t >> 0) & 0xFFFF)] + T.heur[Int((t >> 16) & 0xFFFF)]
             + T.heur[Int((t >> 32) & 0xFFFF)] + T.heur[Int((t >> 48) & 0xFFFF)]
    }
    private static func countEmpty(_ b: UInt64) -> Int {
        var x = b, e = 0
        for _ in 0..<16 { if (x & 0xf) == 0 { e += 1 }; x >>= 4 }
        return e
    }
    private static func distinctTiles(_ b: UInt64) -> Int {
        var x = b, mask = 0
        for _ in 0..<16 { let v = Int(x & 0xf); if v != 0 { mask |= (1 << v) }; x >>= 4 }
        return mask.nonzeroBitCount
    }

    private static let cprobThresh: Float = 0.0001        // CPROB_THRESH_BASE

    private static func scoreMaxNode(_ b: UInt64, _ cprob: Float, _ depth: Int, _ lim: Int,
                                     _ memo: inout [UInt64: Float]) -> Float {
        var best: Float = 0
        for nb in [execUp(b), execDown(b), execLeft(b), execRight(b)] where nb != b {
            let s = scoreChanceNode(nb, cprob, depth, lim, &memo)
            if s > best { best = s }
        }
        return best
    }
    private static func scoreChanceNode(_ b: UInt64, _ cprob: Float, _ depth: Int, _ lim: Int,
                                        _ memo: inout [UInt64: Float]) -> Float {
        if cprob < cprobThresh || depth >= lim { return heurBoard(b) }
        if let cached = memo[b] { return cached }
        let empty = countEmpty(b)
        if empty == 0 { return heurBoard(b) }
        let cp = cprob / Float(empty)
        var total: Float = 0
        var x = b
        var i = 0
        while i < 16 {
            if (x & 0xf) == 0 {
                let shift = UInt64(4 * i)
                total += scoreMaxNode(b | (UInt64(1) << shift), cp * 0.9, depth + 1, lim, &memo) * 0.9
                total += scoreMaxNode(b | (UInt64(2) << shift), cp * 0.1, depth + 1, lim, &memo) * 0.1
            }
            x >>= 4
            i += 1
        }
        let res = total / Float(empty)
        memo[b] = res
        return res
    }

    private static func encode(_ vb: [[Int]]) -> UInt64 {
        var board: UInt64 = 0
        for r in 0..<4 { for c in 0..<4 {
            let v = vb[r][c]
            if v > 0 { board |= UInt64(v.trailingZeroBitCount) << UInt64(16 * r + 4 * c) }
        }}
        return board
    }

    /// Best move for the current board (nil if nothing moves) — bitboard
    /// expectimax with probability-cutoff pruning + a per-call transposition
    /// table. depth_limit grows with board complexity (nneonneo's rule), but
    /// the cprob cutoff keeps every search bounded and roughly uniform.
    /// Public entry point. The bitboard expectimax is a 4×4-only optimization
    /// (board packed into one UInt64 = 16 cells), so route non-4×4 boards to
    /// the generic heuristic expectimax below. Both return a move (or nil if
    /// the board is dead). Used by "Win" auto-play and the AI fallback.
    static func bestMove(_ vb: [[Int]]) -> Move? {
        return vb.count == 4 ? bestMove4x4(vb) : bestMoveGeneric(vb)
    }

    static func bestMove4x4(_ vb: [[Int]]) -> Move? {
        let board = encode(vb)
        // depth_limit = nneonneo's max(3, distinctTiles-2), but CAPPED at 6 so
        // the late game can't spike into a multi-hundred-ms search (keeps every
        // move uniformly fast). Per macroxue's data this depth band already
        // reaches 8192 ~every game and 16384 the large majority; the cprob
        // cutoff bounds it further. Lower the cap for more speed, raise it for
        // more strength — it's the single speed/strength knob.
        let lim = min(6, max(3, distinctTiles(board) - 2))
        let candidates: [(Move, UInt64)] = [
            (.up, execUp(board)), (.down, execDown(board)),
            (.left, execLeft(board)), (.right, execRight(board)),
        ]
        var best: Move?
        var bestScore: Float = -1
        for (mv, nb) in candidates where nb != board {
            var memo = [UInt64: Float](minimumCapacity: 4096)
            let s = scoreChanceNode(nb, 1.0, 0, lim, &memo)
            if s > bestScore { bestScore = s; best = mv }
        }
        return best
    }

    /// Compact board prompt for the LLM ("ai" mode).
    static func prompt(_ b: [[Int]]) -> String {
        let rows = b.map { $0.map { $0 == 0 ? "." : "\($0)" }.joined(separator: "\t") }.joined(separator: "\n")
        return "2048 board (. = empty):\n\(rows)\n\nBest move? up, down, left, or right?"
    }

    /// Parse the LLM reply into a move (first direction word, then first letter).
    static func parseMove(_ text: String?) -> Move? {
        guard let t = text?.lowercased() else { return nil }
        if t.contains("up")    { return .up }
        if t.contains("down")  { return .down }
        if t.contains("left")  { return .left }
        if t.contains("right") { return .right }
        for ch in t {
            switch ch {
            case "u": return .up
            case "d": return .down
            case "l": return .left
            case "r": return .right
            default: continue
            }
        }
        return nil
    }
}

// ════════════════════════════════════════════════════════════════════
// Shared: level-select grid for the campaign games
// ════════════════════════════════════════════════════════════════════

/// Compact level picker pushed by the campaign games. Grid of numbered
/// chips — ✓ green = solved, accent ring = playable, dimmed = locked.
final class HGLevelSelectViewController: UIViewController {
    private let total: Int
    private let done: Set<Int>
    private let unlocked: Int
    private let accent: UIColor
    private let onPick: (Int) -> Void

    init(title: String, total: Int, done: Set<Int>, unlocked: Int,
         accent: UIColor, onPick: @escaping (Int) -> Void) {
        self.total = total
        self.done = done
        self.unlocked = unlocked
        self.accent = accent
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1)

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let perRow = 6
        var i = 0
        while i < total {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 10
            row.distribution = .fillEqually
            for j in i..<min(i + perRow, total) { row.addArrangedSubview(makeChip(j)) }
            while row.arrangedSubviews.count < perRow { row.addArrangedSubview(UIView()) }
            grid.addArrangedSubview(row)
            i += perRow
        }

        let hint = UILabel()
        hint.text = "✓ solved · numbered = playable · dimmed = locked\nProgress saves automatically — leave any time."
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = UIColor(white: 0.4, alpha: 1)
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(grid)
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            hint.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func makeChip(_ idx: Int) -> UIButton {
        let solved = done.contains(idx)
        let open = idx <= unlocked
        let b = UIButton(type: .system)
        b.tag = idx
        b.setTitle(solved ? "✓" : "\(idx + 1)", for: .normal)
        b.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        b.layer.cornerRadius = 10
        b.layer.cornerCurve = .continuous
        b.layer.borderWidth = 1
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let good = UIColor(red: 0.30, green: 0.87, blue: 0.55, alpha: 1)
        if solved {
            b.setTitleColor(good, for: .normal)
            b.backgroundColor = good.withAlphaComponent(0.10)
            b.layer.borderColor = good.withAlphaComponent(0.35).cgColor
        } else if open {
            b.setTitleColor(accent, for: .normal)
            b.backgroundColor = accent.withAlphaComponent(0.08)
            b.layer.borderColor = accent.withAlphaComponent(0.40).cgColor
        } else {
            b.setTitleColor(UIColor(white: 0.32, alpha: 1), for: .normal)
            b.backgroundColor = UIColor(white: 1, alpha: 0.02)
            b.layer.borderColor = UIColor(white: 1, alpha: 0.05).cgColor
            b.isEnabled = false
        }
        b.addTarget(self, action: #selector(pick(_:)), for: .touchUpInside)
        return b
    }

    @objc private func pick(_ b: UIButton) {
        let idx = b.tag
        navigationController?.popViewController(animated: true)
        onPick(idx)
    }
}

// ════════════════════════════════════════════════════════════════════
// 2. Minesweeper — 24-level campaign
// ════════════════════════════════════════════════════════════════════
//
// Replaces the old endless Dungeon/Invaders pair with a game that has a
// real finish line: clear all 24 boards. Resource profile is deliberate:
// ZERO timers and ZERO display links — every redraw happens inside a tap
// handler, so idle CPU/battery cost is nil. The full mid-board state
// (mines, revealed, flags) is persisted after every action and restored
// on relaunch, so a long campaign survives app restarts and jetsam.

final class MinesweeperViewController: HGKeyboardGame {
    static let totalLevels = 24
    private static let cellGap: CGFloat = 2

    // Palette
    private let bg      = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1)
    private let hiddenC = UIColor(red: 0.165, green: 0.180, blue: 0.247, alpha: 1)
    private let openC   = UIColor(red: 0.082, green: 0.090, blue: 0.125, alpha: 1)
    private let mineRed = UIColor(red: 0.90, green: 0.30, blue: 0.30, alpha: 1)
    private let accent  = UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1)
    private let numColors: [UIColor] = [
        .clear,
        UIColor(red: 0.45, green: 0.65, blue: 1.00, alpha: 1),
        UIColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1),
        UIColor(red: 1.00, green: 0.45, blue: 0.45, alpha: 1),
        UIColor(red: 0.75, green: 0.55, blue: 1.00, alpha: 1),
        UIColor(red: 1.00, green: 0.70, blue: 0.35, alpha: 1),
        UIColor(red: 0.40, green: 0.85, blue: 0.85, alpha: 1),
        UIColor(red: 0.95, green: 0.85, blue: 0.40, alpha: 1),
        UIColor(red: 0.90, green: 0.90, blue: 0.95, alpha: 1),
    ]

    // Campaign progress
    private var levelIndex = 0
    private var doneLevels: Set<Int> = []
    private var unlocked = 0

    // Board model
    private var cols = 7
    private var rows = 9
    private var mineTotal = 7
    private var mines: Set<Int> = []
    private var revealed: Set<Int> = []
    private var flags: Set<Int> = []
    private var firstTapDone = false
    private var boardLocked = false
    private var explodedAt: Int? = nil

    // Views
    private let levelLabel = UILabel()
    private let minesLabel = UILabel()
    private let safeLabel = UILabel()
    private let flagButton = UIButton(type: .system)
    private let boardView = UIView()
    private var boardW: NSLayoutConstraint!
    private var boardH: NSLayoutConstraint!
    private var cellLayers: [CALayer] = []
    private var glyphLayers: [CATextLayer?] = []
    private var side: CGFloat = 32
    private var flagMode = false
    private var cursor: Int? = nil          // hardware-keyboard cell cursor
    private let cursorLayer = CALayer()

    /// 4 tiers of 6 levels: board grows, mine density ramps inside a tier.
    static func spec(_ i: Int) -> (cols: Int, rows: Int, mines: Int) {
        let t = min(max(i, 0) / 6, 3)
        let c = [7, 8, 9, 10][t]
        let r = [9, 10, 12, 13][t]
        let m = [7, 12, 20, 28][t] + (i % 6)
        return (c, r, m)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        title = "Minesweeper"
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Restart", style: .plain, target: self, action: #selector(restartLevel)),
            UIBarButtonItem(title: "Levels", style: .plain, target: self, action: #selector(showLevels)),
        ]

        levelLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        levelLabel.textColor = UIColor(white: 0.92, alpha: 1)
        minesLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        minesLabel.textColor = accent
        safeLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        safeLabel.textColor = UIColor(white: 0.65, alpha: 1)

        styleFlagButton()
        flagButton.addTarget(self, action: #selector(toggleFlagMode), for: .touchUpInside)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [levelLabel, spacer, safeLabel, minesLabel, flagButton])
        header.axis = .horizontal
        header.spacing = 10
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false

        boardView.translatesAutoresizingMaskIntoConstraints = false
        boardView.backgroundColor = .clear

        let tap = UITapGestureRecognizer(target: self, action: #selector(boardTapped(_:)))
        boardView.addGestureRecognizer(tap)
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(boardPressed(_:)))
        lp.minimumPressDuration = 0.3
        boardView.addGestureRecognizer(lp)

        let hint = UILabel()
        hint.text = "GOAL: open every ◻ safe tile — or flag all ✹ mines to finish instantly.\n"
            + "Tap = reveal · long-press / F = flag · keyboard: arrows + space + F"
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = UIColor(white: 0.38, alpha: 1)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(boardView)
        view.addSubview(hint)
        boardW = boardView.widthAnchor.constraint(equalToConstant: 100)
        boardH = boardView.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            boardView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            boardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            boardW, boardH,
            hint.topAnchor.constraint(equalTo: boardView.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        restoreOrStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persist()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        // The nav controller's edge/right-swipe pop gesture steals game
        // input ("swiping jumps to another page") — off while the board
        // is frontmost; the Back button still works.
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    // Hardware keyboard: arrows move the cell cursor, space / return
    // reveals, F flags, R restarts the level.
    override var keyCommands: [UIKeyCommand]? {
        func cmd(_ input: String, _ sel: Selector, _ title: String) -> UIKeyCommand {
            let c = UIKeyCommand(input: input, modifierFlags: [], action: sel)
            c.discoverabilityTitle = title
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        return [
            cmd(UIKeyCommand.inputUpArrow,    #selector(kbUp),    "Move up"),
            cmd(UIKeyCommand.inputDownArrow,  #selector(kbDown),  "Move down"),
            cmd(UIKeyCommand.inputLeftArrow,  #selector(kbLeft),  "Move left"),
            cmd(UIKeyCommand.inputRightArrow, #selector(kbRight), "Move right"),
            cmd(" ",  #selector(kbReveal), "Reveal tile"),
            cmd("\r", #selector(kbReveal), "Reveal tile"),
            cmd("f",  #selector(kbFlag),   "Flag tile"),
            cmd("r",  #selector(restartLevel), "Restart level"),
        ]
    }
    @objc private func kbUp()    { moveCursor(dr: -1, dc: 0) }
    @objc private func kbDown()  { moveCursor(dr: 1,  dc: 0) }
    @objc private func kbLeft()  { moveCursor(dr: 0,  dc: -1) }
    @objc private func kbRight() { moveCursor(dr: 0,  dc: 1) }
    @objc private func kbReveal() {
        guard !boardLocked, let c = cursor else { return }
        revealAction(c)
    }
    @objc private func kbFlag() {
        guard !boardLocked, let c = cursor else { return }
        toggleFlag(c)
    }
    private func moveCursor(dr: Int, dc: Int) {
        let start = cursor ?? (rows / 2) * cols + cols / 2
        let r = max(0, min(rows - 1, start / cols + dr))
        let c = max(0, min(cols - 1, start % cols + dc))
        cursor = r * cols + c
        positionCursor()
    }
    private func positionCursor() {
        guard let c = cursor, cellLayers.indices.contains(c) else {
            cursorLayer.isHidden = true
            return
        }
        cursorLayer.isHidden = false
        cursorLayer.frame = cellLayers[c].frame.insetBy(dx: -1.5, dy: -1.5)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let availW = view.bounds.width - 36
        let availH = view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom - 150
        let gap = Self.cellGap
        let s = min((availW - CGFloat(cols - 1) * gap) / CGFloat(cols),
                    (availH - CGFloat(rows - 1) * gap) / CGFloat(rows),
                    44)
        guard s > 8, abs(s - side) > 0.5 || cellLayers.count != cols * rows else { return }
        side = s
        layoutBoardLayers()
    }

    // ── Level lifecycle ───────────────────────────────────────────────

    private func startLevel(_ idx: Int) {
        levelIndex = max(0, min(idx, Self.totalLevels - 1))
        let s = Self.spec(levelIndex)
        cols = s.cols; rows = s.rows; mineTotal = s.mines
        mines = []; revealed = []; flags = []
        firstTapDone = false; boardLocked = false; explodedAt = nil
        cursor = nil
        rebuildBoardLayers()
        updateHUD()
        view.setNeedsLayout()
    }

    @objc private func restartLevel() {
        startLevel(levelIndex)
        persist()
    }

    @objc private func showLevels() {
        let sel = HGLevelSelectViewController(
            title: "Minesweeper — levels", total: Self.totalLevels,
            done: doneLevels, unlocked: unlocked, accent: accent) { [weak self] idx in
            self?.startLevel(idx)
            self?.persist()
        }
        navigationController?.pushViewController(sel, animated: true)
    }

    @objc private func toggleFlagMode() {
        flagMode.toggle()
        styleFlagButton()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func styleFlagButton() {
        flagButton.setTitle(flagMode ? "  ⚑ tap flags  " : "  ⚑ tap reveals  ", for: .normal)
        flagButton.titleLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        flagButton.setTitleColor(flagMode ? accent : UIColor(white: 0.55, alpha: 1), for: .normal)
        flagButton.layer.cornerRadius = 8
        flagButton.layer.borderWidth = 1
        flagButton.layer.borderColor = (flagMode ? accent.withAlphaComponent(0.5)
                                                 : UIColor(white: 1, alpha: 0.10)).cgColor
        flagButton.backgroundColor = flagMode ? accent.withAlphaComponent(0.10) : .clear
    }

    private func updateHUD() {
        levelLabel.text = "LEVEL \(levelIndex + 1)/\(Self.totalLevels)"
        minesLabel.text = "✹ \(max(0, mineTotal - flags.count))"
        // Live goal progress — THE answer to "how do I finish?": when
        // this hits 0 the board clears itself.
        let safeLeft = cols * rows - mineTotal - revealed.count
        safeLabel.text = "◻ \(max(0, safeLeft))"
    }

    // ── Board rendering (CALayer grid — no UIViews per cell) ─────────

    private func rebuildBoardLayers() {
        boardView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        cellLayers = []
        glyphLayers = Array(repeating: nil, count: cols * rows)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for _ in 0..<(cols * rows) {
            let l = CALayer()
            l.cornerRadius = 4
            l.cornerCurve = .continuous
            boardView.layer.addSublayer(l)
            cellLayers.append(l)
        }
        // Keyboard cursor ring sits above the cells.
        cursorLayer.borderColor = accent.cgColor
        cursorLayer.borderWidth = 2
        cursorLayer.cornerRadius = 5
        cursorLayer.cornerCurve = .continuous
        cursorLayer.isHidden = (cursor == nil)
        boardView.layer.addSublayer(cursorLayer)
        layoutBoardLayers()
        CATransaction.commit()
    }

    private func layoutBoardLayers() {
        guard cellLayers.count == cols * rows else { return }
        let gap = Self.cellGap
        boardW.constant = CGFloat(cols) * side + CGFloat(cols - 1) * gap
        boardH.constant = CGFloat(rows) * side + CGFloat(rows - 1) * gap
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<(cols * rows) {
            let r = i / cols, c = i % cols
            cellLayers[i].frame = CGRect(x: CGFloat(c) * (side + gap),
                                         y: CGFloat(r) * (side + gap),
                                         width: side, height: side)
            applyCellAppearance(i)
        }
        positionCursor()
        CATransaction.commit()
    }

    private func setGlyph(_ i: Int, _ text: String?, color: UIColor, size: CGFloat) {
        if let text = text {
            let tl: CATextLayer
            if let existing = glyphLayers[i] { tl = existing }
            else {
                tl = CATextLayer()
                tl.contentsScale = UIScreen.main.scale
                tl.alignmentMode = .center
                tl.font = CTFontCreateWithName("Menlo-Bold" as CFString, 0, nil)
                cellLayers[i].addSublayer(tl)
                glyphLayers[i] = tl
            }
            tl.string = text
            tl.fontSize = size
            tl.foregroundColor = color.cgColor
            let h = size * 1.3
            tl.frame = CGRect(x: 0, y: (side - h) / 2, width: side, height: h)
            tl.isHidden = false
        } else {
            glyphLayers[i]?.isHidden = true
        }
    }

    private func applyCellAppearance(_ i: Int) {
        let l = cellLayers[i]
        if revealed.contains(i) {
            if mines.contains(i) {
                l.backgroundColor = mineRed.withAlphaComponent(i == explodedAt ? 0.55 : 0.28).cgColor
                setGlyph(i, "✹", color: mineRed, size: side * 0.5)
            } else {
                l.backgroundColor = openC.cgColor
                let n = adjacentMines(i)
                setGlyph(i, n > 0 ? "\(n)" : nil, color: numColors[n], size: side * 0.5)
            }
        } else {
            l.backgroundColor = hiddenC.cgColor
            if flags.contains(i) {
                setGlyph(i, "⚑", color: accent, size: side * 0.5)
            } else if boardLocked, mines.contains(i) {
                // Lost: show every unflagged mine dimly.
                setGlyph(i, "✹", color: mineRed.withAlphaComponent(0.7), size: side * 0.45)
            } else {
                setGlyph(i, nil, color: .clear, size: side * 0.5)
            }
        }
    }

    private func refreshCells(_ changed: [Int]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in changed { applyCellAppearance(i) }
        CATransaction.commit()
    }

    // ── Model helpers ─────────────────────────────────────────────────

    private func neighbors(_ i: Int) -> [Int] {
        let r = i / cols, c = i % cols
        var out: [Int] = []
        for dr in -1...1 { for dc in -1...1 where !(dr == 0 && dc == 0) {
            let nr = r + dr, nc = c + dc
            if nr >= 0 && nr < rows && nc >= 0 && nc < cols { out.append(nr * cols + nc) }
        } }
        return out
    }

    private func adjacentMines(_ i: Int) -> Int {
        neighbors(i).reduce(0) { $0 + (mines.contains($1) ? 1 : 0) }
    }

    private func placeMines(avoiding safe: Int) {
        var pool = Array(0..<(cols * rows))
        let exclude = Set([safe] + neighbors(safe))
        pool.removeAll { exclude.contains($0) }
        pool.shuffle()
        mines = Set(pool.prefix(mineTotal))
    }

    // ── Input ─────────────────────────────────────────────────────────

    private func cellAt(_ p: CGPoint) -> Int? {
        let gap = Self.cellGap
        let c = Int(p.x / (side + gap)), r = Int(p.y / (side + gap))
        guard c >= 0, c < cols, r >= 0, r < rows, p.x >= 0, p.y >= 0 else { return nil }
        return r * cols + c
    }

    @objc private func boardTapped(_ g: UITapGestureRecognizer) {
        guard !boardLocked, let i = cellAt(g.location(in: boardView)) else { return }
        if flagMode { toggleFlag(i) } else { revealAction(i) }
    }

    @objc private func boardPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, !boardLocked,
              let i = cellAt(g.location(in: boardView)) else { return }
        toggleFlag(i)
    }

    private func toggleFlag(_ i: Int) {
        guard !boardLocked, !revealed.contains(i) else { return }
        if flags.contains(i) { flags.remove(i) } else { flags.insert(i) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        refreshCells([i])
        updateHUD()
        persist()
        // Flagging exactly the mines (and nothing else) finishes the
        // board — the intuitive "I marked them all, I'm done" move.
        // Remaining safe tiles auto-open and the win fires. A wrong
        // flag simply never matches, so this can't false-trigger.
        if firstTapDone, flags == mines {
            var changed: [Int] = []
            for c in 0..<(cols * rows) where !mines.contains(c) && !revealed.contains(c) {
                revealed.insert(c)
                changed.append(c)
            }
            refreshCells(changed)
            updateHUD()
            levelWon()
        }
    }

    private func revealAction(_ i: Int) {
        guard !revealed.contains(i), !flags.contains(i) else { return }
        if !firstTapDone {
            placeMines(avoiding: i)   // classic first-tap-safe
            firstTapDone = true
        }
        if mines.contains(i) { boom(i); return }
        // Iterative flood reveal of zero-neighbor regions.
        var changed: [Int] = []
        var stack = [i]
        while let cur = stack.popLast() {
            if revealed.contains(cur) || flags.contains(cur) || mines.contains(cur) { continue }
            revealed.insert(cur)
            changed.append(cur)
            if adjacentMines(cur) == 0 { stack.append(contentsOf: neighbors(cur)) }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        refreshCells(changed)
        updateHUD()
        persist()
        if revealed.count == cols * rows - mineTotal { levelWon() }
    }

    // ── Win / lose ────────────────────────────────────────────────────

    private func boom(_ i: Int) {
        boardLocked = true
        explodedAt = i
        revealed.insert(i)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        refreshCells(Array(mines) + [i])
        persist(includeBoard: false)   // a lost board never resumes
        let a = UIAlertController(
            title: "Boom 💥",
            message: "Hit a mine on level \(levelIndex + 1). No progress lost — try the board again.",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Retry level", style: .default) { _ in self.restartLevel() })
        a.addAction(UIAlertAction(title: "Stay (peek board)", style: .cancel))
        present(a, animated: true)
    }

    private func levelWon() {
        boardLocked = true
        doneLevels.insert(levelIndex)
        unlocked = min(max(unlocked, levelIndex + 1), Self.totalLevels - 1)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        persist(includeBoard: false)
        if doneLevels.count == Self.totalLevels {
            let c = ConfettiView(frame: view.bounds)
            view.addSubview(c)
            c.burst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { c.removeFromSuperview() }
            let a = UIAlertController(
                title: "🏆 Campaign complete!",
                message: "All \(Self.totalLevels) boards cleared. That's the whole campaign — you actually finished a hidden game.",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Nice", style: .default))
            present(a, animated: true)
        } else {
            let a = UIAlertController(
                title: "Board cleared ✓",
                message: "Level \(levelIndex + 1) done · \(doneLevels.count)/\(Self.totalLevels) solved.",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Next level", style: .default) { _ in
                self.startLevel(min(self.levelIndex + 1, Self.totalLevels - 1))
                self.persist()
            })
            a.addAction(UIAlertAction(title: "Stay", style: .cancel))
            present(a, animated: true)
        }
    }

    // ── Persistence (resume long campaigns across launches) ──────────

    private func persist(includeBoard: Bool = true) {
        var o: [String: Any] = ["unlocked": unlocked, "done": Array(doneLevels)]
        if includeBoard && firstTapDone && !boardLocked {
            o["cur"] = ["idx": levelIndex,
                        "mines": Array(mines),
                        "rev": Array(revealed),
                        "flag": Array(flags)] as [String: Any]
        }
        HiddenGameScores.saveBlob("mines", o)
        HiddenGameScores.recordIfHigher("mines.levels", doneLevels.count)
    }

    private func restoreOrStart() {
        let o = HiddenGameScores.loadBlob("mines") ?? [:]
        doneLevels = Set(o["done"] as? [Int] ?? [])
        unlocked = min(max(o["unlocked"] as? Int ?? 0, 0), Self.totalLevels - 1)
        if let cur = o["cur"] as? [String: Any],
           let idx = cur["idx"] as? Int, idx >= 0, idx < Self.totalLevels {
            let s = Self.spec(idx)
            let count = s.cols * s.rows
            let m = Set((cur["mines"] as? [Int] ?? []).filter { $0 >= 0 && $0 < count })
            let rev = Set((cur["rev"] as? [Int] ?? []).filter { $0 >= 0 && $0 < count })
            let fl = Set((cur["flag"] as? [Int] ?? []).filter { $0 >= 0 && $0 < count })
            if m.count == s.mines, m.isDisjoint(with: rev) {
                levelIndex = idx
                cols = s.cols; rows = s.rows; mineTotal = s.mines
                mines = m; revealed = rev; flags = fl
                firstTapDone = true; boardLocked = false; explodedAt = nil
                rebuildBoardLayers()
                updateHUD()
                view.setNeedsLayout()
                return
            }
        }
        startLevel(min(unlocked, Self.totalLevels - 1))
    }
}

// ════════════════════════════════════════════════════════════════════
// 3. Sokoban — 20 deterministic puzzles, every one provably solvable
// ════════════════════════════════════════════════════════════════════
//
// Levels are generated by REVERSE play: start from the solved state
// (every crate on its goal) and apply N random legal "pulls". Replaying
// the pulls backwards as pushes solves the level, so solvability is
// guaranteed by construction — no hand-authored level can be broken.
// A fixed per-level seed makes the campaign identical for everyone.
// Like Minesweeper above: no timers, no display link — pure tap/swipe
// driven, near-zero idle cost — and the mid-level state auto-saves.

/// Tiny deterministic PRNG (SplitMix64) so generated levels are stable
/// across launches and devices.
fileprivate struct HGRand {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
}

final class SokobanViewController: HGKeyboardGame {
    static let totalLevels = 20

    // Palette
    private let bg     = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1)
    private let floorC = UIColor(red: 0.075, green: 0.082, blue: 0.115, alpha: 1)
    private let wallC  = UIColor(red: 0.165, green: 0.180, blue: 0.247, alpha: 1)
    private let goalC  = UIColor(red: 0.30, green: 0.87, blue: 0.55, alpha: 1)
    private let boxC   = UIColor(red: 0.95, green: 0.62, blue: 0.26, alpha: 1)
    private let accent = UIColor(red: 0.95, green: 0.62, blue: 0.26, alpha: 1)
    private let playerC = UIColor(red: 0.659, green: 0.333, blue: 0.969, alpha: 1)

    // Campaign
    private var levelIndex = 0
    private var doneLevels: Set<Int> = []
    private var unlocked = 0
    private var bests: [String: Int] = [:]

    // Level model
    private var w = 7
    private var h = 7
    private var walls: Set<Int> = []
    private var goals: Set<Int> = []
    private var boxes: Set<Int> = []
    private var player = 0
    private var moves = 0
    private var undoStack: [(player: Int, boxFrom: Int?, boxTo: Int?)] = []

    // Views
    private let levelLabel = UILabel()
    private let movesLabel = UILabel()
    private let boardView = UIView()
    private var boardW: NSLayoutConstraint!
    private var boardH: NSLayoutConstraint!
    private var baseLayers: [CALayer] = []
    private var boxLayers: [Int: CALayer] = [:]
    private var playerLayer = CALayer()
    private var side: CGFloat = 36
    private static let gap: CGFloat = 2

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        title = "Sokoban"
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Reset", style: .plain, target: self, action: #selector(resetLevel)),
            UIBarButtonItem(title: "Undo", style: .plain, target: self, action: #selector(undoMove)),
            UIBarButtonItem(title: "Levels", style: .plain, target: self, action: #selector(showLevels)),
        ]

        levelLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        levelLabel.textColor = UIColor(white: 0.92, alpha: 1)
        movesLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        movesLabel.textColor = accent
        movesLabel.textAlignment = .right

        let header = UIStackView(arrangedSubviews: [levelLabel, UIView(), movesLabel])
        header.axis = .horizontal
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false

        boardView.translatesAutoresizingMaskIntoConstraints = false

        for dir: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let g = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            g.direction = dir
            view.addGestureRecognizer(g)
        }

        let hint = UILabel()
        hint.text = "GOAL: push every crate onto a ◎ ring.\n"
            + "Move: swipe or arrow keys · U / Z = undo · R = reset level"
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = UIColor(white: 0.38, alpha: 1)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(boardView)
        view.addSubview(hint)
        boardW = boardView.widthAnchor.constraint(equalToConstant: 100)
        boardH = boardView.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            boardView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            boardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            boardW, boardH,
            hint.topAnchor.constraint(equalTo: boardView.bottomAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        restoreOrStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persist()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        // Right-swipes were triggering the nav controller's pop gesture
        // ("the page swiped away") instead of moving the player — off
        // while the puzzle is frontmost; the Back button still works.
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    // Hardware keyboard: arrows move/push, U or Z undoes, R resets.
    override var keyCommands: [UIKeyCommand]? {
        func cmd(_ input: String, _ sel: Selector, _ title: String) -> UIKeyCommand {
            let c = UIKeyCommand(input: input, modifierFlags: [], action: sel)
            c.discoverabilityTitle = title
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        return [
            cmd(UIKeyCommand.inputUpArrow,    #selector(kbUp),    "Move up"),
            cmd(UIKeyCommand.inputDownArrow,  #selector(kbDown),  "Move down"),
            cmd(UIKeyCommand.inputLeftArrow,  #selector(kbLeft),  "Move left"),
            cmd(UIKeyCommand.inputRightArrow, #selector(kbRight), "Move right"),
            cmd("u", #selector(undoMove), "Undo"),
            cmd("z", #selector(undoMove), "Undo"),
            cmd("r", #selector(resetLevel), "Reset level"),
        ]
    }
    @objc private func kbUp()    { attemptMove(-w) }
    @objc private func kbDown()  { attemptMove(w) }
    @objc private func kbLeft()  { attemptMove(-1) }
    @objc private func kbRight() { attemptMove(1) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let availW = view.bounds.width - 36
        let availH = view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom - 150
        let g = Self.gap
        let s = min((availW - CGFloat(w - 1) * g) / CGFloat(w),
                    (availH - CGFloat(h - 1) * g) / CGFloat(h),
                    52)
        guard s > 10, abs(s - side) > 0.5 || baseLayers.count != w * h else { return }
        side = s
        layoutAllLayers()
    }

    // ── Deterministic level generation (reverse pulls) ───────────────

    private static func levelParams(_ i: Int) -> (w: Int, h: Int, boxes: Int, pulls: Int, wallPct: Int) {
        let w = 7 + min(i / 6, 3)            // 7…10
        let h = 7 + min(i / 5, 3)            // 7…10
        let boxes = 2 + min(i / 6, 2)        // 2…4
        let pulls = 8 + i * 2                // 8…46
        let wallPct = 10 + min(i, 8)         // 10…18 % interior walls
        return (w, h, boxes, pulls, wallPct)
    }

    private static func shifted(_ cell: Int, _ d: Int, _ w: Int, _ count: Int) -> Int? {
        let t = cell + d
        guard t >= 0, t < count else { return nil }
        if abs(d) == 1 && (t / w) != (cell / w) { return nil }
        return t
    }

    private static func reachable(from start: Int, walls: Set<Int>, boxes: Set<Int>,
                                  w: Int, count: Int) -> Set<Int> {
        var seen: Set<Int> = [start]
        var stack = [start]
        while let cur = stack.popLast() {
            for d in [-1, 1, -w, w] {
                guard let t = shifted(cur, d, w, count) else { continue }
                if seen.contains(t) || walls.contains(t) || boxes.contains(t) { continue }
                seen.insert(t)
                stack.append(t)
            }
        }
        return seen
    }

    /// Build level `idx`. Returns walls/goals plus the start boxes/player
    /// reached after N reverse pulls — solvable by construction.
    private static func generate(_ idx: Int)
        -> (w: Int, h: Int, walls: Set<Int>, goals: Set<Int>, boxes: Set<Int>, player: Int) {
        let p = levelParams(idx)
        var best: (score: Int, walls: Set<Int>, goals: Set<Int>, boxes: Set<Int>, player: Int)?
        for attempt in 0..<14 {
            var rng = HGRand(0x50C0BA11 &+ UInt64(idx) &* 1_000_003 &+ UInt64(attempt) &* 7_919)
            let count = p.w * p.h
            var walls: Set<Int> = []
            for i in 0..<count {
                let r = i / p.w, c = i % p.w
                if r == 0 || c == 0 || r == p.h - 1 || c == p.w - 1 { walls.insert(i) }
                else if rng.int(100) < p.wallPct { walls.insert(i) }
            }
            let open = (0..<count).filter { !walls.contains($0) }.sorted()
            guard open.count >= p.boxes * 2 + 4 else { continue }
            var pool = open
            var goals: Set<Int> = []
            while goals.count < p.boxes, !pool.isEmpty {
                goals.insert(pool.remove(at: rng.int(pool.count)))
            }
            guard goals.count == p.boxes, !pool.isEmpty else { continue }
            var boxes = goals                       // solved state
            var player = pool[rng.int(pool.count)]
            // Random pulls walk the puzzle backwards from solved.
            for _ in 0..<p.pulls {
                let reach = reachable(from: player, walls: walls, boxes: boxes, w: p.w, count: count)
                var cands: [(box: Int, stand: Int, dest: Int)] = []
                for b in boxes.sorted() {
                    for d in [-1, 1, -p.w, p.w] {
                        guard let stand = shifted(b, d, p.w, count),
                              let dest = shifted(stand, d, p.w, count) else { continue }
                        if walls.contains(stand) || walls.contains(dest) { continue }
                        if boxes.contains(stand) || boxes.contains(dest) { continue }
                        if !reach.contains(stand) { continue }
                        cands.append((b, stand, dest))
                    }
                }
                guard !cands.isEmpty else { break }
                let pick = cands[rng.int(cands.count)]
                boxes.remove(pick.box)
                boxes.insert(pick.stand)
                player = pick.dest
            }
            let displaced = boxes.subtracting(goals).count
            let scored = (displaced, walls, goals, boxes, player)
            if displaced == p.boxes {               // ideal: every crate off its goal
                return (p.w, p.h, walls, goals, boxes, player)
            }
            if best == nil || displaced > best!.score { best = scored }
        }
        if let b = best { return (p.w, p.h, b.walls, b.goals, b.boxes, b.player) }
        // Degenerate fallback (should never happen): trivial 1-push level.
        let w0 = 7, h0 = 7
        var walls0: Set<Int> = []
        for i in 0..<(w0 * h0) {
            let r = i / w0, c = i % w0
            if r == 0 || c == 0 || r == h0 - 1 || c == w0 - 1 { walls0.insert(i) }
        }
        return (w0, h0, walls0, [3 * w0 + 4], [3 * w0 + 3], 3 * w0 + 2)
    }

    // ── Level lifecycle ───────────────────────────────────────────────

    private func startLevel(_ idx: Int) {
        levelIndex = max(0, min(idx, Self.totalLevels - 1))
        let g = Self.generate(levelIndex)
        w = g.w; h = g.h
        walls = g.walls; goals = g.goals; boxes = g.boxes; player = g.player
        moves = 0
        undoStack = []
        rebuildAllLayers()
        updateHUD()
        view.setNeedsLayout()
    }

    @objc private func resetLevel() {
        startLevel(levelIndex)     // deterministic → identical board
        persist()
    }

    @objc private func showLevels() {
        let sel = HGLevelSelectViewController(
            title: "Sokoban — levels", total: Self.totalLevels,
            done: doneLevels, unlocked: unlocked, accent: accent) { [weak self] idx in
            self?.startLevel(idx)
            self?.persist()
        }
        navigationController?.pushViewController(sel, animated: true)
    }

    private func updateHUD() {
        levelLabel.text = "LEVEL \(levelIndex + 1)/\(Self.totalLevels)"
        if let best = bests["\(levelIndex)"] {
            movesLabel.text = "MOVES \(moves) · BEST \(best)"
        } else {
            movesLabel.text = "MOVES \(moves)"
        }
    }

    // ── Rendering ─────────────────────────────────────────────────────

    private func cellFrame(_ i: Int) -> CGRect {
        let g = Self.gap
        let r = i / w, c = i % w
        return CGRect(x: CGFloat(c) * (side + g), y: CGFloat(r) * (side + g),
                      width: side, height: side)
    }

    private func rebuildAllLayers() {
        boardView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        baseLayers = []
        boxLayers = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<(w * h) {
            let l = CALayer()
            l.cornerRadius = 4
            l.cornerCurve = .continuous
            if walls.contains(i) {
                l.backgroundColor = wallC.cgColor
            } else {
                l.backgroundColor = floorC.cgColor
                if goals.contains(i) {
                    let dot = CALayer()
                    dot.name = "goalDot"
                    dot.borderColor = goalC.withAlphaComponent(0.8).cgColor
                    dot.borderWidth = 2
                    l.addSublayer(dot)
                }
            }
            boardView.layer.addSublayer(l)
            baseLayers.append(l)
        }
        for b in boxes {
            let l = CALayer()
            l.cornerRadius = 6
            l.cornerCurve = .continuous
            boardView.layer.addSublayer(l)
            boxLayers[b] = l
        }
        playerLayer = CALayer()
        boardView.layer.addSublayer(playerLayer)
        layoutAllLayers()
        CATransaction.commit()
    }

    private func layoutAllLayers() {
        guard baseLayers.count == w * h else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<(w * h) {
            baseLayers[i].frame = cellFrame(i)
            if let dot = baseLayers[i].sublayers?.first(where: { $0.name == "goalDot" }) {
                let inset = side * 0.32
                dot.frame = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
                dot.cornerRadius = (side - inset * 2) / 2
            }
        }
        for (cell, l) in boxLayers {
            l.frame = cellFrame(cell).insetBy(dx: side * 0.08, dy: side * 0.08)
            l.backgroundColor = (goals.contains(cell) ? goalC : boxC).cgColor
        }
        playerLayer.frame = cellFrame(player).insetBy(dx: side * 0.16, dy: side * 0.16)
        playerLayer.cornerRadius = (side - side * 0.32) / 2
        playerLayer.backgroundColor = playerC.cgColor
        boardW.constant = CGFloat(w) * side + CGFloat(w - 1) * Self.gap
        boardH.constant = CGFloat(h) * side + CGFloat(h - 1) * Self.gap
        CATransaction.commit()
    }

    // ── Input / movement ─────────────────────────────────────────────

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        let d: Int
        switch g.direction {
        case .left:  d = -1
        case .right: d = 1
        case .up:    d = -w
        default:     d = w
        }
        attemptMove(d)
    }

    private func attemptMove(_ d: Int) {
        let count = w * h
        guard let t = Self.shifted(player, d, w, count), !walls.contains(t) else { return }
        if boxes.contains(t) {
            guard let t2 = Self.shifted(t, d, w, count),
                  !walls.contains(t2), !boxes.contains(t2) else { return }
            undoStack.append((player, t, t2))
            if undoStack.count > 400 { undoStack.removeFirst() }
            boxes.remove(t)
            boxes.insert(t2)
            if let l = boxLayers.removeValue(forKey: t) {
                boxLayers[t2] = l
                // Implicit CALayer animation gives a cheap, smooth slide.
                l.frame = cellFrame(t2).insetBy(dx: side * 0.08, dy: side * 0.08)
                l.backgroundColor = (goals.contains(t2) ? goalC : boxC).cgColor
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            undoStack.append((player, nil, nil))
            if undoStack.count > 400 { undoStack.removeFirst() }
        }
        player = t
        playerLayer.frame = cellFrame(player).insetBy(dx: side * 0.16, dy: side * 0.16)
        moves += 1
        updateHUD()
        persist()
        if boxes == goals { levelWon() }
    }

    @objc private func undoMove() {
        guard let u = undoStack.popLast() else { return }
        if let from = u.boxFrom, let to = u.boxTo {
            boxes.remove(to)
            boxes.insert(from)
            if let l = boxLayers.removeValue(forKey: to) {
                boxLayers[from] = l
                l.frame = cellFrame(from).insetBy(dx: side * 0.08, dy: side * 0.08)
                l.backgroundColor = (goals.contains(from) ? goalC : boxC).cgColor
            }
        }
        player = u.player
        playerLayer.frame = cellFrame(player).insetBy(dx: side * 0.16, dy: side * 0.16)
        moves = max(0, moves - 1)
        updateHUD()
        persist()
    }

    private func levelWon() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        doneLevels.insert(levelIndex)
        unlocked = min(max(unlocked, levelIndex + 1), Self.totalLevels - 1)
        let key = "\(levelIndex)"
        if bests[key] == nil || moves < bests[key]! { bests[key] = moves }
        persist(includeBoard: false)
        updateHUD()
        if doneLevels.count == Self.totalLevels {
            let c = ConfettiView(frame: view.bounds)
            view.addSubview(c)
            c.burst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { c.removeFromSuperview() }
            let a = UIAlertController(
                title: "🏆 All 20 solved!",
                message: "Every crate on every goal. Campaign complete.",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Nice", style: .default))
            present(a, animated: true)
        } else {
            let a = UIAlertController(
                title: "Solved ✓",
                message: "Level \(levelIndex + 1) in \(moves) moves · \(doneLevels.count)/\(Self.totalLevels) done.",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Next level", style: .default) { _ in
                self.startLevel(min(self.levelIndex + 1, Self.totalLevels - 1))
                self.persist()
            })
            a.addAction(UIAlertAction(title: "Stay", style: .cancel))
            present(a, animated: true)
        }
    }

    // ── Persistence ───────────────────────────────────────────────────

    private func persist(includeBoard: Bool = true) {
        var o: [String: Any] = ["unlocked": unlocked,
                                "done": Array(doneLevels),
                                "bests": bests]
        if includeBoard && boxes != goals {
            o["cur"] = ["idx": levelIndex,
                        "boxes": Array(boxes),
                        "player": player,
                        "moves": moves] as [String: Any]
        }
        HiddenGameScores.saveBlob("soko", o)
        HiddenGameScores.recordIfHigher("soko.levels", doneLevels.count)
    }

    private func restoreOrStart() {
        let o = HiddenGameScores.loadBlob("soko") ?? [:]
        doneLevels = Set(o["done"] as? [Int] ?? [])
        unlocked = min(max(o["unlocked"] as? Int ?? 0, 0), Self.totalLevels - 1)
        bests = o["bests"] as? [String: Int] ?? [:]
        if let cur = o["cur"] as? [String: Any],
           let idx = cur["idx"] as? Int, idx >= 0, idx < Self.totalLevels {
            startLevel(idx)        // regenerates identical walls/goals
            let count = w * h
            let savedBoxes = Set((cur["boxes"] as? [Int] ?? []).filter { $0 >= 0 && $0 < count })
            let savedPlayer = cur["player"] as? Int ?? -1
            let free: (Int) -> Bool = { !self.walls.contains($0) }
            if savedBoxes.count == goals.count,
               savedBoxes.allSatisfy(free),
               savedPlayer >= 0, savedPlayer < count, free(savedPlayer),
               !savedBoxes.contains(savedPlayer) {
                boxes = savedBoxes
                player = savedPlayer
                moves = cur["moves"] as? Int ?? 0
                undoStack = []
                rebuildAllLayers()
                updateHUD()
            }
            return
        }
        startLevel(min(unlocked, Self.totalLevels - 1))
    }
}

// ════════════════════════════════════════════════════════════════════
// 4. Codle — Wordle-style deduction over a Python/CS vocabulary
// ════════════════════════════════════════════════════════════════════
//
// The most instantly-understood mechanic in modern puzzling, themed
// for a code app: guess the 5-letter programming word in 6 tries.
// 20-level campaign, deterministic per level. Touch keyboard on
// screen, full hardware-keyboard typing via pressesBegan. Like the
// other games: zero timers, auto-saved mid-game, pop-gesture safe.

final class CodleViewController: HGKeyboardGame {
    static let totalLevels = 20

    private static let words: [String] = [
        "array", "tuple", "yield", "async", "await", "class", "print", "input",
        "range", "float", "break", "while", "super", "raise", "slice", "index",
        "debug", "stack", "queue", "graph", "torch", "numpy", "mutex", "cache",
        "regex", "bytes", "codec", "scope", "shell", "patch", "merge", "fetch",
        "clone", "build", "metal", "swift", "xcode", "table", "field", "value",
        "const", "types", "macro", "actor", "frame", "layer", "pixel", "blend",
        "model", "token", "parse", "lexer", "tests", "fuzzy", "crash", "panic",
        "fatal", "error", "throw", "catch", "trace", "probe", "bench", "bound",
        "logic", "proof", "sigma", "delta", "gamma",
    ]
    static func word(for level: Int) -> String {
        words[(level * 37 + 11) % words.count]
    }

    // Palette
    private let bg      = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1)
    private let tileBg  = UIColor(red: 0.110, green: 0.120, blue: 0.165, alpha: 1)
    private let exactC  = UIColor(red: 0.30, green: 0.78, blue: 0.45, alpha: 1)
    private let nearC   = UIColor(red: 0.93, green: 0.76, blue: 0.18, alpha: 1)
    private let absentC = UIColor(red: 0.165, green: 0.170, blue: 0.215, alpha: 1)
    private let accent  = UIColor(red: 0.40, green: 0.65, blue: 0.95, alpha: 1)

    // Campaign
    private var levelIndex = 0
    private var doneLevels: Set<Int> = []
    private var unlocked = 0

    // Round state
    private var target = "array"
    private var guesses: [String] = []          // submitted rows
    private var current = ""                    // row being typed
    private var roundOver = false
    /// Best known state per letter: 0 unknown · 1 absent · 2 present · 3 exact
    private var letterStates: [Character: Int] = [:]

    // Views
    private let levelLabel = UILabel()
    private let triesLabel = UILabel()
    private let gridView = UIView()
    private var gridW: NSLayoutConstraint!
    private var gridH: NSLayoutConstraint!
    private var tileLayers: [[CALayer]] = []
    private var tileGlyphs: [[CATextLayer]] = []
    private var keyButtons: [Character: UIButton] = [:]
    private var side: CGFloat = 48
    private static let gap: CGFloat = 5

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        title = "Codle"
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Restart", style: .plain, target: self, action: #selector(restartLevel)),
            UIBarButtonItem(title: "Levels", style: .plain, target: self, action: #selector(showLevels)),
        ]

        levelLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        levelLabel.textColor = UIColor(white: 0.92, alpha: 1)
        triesLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        triesLabel.textColor = accent
        triesLabel.textAlignment = .right

        let header = UIStackView(arrangedSubviews: [levelLabel, UIView(), triesLabel])
        header.axis = .horizontal
        header.translatesAutoresizingMaskIntoConstraints = false

        gridView.translatesAutoresizingMaskIntoConstraints = false

        let hint = UILabel()
        hint.text = "Guess the 5-letter programming word · 6 tries\n"
            + "green = right spot · yellow = wrong spot · type on either keyboard"
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = UIColor(white: 0.38, alpha: 1)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false

        let kb = buildKeyboard()

        view.addSubview(header)
        view.addSubview(gridView)
        view.addSubview(hint)
        view.addSubview(kb)
        gridW = gridView.widthAnchor.constraint(equalToConstant: 100)
        gridH = gridView.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            gridView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            gridView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gridW, gridH,

            hint.topAnchor.constraint(equalTo: gridView.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            kb.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            kb.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            kb.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        buildGridLayers()
        restoreOrStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persist()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let availW = view.bounds.width - 40
        let s = min((availW - Self.gap * 4) / 5, 52)
        guard s > 20, abs(s - side) > 0.5 else { return }
        side = s
        layoutGridLayers()
    }

    // ── Hardware keyboard (typing) ────────────────────────────────────

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if key.modifierFlags.contains(.command) { continue }   // leave ⌘ shortcuts alone
            switch key.keyCode {
            case .keyboardReturnOrEnter, .keypadEnter:
                submitGuess(); handled = true
            case .keyboardDeleteOrBackspace:
                deleteLetter(); handled = true
            default:
                let chars = key.charactersIgnoringModifiers.lowercased()
                if chars.count == 1, let ch = chars.first, ch >= "a", ch <= "z" {
                    typeLetter(ch); handled = true
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    // ── On-screen keyboard ────────────────────────────────────────────

    private func buildKeyboard() -> UIView {
        let rows = ["qwertyuiop", "asdfghjkl", "*zxcvbnm<"]   // * = enter, < = delete
        let col = UIStackView()
        col.axis = .vertical
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false
        for r in rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 5
            row.distribution = .fillProportionally
            for ch in r {
                let b = UIButton(type: .system)
                b.layer.cornerRadius = 7
                b.layer.cornerCurve = .continuous
                b.backgroundColor = UIColor(white: 0.16, alpha: 1)
                b.heightAnchor.constraint(equalToConstant: 42).isActive = true
                switch ch {
                case "*":
                    b.setTitle("⏎", for: .normal)
                    b.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
                    b.setTitleColor(accent, for: .normal)
                    b.addTarget(self, action: #selector(enterTapped), for: .touchUpInside)
                case "<":
                    b.setTitle("⌫", for: .normal)
                    b.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
                    b.setTitleColor(UIColor(white: 0.8, alpha: 1), for: .normal)
                    b.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
                default:
                    b.setTitle(String(ch).uppercased(), for: .normal)
                    b.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
                    b.setTitleColor(UIColor(white: 0.92, alpha: 1), for: .normal)
                    b.addTarget(self, action: #selector(letterTapped(_:)), for: .touchUpInside)
                    keyButtons[ch] = b
                }
                row.addArrangedSubview(b)
            }
            col.addArrangedSubview(row)
        }
        return col
    }

    @objc private func letterTapped(_ b: UIButton) {
        guard let t = b.currentTitle?.lowercased().first else { return }
        typeLetter(t)
    }
    @objc private func enterTapped()  { submitGuess() }
    @objc private func deleteTapped() { deleteLetter() }

    // ── Round mechanics ───────────────────────────────────────────────

    private func typeLetter(_ ch: Character) {
        guard !roundOver, current.count < 5 else { return }
        current.append(ch)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        renderCurrentRow()
    }

    private func deleteLetter() {
        guard !roundOver, !current.isEmpty else { return }
        current.removeLast()
        renderCurrentRow()
    }

    private func submitGuess() {
        guard !roundOver, current.count == 5 else { return }
        let guess = current
        guesses.append(guess)
        current = ""
        applyColors(row: guesses.count - 1, guess: guess)
        persist()
        if guess == target {
            roundOver = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            levelWon()
        } else if guesses.count >= 6 {
            roundOver = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            persist(includeRound: false)
            let a = UIAlertController(
                title: "Out of tries",
                message: "The word was “\(target.uppercased())”. No progress lost — go again.",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Retry level", style: .default) { _ in self.restartLevel() })
            a.addAction(UIAlertAction(title: "Stay", style: .cancel))
            present(a, animated: true)
        } else {
            renderCurrentRow()
        }
        updateHUD()
    }

    /// Wordle scoring with correct duplicate handling.
    private func score(_ guess: String) -> [Int] {
        let g = Array(guess), t = Array(target)
        var res = [Int](repeating: 1, count: 5)
        var remaining: [Character: Int] = [:]
        for i in 0..<5 where g[i] != t[i] { remaining[t[i], default: 0] += 1 }
        for i in 0..<5 where g[i] == t[i] { res[i] = 3 }
        for i in 0..<5 where res[i] != 3 {
            if remaining[g[i], default: 0] > 0 {
                res[i] = 2
                remaining[g[i]]! -= 1
            }
        }
        return res
    }

    private func applyColors(row: Int, guess: String) {
        let res = score(guess)
        let g = Array(guess)
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        for i in 0..<5 {
            let color: UIColor = res[i] == 3 ? exactC : (res[i] == 2 ? nearC : absentC)
            tileLayers[row][i].backgroundColor = color.cgColor
            tileGlyphs[row][i].string = String(g[i]).uppercased()
            tileGlyphs[row][i].foregroundColor = UIColor.white.cgColor
            letterStates[g[i]] = max(letterStates[g[i], default: 0], res[i])
        }
        CATransaction.commit()
        for (ch, st) in letterStates {
            guard let b = keyButtons[ch] else { continue }
            switch st {
            case 3: b.backgroundColor = exactC.withAlphaComponent(0.85)
            case 2: b.backgroundColor = nearC.withAlphaComponent(0.85)
            case 1: b.backgroundColor = UIColor(white: 0.10, alpha: 1)
            default: break
            }
        }
    }

    private func renderCurrentRow() {
        let row = guesses.count
        guard row < 6 else { return }
        let chars = Array(current)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<5 {
            tileGlyphs[row][i].string = i < chars.count ? String(chars[i]).uppercased() : ""
            tileGlyphs[row][i].foregroundColor = UIColor(white: 0.95, alpha: 1).cgColor
        }
        CATransaction.commit()
    }

    private func updateHUD() {
        levelLabel.text = "LEVEL \(levelIndex + 1)/\(Self.totalLevels)"
        triesLabel.text = "TRY \(min(guesses.count + (roundOver ? 0 : 1), 6))/6"
    }

    // ── Grid rendering ────────────────────────────────────────────────

    private func buildGridLayers() {
        gridView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        tileLayers = []
        tileGlyphs = []
        for _ in 0..<6 {
            var rowL: [CALayer] = []
            var rowG: [CATextLayer] = []
            for _ in 0..<5 {
                let l = CALayer()
                l.cornerRadius = 7
                l.cornerCurve = .continuous
                l.backgroundColor = tileBg.cgColor
                l.borderWidth = 1
                l.borderColor = UIColor(white: 1, alpha: 0.07).cgColor
                gridView.layer.addSublayer(l)
                let t = CATextLayer()
                t.contentsScale = UIScreen.main.scale
                t.alignmentMode = .center
                t.font = CTFontCreateWithName("Menlo-Bold" as CFString, 0, nil)
                l.addSublayer(t)
                rowL.append(l)
                rowG.append(t)
            }
            tileLayers.append(rowL)
            tileGlyphs.append(rowG)
        }
        layoutGridLayers()
    }

    private func layoutGridLayers() {
        let gap = Self.gap
        gridW.constant = side * 5 + gap * 4
        gridH.constant = side * 6 + gap * 5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for r in 0..<6 {
            for c in 0..<5 {
                let l = tileLayers[r][c]
                l.frame = CGRect(x: CGFloat(c) * (side + gap),
                                 y: CGFloat(r) * (side + gap),
                                 width: side, height: side)
                let g = tileGlyphs[r][c]
                g.fontSize = side * 0.45
                let h = side * 0.6
                g.frame = CGRect(x: 0, y: (side - h) / 2, width: side, height: h)
            }
        }
        CATransaction.commit()
    }

    // ── Level lifecycle / persistence ────────────────────────────────

    private func startLevel(_ idx: Int) {
        levelIndex = max(0, min(idx, Self.totalLevels - 1))
        target = Self.word(for: levelIndex)
        guesses = []
        current = ""
        roundOver = false
        letterStates = [:]
        for (_, b) in keyButtons { b.backgroundColor = UIColor(white: 0.16, alpha: 1) }
        buildGridLayers()
        updateHUD()
    }

    @objc private func restartLevel() {
        startLevel(levelIndex)
        persist()
    }

    @objc private func showLevels() {
        let sel = HGLevelSelectViewController(
            title: "Codle — levels", total: Self.totalLevels,
            done: doneLevels, unlocked: unlocked, accent: accent) { [weak self] idx in
            self?.startLevel(idx)
            self?.persist()
        }
        navigationController?.pushViewController(sel, animated: true)
    }

    private func levelWon() {
        doneLevels.insert(levelIndex)
        unlocked = min(max(unlocked, levelIndex + 1), Self.totalLevels - 1)
        persist(includeRound: false)
        updateHUD()
        if doneLevels.count == Self.totalLevels {
            let c = ConfettiView(frame: view.bounds)
            view.addSubview(c)
            c.burst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { c.removeFromSuperview() }
            let a = UIAlertController(title: "🏆 Vocabulary complete!",
                                      message: "All \(Self.totalLevels) words guessed.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Nice", style: .default))
            present(a, animated: true)
        } else {
            let a = UIAlertController(
                title: "Got it ✓",
                message: "“\(target.uppercased())” in \(guesses.count) — \(doneLevels.count)/\(Self.totalLevels) done.",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Next word", style: .default) { _ in
                self.startLevel(min(self.levelIndex + 1, Self.totalLevels - 1))
                self.persist()
            })
            a.addAction(UIAlertAction(title: "Stay", style: .cancel))
            present(a, animated: true)
        }
    }

    private func persist(includeRound: Bool = true) {
        var o: [String: Any] = ["unlocked": unlocked, "done": Array(doneLevels)]
        if includeRound && !roundOver && !guesses.isEmpty {
            o["cur"] = ["idx": levelIndex, "guesses": guesses] as [String: Any]
        }
        HiddenGameScores.saveBlob("codle", o)
        HiddenGameScores.recordIfHigher("codle.levels", doneLevels.count)
    }

    private func restoreOrStart() {
        let o = HiddenGameScores.loadBlob("codle") ?? [:]
        doneLevels = Set(o["done"] as? [Int] ?? [])
        unlocked = min(max(o["unlocked"] as? Int ?? 0, 0), Self.totalLevels - 1)
        if let cur = o["cur"] as? [String: Any],
           let idx = cur["idx"] as? Int, idx >= 0, idx < Self.totalLevels,
           let saved = cur["guesses"] as? [String], saved.count < 6,
           saved.allSatisfy({ $0.count == 5 }) {
            startLevel(idx)
            for g in saved {
                guesses.append(g)
                applyColors(row: guesses.count - 1, guess: g)
            }
            updateHUD()
            return
        }
        startLevel(min(unlocked, Self.totalLevels - 1))
    }
}

// ════════════════════════════════════════════════════════════════════
// 5. Lights Out — toggle logic, every board provably solvable
// ════════════════════════════════════════════════════════════════════
//
// Press a cell → it and its orthogonal neighbours flip. Turn the whole
// board dark. Boards are generated by pressing random cells on a dark
// board (seeded), so a solution ALWAYS exists — replay those presses.
// 24 levels: 5×5 → 7×7. Tap or arrow-keys+space. Auto-saved.

final class LightsOutViewController: HGKeyboardGame {
    static let totalLevels = 24

    private let bg     = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1)
    private let offC   = UIColor(red: 0.110, green: 0.120, blue: 0.165, alpha: 1)
    private let onC    = UIColor(red: 0.95, green: 0.78, blue: 0.35, alpha: 1)
    private let accent = UIColor(red: 0.95, green: 0.78, blue: 0.35, alpha: 1)

    private var levelIndex = 0
    private var doneLevels: Set<Int> = []
    private var unlocked = 0
    private var bests: [String: Int] = [:]

    private var n = 5
    private var lit: Set<Int> = []
    private var presses = 0

    private let levelLabel = UILabel()
    private let pressLabel = UILabel()
    private let litLabel = UILabel()
    private let boardView = UIView()
    private var boardW: NSLayoutConstraint!
    private var boardH: NSLayoutConstraint!
    private var cellLayers: [CALayer] = []
    private var side: CGFloat = 44
    private static let gap: CGFloat = 4
    private var cursor: Int? = nil
    private let cursorLayer = CALayer()

    static func spec(_ i: Int) -> (n: Int, scrambles: Int) {
        let tier = min(max(i, 0) / 8, 2)
        let n = 5 + tier                           // 5, 6, 7
        let scrambles = 4 + (i % 8) * 2 + tier * 3 // 4…21
        return (n, scrambles)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        title = "Lights Out"
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Reset", style: .plain, target: self, action: #selector(resetLevel)),
            UIBarButtonItem(title: "Levels", style: .plain, target: self, action: #selector(showLevels)),
        ]

        levelLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        levelLabel.textColor = UIColor(white: 0.92, alpha: 1)
        pressLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        pressLabel.textColor = accent
        litLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        litLabel.textColor = UIColor(white: 0.65, alpha: 1)

        let header = UIStackView(arrangedSubviews: [levelLabel, UIView(), litLabel, pressLabel])
        header.axis = .horizontal
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        boardView.translatesAutoresizingMaskIntoConstraints = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(boardTapped(_:)))
        boardView.addGestureRecognizer(tap)

        let hint = UILabel()
        hint.text = "GOAL: turn every light off — a press flips the cell + its neighbours.\n"
            + "Tap, or arrows + space on a keyboard · R = reset"
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = UIColor(white: 0.38, alpha: 1)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(boardView)
        view.addSubview(hint)
        boardW = boardView.widthAnchor.constraint(equalToConstant: 100)
        boardH = boardView.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            boardView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            boardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            boardW, boardH,
            hint.topAnchor.constraint(equalTo: boardView.bottomAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        restoreOrStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persist()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override var keyCommands: [UIKeyCommand]? {
        func cmd(_ input: String, _ sel: Selector, _ title: String) -> UIKeyCommand {
            let c = UIKeyCommand(input: input, modifierFlags: [], action: sel)
            c.discoverabilityTitle = title
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        return [
            cmd(UIKeyCommand.inputUpArrow,    #selector(kbUp),    "Move up"),
            cmd(UIKeyCommand.inputDownArrow,  #selector(kbDown),  "Move down"),
            cmd(UIKeyCommand.inputLeftArrow,  #selector(kbLeft),  "Move left"),
            cmd(UIKeyCommand.inputRightArrow, #selector(kbRight), "Move right"),
            cmd(" ",  #selector(kbPress), "Press cell"),
            cmd("\r", #selector(kbPress), "Press cell"),
            cmd("r",  #selector(resetLevel), "Reset level"),
        ]
    }
    @objc private func kbUp()    { moveCursor(dr: -1, dc: 0) }
    @objc private func kbDown()  { moveCursor(dr: 1,  dc: 0) }
    @objc private func kbLeft()  { moveCursor(dr: 0,  dc: -1) }
    @objc private func kbRight() { moveCursor(dr: 0,  dc: 1) }
    @objc private func kbPress() {
        guard let c = cursor else { return }
        pressCell(c)
    }
    private func moveCursor(dr: Int, dc: Int) {
        let start = cursor ?? (n / 2) * n + n / 2
        let r = max(0, min(n - 1, start / n + dr))
        let c = max(0, min(n - 1, start % n + dc))
        cursor = r * n + c
        positionCursor()
    }
    private func positionCursor() {
        guard let c = cursor, cellLayers.indices.contains(c) else {
            cursorLayer.isHidden = true
            return
        }
        cursorLayer.isHidden = false
        cursorLayer.frame = cellLayers[c].frame.insetBy(dx: -1.5, dy: -1.5)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let availW = view.bounds.width - 40
        let availH = view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom - 170
        let g = Self.gap
        let s = min((availW - CGFloat(n - 1) * g) / CGFloat(n),
                    (availH - CGFloat(n - 1) * g) / CGFloat(n), 56)
        guard s > 12, abs(s - side) > 0.5 || cellLayers.count != n * n else { return }
        side = s
        layoutBoard()
    }

    // ── Model ─────────────────────────────────────────────────────────

    private func neighborsPlus(_ i: Int) -> [Int] {
        var out = [i]
        let r = i / n, c = i % n
        if r > 0     { out.append(i - n) }
        if r < n - 1 { out.append(i + n) }
        if c > 0     { out.append(i - 1) }
        if c < n - 1 { out.append(i + 1) }
        return out
    }

    private func pressCell(_ i: Int) {
        guard i >= 0, i < n * n else { return }
        var changed: [Int] = []
        for t in neighborsPlus(i) {
            if lit.contains(t) { lit.remove(t) } else { lit.insert(t) }
            changed.append(t)
        }
        presses += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        refreshCells(changed)
        updateHUD()
        persist()
        if lit.isEmpty { levelWon() }
    }

    @objc private func boardTapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: boardView)
        let gp = Self.gap
        let c = Int(p.x / (side + gp)), r = Int(p.y / (side + gp))
        guard r >= 0, r < n, c >= 0, c < n, p.x >= 0, p.y >= 0 else { return }
        pressCell(r * n + c)
    }

    // ── Rendering ─────────────────────────────────────────────────────

    private func rebuildBoard() {
        boardView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        cellLayers = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for _ in 0..<(n * n) {
            let l = CALayer()
            l.cornerRadius = 7
            l.cornerCurve = .continuous
            boardView.layer.addSublayer(l)
            cellLayers.append(l)
        }
        cursorLayer.borderColor = UIColor(white: 0.95, alpha: 1).cgColor
        cursorLayer.borderWidth = 2
        cursorLayer.cornerRadius = 8
        cursorLayer.cornerCurve = .continuous
        cursorLayer.isHidden = (cursor == nil)
        boardView.layer.addSublayer(cursorLayer)
        layoutBoard()
        CATransaction.commit()
    }

    private func layoutBoard() {
        guard cellLayers.count == n * n else { return }
        let g = Self.gap
        boardW.constant = CGFloat(n) * side + CGFloat(n - 1) * g
        boardH.constant = CGFloat(n) * side + CGFloat(n - 1) * g
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<(n * n) {
            cellLayers[i].frame = CGRect(x: CGFloat(i % n) * (side + g),
                                         y: CGFloat(i / n) * (side + g),
                                         width: side, height: side)
            applyCell(i)
        }
        positionCursor()
        CATransaction.commit()
    }

    private func applyCell(_ i: Int) {
        let on = lit.contains(i)
        cellLayers[i].backgroundColor = (on ? onC : offC).cgColor
        cellLayers[i].shadowColor = onC.cgColor
        cellLayers[i].shadowOpacity = on ? 0.55 : 0
        cellLayers[i].shadowRadius = 7
        cellLayers[i].shadowOffset = .zero
    }

    private func refreshCells(_ idxs: [Int]) {
        CATransaction.begin()
        CATransaction.setDisableActions(false)   // soft flip animation
        for i in idxs { applyCell(i) }
        CATransaction.commit()
    }

    private func updateHUD() {
        levelLabel.text = "LEVEL \(levelIndex + 1)/\(Self.totalLevels)"
        litLabel.text = "💡 \(lit.count)"
        if let best = bests["\(levelIndex)"] {
            pressLabel.text = "PRESS \(presses) · BEST \(best)"
        } else {
            pressLabel.text = "PRESS \(presses)"
        }
    }

    // ── Lifecycle / persistence ───────────────────────────────────────

    private func startLevel(_ idx: Int) {
        levelIndex = max(0, min(idx, Self.totalLevels - 1))
        let s = Self.spec(levelIndex)
        n = s.n
        lit = []
        presses = 0
        cursor = nil
        // Seeded scramble from the solved (dark) board → always solvable.
        var rng = HGRand(0x11975 &+ UInt64(levelIndex) &* 2_000_003)
        var picked: Set<Int> = []
        while picked.count < s.scrambles { picked.insert(rng.int(n * n)) }
        for p in picked.sorted() {
            for t in neighborsPlus(p) {
                if lit.contains(t) { lit.remove(t) } else { lit.insert(t) }
            }
        }
        if lit.isEmpty { lit.insert(n / 2 * n + n / 2) }   // never start already-solved
        rebuildBoard()
        updateHUD()
        view.setNeedsLayout()
    }

    @objc private func resetLevel() {
        startLevel(levelIndex)
        persist()
    }

    @objc private func showLevels() {
        let sel = HGLevelSelectViewController(
            title: "Lights Out — levels", total: Self.totalLevels,
            done: doneLevels, unlocked: unlocked, accent: accent) { [weak self] idx in
            self?.startLevel(idx)
            self?.persist()
        }
        navigationController?.pushViewController(sel, animated: true)
    }

    private func levelWon() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        doneLevels.insert(levelIndex)
        unlocked = min(max(unlocked, levelIndex + 1), Self.totalLevels - 1)
        let key = "\(levelIndex)"
        if bests[key] == nil || presses < bests[key]! { bests[key] = presses }
        persist(includeBoard: false)
        updateHUD()
        if doneLevels.count == Self.totalLevels {
            let c = ConfettiView(frame: view.bounds)
            view.addSubview(c)
            c.burst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { c.removeFromSuperview() }
            let a = UIAlertController(title: "🏆 All lights out!",
                                      message: "Every board dark. Campaign complete.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Nice", style: .default))
            present(a, animated: true)
        } else {
            let a = UIAlertController(
                title: "Board dark ✓",
                message: "Level \(levelIndex + 1) in \(presses) presses · \(doneLevels.count)/\(Self.totalLevels) done.",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Next level", style: .default) { _ in
                self.startLevel(min(self.levelIndex + 1, Self.totalLevels - 1))
                self.persist()
            })
            a.addAction(UIAlertAction(title: "Stay", style: .cancel))
            present(a, animated: true)
        }
    }

    private func persist(includeBoard: Bool = true) {
        var o: [String: Any] = ["unlocked": unlocked,
                                "done": Array(doneLevels),
                                "bests": bests]
        if includeBoard && !lit.isEmpty {
            o["cur"] = ["idx": levelIndex, "lit": Array(lit), "presses": presses] as [String: Any]
        }
        HiddenGameScores.saveBlob("lights", o)
        HiddenGameScores.recordIfHigher("lights.levels", doneLevels.count)
    }

    private func restoreOrStart() {
        let o = HiddenGameScores.loadBlob("lights") ?? [:]
        doneLevels = Set(o["done"] as? [Int] ?? [])
        unlocked = min(max(o["unlocked"] as? Int ?? 0, 0), Self.totalLevels - 1)
        bests = o["bests"] as? [String: Int] ?? [:]
        if let cur = o["cur"] as? [String: Any],
           let idx = cur["idx"] as? Int, idx >= 0, idx < Self.totalLevels {
            startLevel(idx)
            let count = n * n
            let saved = Set((cur["lit"] as? [Int] ?? []).filter { $0 >= 0 && $0 < count })
            if !saved.isEmpty {
                lit = saved
                presses = cur["presses"] as? Int ?? 0
                rebuildBoard()
                updateHUD()
            }
            return
        }
        startLevel(min(unlocked, Self.totalLevels - 1))
    }
}

// ════════════════════════════════════════════════════════════════════
// 6. Slide 15 — the classic sliding puzzle, always-solvable shuffles
// ════════════════════════════════════════════════════════════════════
//
// Order the tiles 1…N with the gap last. Shuffles are made by walking
// the blank with random legal moves from the solved state (seeded), so
// every board is solvable by construction. 18 levels: 3×3 → 5×5.
// Tap a tile in the blank's row/column to slide the whole run, swipe,
// or use arrow keys. Auto-saved mid-slide.

final class SlidePuzzleViewController: HGKeyboardGame {
    static let totalLevels = 18

    private let bg     = UIColor(red: 0.039, green: 0.039, blue: 0.059, alpha: 1)
    private let tileC  = UIColor(red: 0.165, green: 0.180, blue: 0.247, alpha: 1)
    private let homeC  = UIColor(red: 0.30, green: 0.78, blue: 0.45, alpha: 1)
    private let accent = UIColor(red: 0.95, green: 0.45, blue: 0.55, alpha: 1)

    private var levelIndex = 0
    private var doneLevels: Set<Int> = []
    private var unlocked = 0
    private var bests: [String: Int] = [:]

    private var n = 3
    private var board: [Int] = []      // board[pos] = tile value, 0 = blank
    private var moves = 0

    private let levelLabel = UILabel()
    private let movesLabel = UILabel()
    private let boardView = UIView()
    private var boardW: NSLayoutConstraint!
    private var boardH: NSLayoutConstraint!
    private var tileLayers: [Int: CALayer] = [:]     // tile value → layer
    private var tileGlyphs: [Int: CATextLayer] = [:]
    private var side: CGFloat = 64
    private static let gap: CGFloat = 5

    static func spec(_ i: Int) -> (n: Int, shuffles: Int) {
        let tier = min(max(i, 0) / 6, 2)
        return (3 + tier, 40 + i * 14)     // 3×3…5×5, 40…278 blank-walks
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        title = "Slide 15"
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Reset", style: .plain, target: self, action: #selector(resetLevel)),
            UIBarButtonItem(title: "Levels", style: .plain, target: self, action: #selector(showLevels)),
        ]

        levelLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        levelLabel.textColor = UIColor(white: 0.92, alpha: 1)
        movesLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        movesLabel.textColor = accent
        movesLabel.textAlignment = .right

        let header = UIStackView(arrangedSubviews: [levelLabel, UIView(), movesLabel])
        header.axis = .horizontal
        header.translatesAutoresizingMaskIntoConstraints = false

        boardView.translatesAutoresizingMaskIntoConstraints = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(boardTapped(_:)))
        boardView.addGestureRecognizer(tap)
        for dir: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let g = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            g.direction = dir
            view.addGestureRecognizer(g)
        }

        let hint = UILabel()
        hint.text = "GOAL: order the tiles 1 → \(n * n - 1), gap bottom-right.\n"
            + "Tap a tile in the gap's row/column · swipe · or arrow keys"
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = UIColor(white: 0.38, alpha: 1)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        hintLabel = hint

        view.addSubview(header)
        view.addSubview(boardView)
        view.addSubview(hint)
        boardW = boardView.widthAnchor.constraint(equalToConstant: 100)
        boardH = boardView.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            boardView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            boardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            boardW, boardH,
            hint.topAnchor.constraint(equalTo: boardView.bottomAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        restoreOrStart()
    }

    private weak var hintLabel: UILabel?

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persist()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override var keyCommands: [UIKeyCommand]? {
        func cmd(_ input: String, _ sel: Selector, _ title: String) -> UIKeyCommand {
            let c = UIKeyCommand(input: input, modifierFlags: [], action: sel)
            c.discoverabilityTitle = title
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        return [
            cmd(UIKeyCommand.inputUpArrow,    #selector(kbUp),    "Slide up"),
            cmd(UIKeyCommand.inputDownArrow,  #selector(kbDown),  "Slide down"),
            cmd(UIKeyCommand.inputLeftArrow,  #selector(kbLeft),  "Slide left"),
            cmd(UIKeyCommand.inputRightArrow, #selector(kbRight), "Slide right"),
            cmd("r", #selector(resetLevel), "Reset level"),
        ]
    }
    // Arrow = the direction a tile MOVES (into the gap).
    @objc private func kbUp()    { slide(direction: -n) }
    @objc private func kbDown()  { slide(direction: n) }
    @objc private func kbLeft()  { slide(direction: -1) }
    @objc private func kbRight() { slide(direction: 1) }

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        switch g.direction {
        case .up:    slide(direction: -n)
        case .down:  slide(direction: n)
        case .left:  slide(direction: -1)
        default:     slide(direction: 1)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let availW = view.bounds.width - 40
        let availH = view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom - 170
        let g = Self.gap
        let s = min((availW - CGFloat(n - 1) * g) / CGFloat(n),
                    (availH - CGFloat(n - 1) * g) / CGFloat(n), 88)
        guard s > 18, abs(s - side) > 0.5 || tileLayers.count != n * n - 1 else { return }
        side = s
        layoutTiles()
    }

    // ── Model ─────────────────────────────────────────────────────────

    private var blankPos: Int { board.firstIndex(of: 0) ?? 0 }

    private func validStep(_ from: Int, _ d: Int) -> Int? {
        let t = from + d
        guard t >= 0, t < n * n else { return nil }
        if abs(d) == 1 && (t / n) != (from / n) { return nil }
        return t
    }

    /// Move ONE tile into the gap; `direction` = where the tile travels.
    private func slide(direction d: Int) {
        let b = blankPos
        guard let tilePos = validStep(b, -d) else { return }   // tile sits opposite the travel
        moveTile(at: tilePos, to: b)
        afterMove()
    }

    /// Tap: slide the whole run between the tapped tile and the gap.
    @objc private func boardTapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: boardView)
        let gp = Self.gap
        let c = Int(p.x / (side + gp)), r = Int(p.y / (side + gp))
        guard r >= 0, r < n, c >= 0, c < n, p.x >= 0, p.y >= 0 else { return }
        let pos = r * n + c
        let b = blankPos
        guard pos != b else { return }
        if pos / n == b / n {                       // same row
            let step = pos > b ? 1 : -1
            var gapAt = b
            while gapAt != pos {
                let from = gapAt + step
                moveTile(at: from, to: gapAt)
                gapAt = from
            }
            afterMove()
        } else if pos % n == b % n {                // same column
            let step = pos > b ? n : -n
            var gapAt = b
            while gapAt != pos {
                let from = gapAt + step
                moveTile(at: from, to: gapAt)
                gapAt = from
            }
            afterMove()
        }
    }

    private func moveTile(at from: Int, to: Int) {
        let v = board[from]
        guard v != 0 else { return }
        board[to] = v
        board[from] = 0
        moves += 1
        if let l = tileLayers[v] {
            l.frame = tileFrame(to)                  // implicit slide animation
            l.backgroundColor = (to == v - 1 ? homeC.withAlphaComponent(0.45) : tileC).cgColor
        }
    }

    private func afterMove() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        updateHUD()
        persist()
        if isSolved() { levelWon() }
    }

    private func isSolved() -> Bool {
        for i in 0..<(n * n - 1) where board[i] != i + 1 { return false }
        return true
    }

    // ── Rendering ─────────────────────────────────────────────────────

    private func tileFrame(_ pos: Int) -> CGRect {
        let g = Self.gap
        return CGRect(x: CGFloat(pos % n) * (side + g),
                      y: CGFloat(pos / n) * (side + g),
                      width: side, height: side)
    }

    private func rebuildTiles() {
        boardView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        tileLayers = [:]
        tileGlyphs = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pos in 0..<(n * n) {
            let v = board[pos]
            guard v != 0 else { continue }
            let l = CALayer()
            l.cornerRadius = 9
            l.cornerCurve = .continuous
            l.borderWidth = 1
            l.borderColor = UIColor(white: 1, alpha: 0.08).cgColor
            let t = CATextLayer()
            t.contentsScale = UIScreen.main.scale
            t.alignmentMode = .center
            t.font = CTFontCreateWithName("Menlo-Bold" as CFString, 0, nil)
            t.string = "\(v)"
            t.foregroundColor = UIColor(white: 0.95, alpha: 1).cgColor
            l.addSublayer(t)
            boardView.layer.addSublayer(l)
            tileLayers[v] = l
            tileGlyphs[v] = t
        }
        layoutTiles()
        CATransaction.commit()
    }

    private func layoutTiles() {
        let g = Self.gap
        boardW.constant = CGFloat(n) * side + CGFloat(n - 1) * g
        boardH.constant = CGFloat(n) * side + CGFloat(n - 1) * g
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pos in 0..<(n * n) {
            let v = board[pos]
            guard v != 0, let l = tileLayers[v], let t = tileGlyphs[v] else { continue }
            l.frame = tileFrame(pos)
            l.backgroundColor = (pos == v - 1 ? homeC.withAlphaComponent(0.45) : tileC).cgColor
            t.fontSize = side * 0.4
            let h = side * 0.55
            t.frame = CGRect(x: 0, y: (side - h) / 2, width: side, height: h)
        }
        CATransaction.commit()
    }

    private func updateHUD() {
        levelLabel.text = "LEVEL \(levelIndex + 1)/\(Self.totalLevels) · \(n)×\(n)"
        if let best = bests["\(levelIndex)"] {
            movesLabel.text = "MOVES \(moves) · BEST \(best)"
        } else {
            movesLabel.text = "MOVES \(moves)"
        }
    }

    // ── Lifecycle / persistence ───────────────────────────────────────

    private func startLevel(_ idx: Int) {
        levelIndex = max(0, min(idx, Self.totalLevels - 1))
        let s = Self.spec(levelIndex)
        n = s.n
        board = Array(1..<(n * n)) + [0]
        // Seeded blank-walk from solved → always solvable. Never undo
        // the previous step so the shuffle actually goes somewhere.
        var rng = HGRand(0x517DE &+ UInt64(levelIndex) &* 3_000_017)
        var last = 0
        var blank = n * n - 1
        for _ in 0..<s.shuffles {
            var dirs: [Int] = []
            for d in [-1, 1, -n, n] where d != -last {
                if validStep(blank, d) != nil { dirs.append(d) }
            }
            guard !dirs.isEmpty else { break }
            let d = dirs[rng.int(dirs.count)]
            let from = blank + d
            board[blank] = board[from]
            board[from] = 0
            blank = from
            last = d
        }
        if isSolved() {                              // freak case: reshuffle a corner
            let a = board[0]; board[0] = board[1]; board[1] = a
        }
        moves = 0
        hintLabel?.text = "GOAL: order the tiles 1 → \(n * n - 1), gap bottom-right.\n"
            + "Tap a tile in the gap's row/column · swipe · or arrow keys"
        rebuildTiles()
        updateHUD()
        view.setNeedsLayout()
    }

    @objc private func resetLevel() {
        startLevel(levelIndex)
        persist()
    }

    @objc private func showLevels() {
        let sel = HGLevelSelectViewController(
            title: "Slide 15 — levels", total: Self.totalLevels,
            done: doneLevels, unlocked: unlocked, accent: accent) { [weak self] idx in
            self?.startLevel(idx)
            self?.persist()
        }
        navigationController?.pushViewController(sel, animated: true)
    }

    private func levelWon() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        doneLevels.insert(levelIndex)
        unlocked = min(max(unlocked, levelIndex + 1), Self.totalLevels - 1)
        let key = "\(levelIndex)"
        if bests[key] == nil || moves < bests[key]! { bests[key] = moves }
        persist(includeBoard: false)
        updateHUD()
        if doneLevels.count == Self.totalLevels {
            let c = ConfettiView(frame: view.bounds)
            view.addSubview(c)
            c.burst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { c.removeFromSuperview() }
            let a = UIAlertController(title: "🏆 All boards ordered!",
                                      message: "3×3 through 5×5 — campaign complete.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Nice", style: .default))
            present(a, animated: true)
        } else {
            let a = UIAlertController(
                title: "Solved ✓",
                message: "Level \(levelIndex + 1) in \(moves) moves · \(doneLevels.count)/\(Self.totalLevels) done.",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Next level", style: .default) { _ in
                self.startLevel(min(self.levelIndex + 1, Self.totalLevels - 1))
                self.persist()
            })
            a.addAction(UIAlertAction(title: "Stay", style: .cancel))
            present(a, animated: true)
        }
    }

    private func persist(includeBoard: Bool = true) {
        var o: [String: Any] = ["unlocked": unlocked,
                                "done": Array(doneLevels),
                                "bests": bests]
        if includeBoard && !isSolved() && !board.isEmpty {
            o["cur"] = ["idx": levelIndex, "board": board, "moves": moves] as [String: Any]
        }
        HiddenGameScores.saveBlob("slide", o)
        HiddenGameScores.recordIfHigher("slide.levels", doneLevels.count)
    }

    private func restoreOrStart() {
        let o = HiddenGameScores.loadBlob("slide") ?? [:]
        doneLevels = Set(o["done"] as? [Int] ?? [])
        unlocked = min(max(o["unlocked"] as? Int ?? 0, 0), Self.totalLevels - 1)
        bests = o["bests"] as? [String: Int] ?? [:]
        if let cur = o["cur"] as? [String: Any],
           let idx = cur["idx"] as? Int, idx >= 0, idx < Self.totalLevels,
           let saved = cur["board"] as? [Int] {
            startLevel(idx)
            if saved.count == n * n,
               Set(saved) == Set(0..<(n * n)) {      // valid permutation
                board = saved
                moves = cur["moves"] as? Int ?? 0
                rebuildTiles()
                updateHUD()
            }
            return
        }
        startLevel(min(unlocked, Self.totalLevels - 1))
    }
}
