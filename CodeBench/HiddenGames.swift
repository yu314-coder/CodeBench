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
// Three full-UI mini-games reachable only via a hidden 3-finger
// swipe-UP gesture on the editor (paired symmetrically with the
// 3-finger swipe-DOWN that cycles secret themes). Each game lives
// in its own UIViewController, fully self-contained.

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
    /// Wipe every hidden-game best + play count. Iterates the standard
    /// domain so we never have to hard-code the per-game key list here.
    static func resetAll() {
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("hg.best.") || k.hasPrefix("hg.plays.") {
            d.removeObject(forKey: k)
        }
    }
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
        heroCard.backgroundColor = UIColor(red: 0.071, green: 0.071, blue: 0.102, alpha: 1.0)
        heroCard.layer.cornerRadius = 18
        heroCard.layer.cornerCurve = .continuous
        heroCard.layer.borderColor = UIColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 0.15).cgColor
        heroCard.layer.borderWidth = 1

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
        heroSub.text = "Quick distractions, all bundled. Tap a card to play."
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
                key: "2048", title: "2048", blurb: "Slide tiles · merge to win",
                glyph: "square.grid.4x3.fill",
                tint: UIColor(red: 0.93, green: 0.76, blue: 0.18, alpha: 1.0),
                glowRGB: (237, 194, 46),
                scoreKey: "g2048.bestTile",
                scoreFormat: { $0 == 0 ? "—" : "best tile \($0)" },
                selector: #selector(open2048)),
            GameSlot(
                key: "Dungeon", title: "Dungeon", blurb: "Tiny roguelike · turn-based",
                glyph: "shield.lefthalf.filled",
                tint: UIColor(red: 0.85, green: 0.42, blue: 0.42, alpha: 1.0),
                glowRGB: (218, 107, 107),
                scoreKey: "dungeon.maxDepth",
                scoreFormat: { $0 == 0 ? "—" : "depth \($0) reached" },
                selector: #selector(openDungeon)),
            GameSlot(
                key: "Invaders", title: "Space Invaders", blurb: "Shoot the aliens · 8×4 wave",
                glyph: "airplane",
                tint: UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1.0),
                glowRGB: (52, 211, 153),
                scoreKey: "invaders.bestScore",
                scoreFormat: { $0 == 0 ? "—" : "best score \($0)" },
                selector: #selector(openInvaders)),
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

        view.addSubview(heroCard)
        view.addSubview(cardsStack)
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

            cardsStack.topAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: 22),
            cardsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cardsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

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
        card.backgroundColor = UIColor(red: 0.071, green: 0.071, blue: 0.102, alpha: 1.0)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.06).cgColor
        card.layer.borderWidth = 1
        card.isUserInteractionEnabled = true

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
            title: "Reset high scores?",
            message: "This clears the best score and play count for all hidden games.",
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

    @objc private func close()        { dismiss(animated: true) }
    @objc private func open2048()     { HiddenGameScores.bumpPlays("g2048.bestTile");   navigationController?.pushViewController(Game2048ViewController(), animated: true) }
    @objc private func openDungeon()  { HiddenGameScores.bumpPlays("dungeon.maxDepth"); navigationController?.pushViewController(DungeonViewController(), animated: true) }
    @objc private func openInvaders() { HiddenGameScores.bumpPlays("invaders.bestScore"); navigationController?.pushViewController(SpaceInvadersViewController(), animated: true) }
}

// ════════════════════════════════════════════════════════════════════
// 1. 2048
// ════════════════════════════════════════════════════════════════════

final class Game2048ViewController: UIViewController {
    private let size = 4
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bg
        title = "2048"
        // Reset · AI (LLM auto-play) · Win (expectimax solver → 16384).
        // Shown right-to-left, so the visible order from the edge is Win, AI, Reset.
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Reset", style: .plain, target: self, action: #selector(reset)),
            UIBarButtonItem(title: "AI",  style: .plain, target: self, action: #selector(toggleAI)),
            UIBarButtonItem(title: "Win", style: .done,  target: self, action: #selector(toggleSolver)),
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
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: grid.leadingAnchor, constant: 2),
            header.trailingAnchor.constraint(equalTo: grid.trailingAnchor, constant: -2),

            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gridWidth,
            grid.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            grid.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
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

        reset()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard grid.bounds.width > 0 else { return }
        let pad = max(7, grid.bounds.width * 0.028)
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
                t.layer.cornerRadius = max(6, cellSize * 0.12)
                t.font = tileFont(for: Int(t.text ?? "") ?? 0)
            }
        }
    }

    /// Font that scales with the cell size and shrinks for longer numbers,
    /// so digits always fit no matter how big/small the board is laid out.
    private func tileFont(for n: Int) -> UIFont {
        let base = cellSide > 0 ? cellSide : 64
        let frac: CGFloat = n < 100 ? 0.46 : (n < 1000 ? 0.36 : 0.28)
        return .systemFont(ofSize: max(14, base * frac), weight: .bold)
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

            if isLost() {
                let wasAuto = autoPlay != .off
                stopAutoPlay()
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
                // A tiny FIXED delay paces exactly one move per frame. Without
                // it, fast moves batch up and CoreAnimation commits them in
                // bursts — which looks like "freeze, then a flurry". 0.02 s ≈
                // 50 moves/s: smooth AND fast.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.stepSolver() }
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
        while nums.count < N { nums.append(0) }
        return (nums, gained)
    }

    /// Apply a move to a board copy → (new board, score gained, did-it-move).
    static func move(_ b: [[Int]], _ m: Move) -> (board: [[Int]], gained: Int, moved: Bool) {
        var nb = b
        var gained = 0
        switch m {
        case .left:
            for r in 0..<N { let s = slide(b[r]); nb[r] = s.line; gained += s.gained }
        case .right:
            for r in 0..<N { let s = slide(b[r].reversed()); nb[r] = Array(s.line.reversed()); gained += s.gained }
        case .up:
            for c in 0..<N {
                let col = (0..<N).map { b[$0][c] }
                let s = slide(col); gained += s.gained
                for r in 0..<N { nb[r][c] = s.line[r] }
            }
        case .down:
            for c in 0..<N {
                let col = (0..<N).map { b[$0][c] }
                let s = slide(col.reversed()); gained += s.gained
                let rev = Array(s.line.reversed())
                for r in 0..<N { nb[r][c] = rev[r] }
            }
        }
        return (nb, gained, nb != b)
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
    static func bestMove(_ vb: [[Int]]) -> Move? {
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
// 2. Dungeon — tiny roguelike
// ════════════════════════════════════════════════════════════════════
//
// 30×16 grid. Player @, walls #, floor ., enemies (g goblin, o orc),
// gold $, stairs >. Turn-based: each player move ticks enemies one
// step toward the player. Bumping into an enemy attacks it; if it
// dies you get gold and a small heal. HP 0 = game over.

final class DungeonViewController: UIViewController {
    private let cols = 30, rows = 16
    private var grid: [[Character]] = []
    private var px = 0, py = 0
    private var hp = 20, maxHp = 20
    private var gold = 0, depth = 1
    private struct Enemy { var x, y, hp: Int; let kind: Character; let dmg: Int }
    private var enemies: [Enemy] = []
    private let mapLabel = UILabel()
    private let statsLabel = UILabel()
    private let logLabel = UILabel()
    private var log: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = "Dungeon"

        mapLabel.font = .monospacedSystemFont(ofSize: 18, weight: .bold)
        mapLabel.numberOfLines = 0
        mapLabel.textColor = UIColor(red: 0.85, green: 0.85, blue: 0.65, alpha: 1)
        mapLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapLabel)

        statsLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        statsLabel.textColor = .white
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsLabel)

        logLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logLabel.numberOfLines = 3
        logLabel.textColor = UIColor(white: 0.75, alpha: 1)
        logLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logLabel)

        let controls = UIStackView()
        controls.axis = .horizontal
        controls.distribution = .equalSpacing
        controls.translatesAutoresizingMaskIntoConstraints = false
        for (title, sel) in [("←", #selector(moveL)), ("↑", #selector(moveU)),
                              ("↓", #selector(moveD)), ("→", #selector(moveR))] {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 32, weight: .bold)
            b.setTitleColor(.white, for: .normal)
            b.backgroundColor = UIColor(white: 0.18, alpha: 1)
            b.layer.cornerRadius = 12
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 64).isActive = true
            b.heightAnchor.constraint(equalToConstant: 64).isActive = true
            b.addTarget(self, action: sel, for: .touchUpInside)
            controls.addArrangedSubview(b)
        }
        view.addSubview(controls)

        for dir: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let g = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:)))
            g.direction = dir
            view.addGestureRecognizer(g)
        }

        NSLayoutConstraint.activate([
            mapLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            mapLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statsLabel.topAnchor.constraint(equalTo: mapLabel.bottomAnchor, constant: 12),
            statsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            logLabel.topAnchor.constraint(equalTo: statsLabel.bottomAnchor, constant: 8),
            logLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            logLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
        ])

        generateLevel()
        render()
    }

    private func generateLevel() {
        grid = Array(repeating: Array(repeating: "#", count: cols), count: rows)
        // Carve 4-6 rooms + connect with corridors.
        var rooms: [(x: Int, y: Int, w: Int, h: Int)] = []
        for _ in 0..<6 {
            let w = Int.random(in: 4...7), h = Int.random(in: 3...5)
            let x = Int.random(in: 1..<(cols - w - 1))
            let y = Int.random(in: 1..<(rows - h - 1))
            rooms.append((x, y, w, h))
            for ry in y..<(y + h) { for rx in x..<(x + w) { grid[ry][rx] = "." } }
        }
        // Corridors connecting room centers in order.
        for i in 1..<rooms.count {
            let a = rooms[i - 1], b = rooms[i]
            let ax = a.x + a.w / 2, ay = a.y + a.h / 2
            let bx = b.x + b.w / 2, by = b.y + b.h / 2
            for x in min(ax, bx)...max(ax, bx) { grid[ay][x] = "." }
            for y in min(ay, by)...max(ay, by) { grid[y][bx] = "." }
        }
        // Place player in first room.
        px = rooms[0].x + 1; py = rooms[0].y + 1
        // Stairs in last room.
        grid[rooms.last!.y + 1][rooms.last!.x + 1] = ">"
        // Sprinkle gold in random rooms.
        for _ in 0..<6 {
            let r = rooms.randomElement()!
            let x = Int.random(in: r.x..<(r.x + r.w))
            let y = Int.random(in: r.y..<(r.y + r.h))
            if grid[y][x] == "." { grid[y][x] = "$" }
        }
        // Potions — restore 8 HP when picked up. Always 1-2 per floor.
        for _ in 0..<Int.random(in: 1...2) {
            let r = rooms.randomElement()!
            let x = Int.random(in: r.x..<(r.x + r.w))
            let y = Int.random(in: r.y..<(r.y + r.h))
            if grid[y][x] == "." { grid[y][x] = "!" }
        }
        // Spawn enemies — count scales with depth. Three tiers:
        //   goblin (g) — common, 3 + depth HP, 1 dmg, 3 gold
        //   orc    (o) — uncommon, 5 + depth·2 HP, 3 dmg, 8 gold
        //   troll  (T) — depth ≥ 3, 8 + depth·3 HP, 5 dmg, 18 gold
        enemies.removeAll()
        for _ in 0..<(3 + depth) {
            let r = rooms[1 + Int.random(in: 0..<(rooms.count - 1))]
            let x = Int.random(in: r.x..<(r.x + r.w))
            let y = Int.random(in: r.y..<(r.y + r.h))
            guard grid[y][x] == "." && !(x == px && y == py) else { continue }
            let roll = Int.random(in: 0..<10)
            if depth >= 3 && roll == 0 {
                enemies.append(Enemy(x: x, y: y, hp: 8 + depth * 3, kind: "T", dmg: 5))
            } else if roll < 4 {
                enemies.append(Enemy(x: x, y: y, hp: 5 + depth * 2, kind: "o", dmg: 3))
            } else {
                enemies.append(Enemy(x: x, y: y, hp: 3 + depth, kind: "g", dmg: 1))
            }
        }
    }

    @objc private func moveL() { tryMove(dx: -1, dy: 0) }
    @objc private func moveR() { tryMove(dx:  1, dy: 0) }
    @objc private func moveU() { tryMove(dx:  0, dy: -1) }
    @objc private func moveD() { tryMove(dx:  0, dy:  1) }
    @objc private func swipe(_ g: UISwipeGestureRecognizer) {
        switch g.direction {
        case .left: moveL(); case .right: moveR()
        case .up: moveU(); case .down: moveD()
        default: break
        }
    }

    private func tryMove(dx: Int, dy: Int) {
        let nx = px + dx, ny = py + dy
        guard nx >= 0, nx < cols, ny >= 0, ny < rows else { return }
        // Enemy in the target cell? Attack.
        if let i = enemies.firstIndex(where: { $0.x == nx && $0.y == ny }) {
            let dmg = Int.random(in: 2...4)
            enemies[i].hp -= dmg
            let name = enemyName(enemies[i].kind)
            addLog("You hit \(name) for \(dmg).")
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if enemies[i].hp <= 0 {
                let reward = goldReward(for: enemies[i].kind)
                addLog("\(name.capitalized) slain! +\(reward) gold")
                gold += reward
                hp = min(maxHp, hp + 1)
                enemies.remove(at: i)
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
            enemyTurn(); render(); return
        }
        let ch = grid[ny][nx]
        if ch == "#" { return }
        if ch == "$" {
            let g = Int.random(in: 5...20)
            gold += g
            addLog("Picked up \(g) gold.")
            grid[ny][nx] = "."
        }
        if ch == "!" {
            let heal = 8
            hp = min(maxHp, hp + heal)
            addLog("Quaffed a potion. +\(heal) HP.")
            grid[ny][nx] = "."
        }
        if ch == ">" {
            depth += 1
            // Bump maxHP slightly with every descent — a tiny meta-
            // progression to reward going deeper instead of grinding
            // the first floor.
            maxHp += 2
            hp = min(maxHp, hp + 2)
            addLog("Descending to depth \(depth)…")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Live-record toast the moment you beat your deepest run.
            if HiddenGameScores.recordIfHigherWasRecord("dungeon.maxDepth", depth) {
                showDungeonToast("NEW RECORD · DEPTH \(depth)")
            }
            generateLevel(); render(); return
        }
        px = nx; py = ny
        enemyTurn()
        render()
    }

    private func enemyTurn() {
        for i in enemies.indices {
            let dx = (px > enemies[i].x) ? 1 : (px < enemies[i].x ? -1 : 0)
            let dy = (py > enemies[i].y) ? 1 : (py < enemies[i].y ? -1 : 0)
            let pri = Bool.random() ? (dx, 0) : (0, dy)
            let attempts = [pri, (dx, 0), (0, dy)]
            for (ax, ay) in attempts {
                let nx = enemies[i].x + ax, ny = enemies[i].y + ay
                if nx == px && ny == py {
                    hp -= enemies[i].dmg
                    addLog("\(enemyName(enemies[i].kind).capitalized) hits you for \(enemies[i].dmg).")
                    break
                }
                if nx >= 0 && nx < cols && ny >= 0 && ny < rows,
                   grid[ny][nx] != "#",
                   !enemies.contains(where: { $0.x == nx && $0.y == ny }) {
                    enemies[i].x = nx; enemies[i].y = ny
                    break
                }
            }
        }
        if hp <= 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            // Persist max depth reached before resetting.
            HiddenGameScores.recordIfHigher("dungeon.maxDepth", depth)
            let a = UIAlertController(title: "You died",
                                      message: "Depth \(depth), \(gold) gold. RIP.",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Start over", style: .default) { _ in
                self.hp = 20; self.maxHp = 20; self.gold = 0; self.depth = 1
                self.log.removeAll()
                self.generateLevel(); self.render()
            })
            present(a, animated: true)
        }
    }

    private func render() {
        var displayGrid = grid
        for e in enemies { displayGrid[e.y][e.x] = e.kind }
        displayGrid[py][px] = "@"

        // Per-character coloring — every tile type gets its own hue
        // so the map reads like a real roguelike instead of beige text.
        let mapFont = UIFont.monospacedSystemFont(ofSize: 18, weight: .bold)
        let mapText = NSMutableAttributedString()
        let charColors: [Character: UIColor] = [
            "#": UIColor(white: 0.30, alpha: 1),                                 // walls
            ".": UIColor(red: 0.55, green: 0.50, blue: 0.42, alpha: 1),          // floor
            "@": UIColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 1),          // player — cyan
            "g": UIColor(red: 0.36, green: 0.85, blue: 0.55, alpha: 1),          // goblin — green
            "o": UIColor(red: 1.00, green: 0.42, blue: 0.40, alpha: 1),          // orc — red
            "T": UIColor(red: 1.00, green: 0.55, blue: 0.20, alpha: 1),          // troll — orange
            "$": UIColor(red: 1.00, green: 0.84, blue: 0.20, alpha: 1),          // gold — amber
            "!": UIColor(red: 0.94, green: 0.40, blue: 0.85, alpha: 1),          // potion — magenta
            ">": UIColor(red: 0.66, green: 0.55, blue: 0.95, alpha: 1),          // stairs — violet
        ]
        for (rowIndex, row) in displayGrid.enumerated() {
            if rowIndex > 0 {
                mapText.append(NSAttributedString(string: "\n", attributes: [.font: mapFont]))
            }
            for ch in row {
                mapText.append(NSAttributedString(
                    string: String(ch),
                    attributes: [
                        .font: mapFont,
                        .foregroundColor: charColors[ch] ?? UIColor(white: 0.6, alpha: 1),
                    ]))
            }
        }
        mapLabel.attributedText = mapText

        // Colored HP bar + gold + depth, rendered as one attributed
        // string so it reads as a single stat row. HP color shifts
        // red → amber → green based on health %.
        let pct = Double(hp) / Double(maxHp)
        let hpColor: UIColor =
            pct < 0.25 ? UIColor(red: 1.0,  green: 0.36, blue: 0.36, alpha: 1) :
            pct < 0.5  ? UIColor(red: 1.0,  green: 0.72, blue: 0.20, alpha: 1) :
                         UIColor(red: 0.36, green: 0.85, blue: 0.55, alpha: 1)
        let bars = max(0, min(10, Int(pct * 10 + 0.5)))
        let hpBar = String(repeating: "█", count: bars)
                  + String(repeating: "·", count: 10 - bars)

        let stats = NSMutableAttributedString()
        let mono = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        stats.append(NSAttributedString(string: "HP ", attributes: [
            .font: mono, .foregroundColor: UIColor(white: 0.65, alpha: 1)]))
        stats.append(NSAttributedString(string: hpBar, attributes: [
            .font: mono, .foregroundColor: hpColor]))
        stats.append(NSAttributedString(string: "  \(hp)/\(maxHp)", attributes: [
            .font: mono, .foregroundColor: hpColor]))
        stats.append(NSAttributedString(string: "    ", attributes: [.font: mono]))
        stats.append(NSAttributedString(string: "⛁ \(gold)", attributes: [
            .font: mono, .foregroundColor: UIColor(red: 1.0, green: 0.84, blue: 0.20, alpha: 1)]))
        stats.append(NSAttributedString(string: "    ", attributes: [.font: mono]))
        stats.append(NSAttributedString(string: "⛓ depth \(depth)", attributes: [
            .font: mono, .foregroundColor: UIColor(red: 0.66, green: 0.55, blue: 0.95, alpha: 1)]))
        statsLabel.attributedText = stats
        logLabel.text = log.suffix(3).joined(separator: "\n")
    }
    private func addLog(_ s: String) {
        log.append(s)
        if log.count > 50 { log.removeFirst(log.count - 50) }
    }

    /// Brief, auto-dismissing banner for milestones (e.g. new depth
    /// record). Self-contained: builds, animates, and removes its own
    /// view — touches no existing subview or constraint.
    private func showDungeonToast(_ text: String) {
        let toast = PaddedLabel()
        toast.text = text
        toast.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        toast.textColor = UIColor(red: 0.66, green: 0.55, blue: 0.95, alpha: 1)
        toast.textAlignment = .center
        toast.backgroundColor = UIColor(red: 0.071, green: 0.071, blue: 0.102, alpha: 0.96)
        toast.layer.cornerRadius = 10
        toast.layer.cornerCurve = .continuous
        toast.layer.borderColor = UIColor(red: 0.66, green: 0.55, blue: 0.95, alpha: 0.45).cgColor
        toast.layer.borderWidth = 1
        toast.clipsToBounds = true
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            toast.heightAnchor.constraint(equalToConstant: 34),
        ])
        UIView.animate(withDuration: 0.25, animations: { toast.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.4, delay: 1.1, options: []) {
                toast.alpha = 0
            } completion: { _ in toast.removeFromSuperview() }
        }
    }

    private func enemyName(_ kind: Character) -> String {
        switch kind {
        case "T": return "troll"
        case "o": return "orc"
        default:  return "goblin"
        }
    }
    private func goldReward(for kind: Character) -> Int {
        switch kind {
        case "T": return 18
        case "o": return 8
        default:  return 3
        }
    }

    // MARK: - Magic Keyboard

    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        // Arrow keys + WASD both move; rogues traditionally use HJKL
        // but iOS users expect arrows + WASD so we wire both.
        let map: [(String, Selector)] = [
            (UIKeyCommand.inputLeftArrow,  #selector(moveL)),
            (UIKeyCommand.inputRightArrow, #selector(moveR)),
            (UIKeyCommand.inputUpArrow,    #selector(moveU)),
            (UIKeyCommand.inputDownArrow,  #selector(moveD)),
            ("a", #selector(moveL)), ("A", #selector(moveL)),
            ("d", #selector(moveR)), ("D", #selector(moveR)),
            ("w", #selector(moveU)), ("W", #selector(moveU)),
            ("s", #selector(moveD)), ("S", #selector(moveD)),
        ]
        return map.map { (input, sel) in
            let c = UIKeyCommand(input: input, modifierFlags: [], action: sel)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
    }
}


// ════════════════════════════════════════════════════════════════════
// 3. Space Invaders
// ════════════════════════════════════════════════════════════════════

final class SpaceInvadersViewController: UIViewController {
    private struct Alien { var x, y: CGFloat; var alive: Bool; let kind: Int }
    /// Short-lived explosion particle. Drawn as a fading dot;
    /// despawns when life ≤ 0.
    private struct Particle { var x, y, vx, vy: CGFloat; var life: CGFloat; let color: UIColor }
    /// Score popup that floats up from the kill point and fades.
    private struct ScorePopup { var x, y: CGFloat; var life: CGFloat; let text: String; let color: UIColor }
    private var aliens: [Alien] = []
    private var particles: [Particle] = []
    private var popups: [ScorePopup] = []
    private var alienDx: CGFloat = 1
    private var alienSpeed: CGFloat = 0.6
    private var alienStepTimer: CGFloat = 0
    private var bullets: [CGPoint] = []        // player bullets
    private var enemyBullets: [CGPoint] = []
    private var player = CGPoint(x: 200, y: 600)
    private let playerSize = CGSize(width: 40, height: 16)
    private var displayLink: CADisplayLink?
    private var score = 0
    private var lives = 3
    private var wave = 1
    private var frameCount = 0
    private var moveLeft = false, moveRight = false
    private let canvas = CALayer()
    private let hitFlash = CALayer()   // red overlay pulsed when hit; sibling of canvas so draw()'s sublayer wipe never clears it
    private let scoreLabel = UILabel()
    private let livesLabel = UILabel()
    private let waveLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = "Space Invaders"

        canvas.frame = .zero
        view.layer.addSublayer(canvas)
        hitFlash.frame = .zero
        hitFlash.backgroundColor = UIColor.systemRed.cgColor
        hitFlash.opacity = 0
        view.layer.addSublayer(hitFlash)   // sits above the game canvas

        scoreLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        scoreLabel.textColor = .systemGreen
        scoreLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scoreLabel)

        livesLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        livesLabel.textColor = .systemRed
        livesLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(livesLabel)

        // Wave counter — centered between SCORE and LIVES.
        waveLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        waveLabel.textColor = UIColor(red: 0.66, green: 0.55, blue: 0.95, alpha: 1) // violet
        waveLabel.translatesAutoresizingMaskIntoConstraints = false
        waveLabel.textAlignment = .center
        view.addSubview(waveLabel)

        NSLayoutConstraint.activate([
            scoreLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            scoreLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            livesLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            livesLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            waveLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            waveLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        // On-screen controls: ◀ ▶ FIRE
        let l = bigButton("◀")
        let r = bigButton("▶")
        let fire = bigButton("●")
        for b in [l, r, fire] { view.addSubview(b) }
        l.addAction(UIAction { [weak self] _ in self?.moveLeft = true },  for: .touchDown)
        l.addAction(UIAction { [weak self] _ in self?.moveLeft = false }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        r.addAction(UIAction { [weak self] _ in self?.moveRight = true },  for: .touchDown)
        r.addAction(UIAction { [weak self] _ in self?.moveRight = false }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        fire.addAction(UIAction { [weak self] _ in self?.fire() }, for: .touchDown)

        l.translatesAutoresizingMaskIntoConstraints = false
        r.translatesAutoresizingMaskIntoConstraints = false
        fire.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            l.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            l.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            r.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            r.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 18),
            fire.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            fire.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        startGame()
    }

    private func bigButton(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 28, weight: .bold)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor(white: 0.18, alpha: 1)
        b.layer.cornerRadius = 36
        b.widthAnchor.constraint(equalToConstant: 72).isActive = true
        b.heightAnchor.constraint(equalToConstant: 72).isActive = true
        return b
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        canvas.frame = view.bounds
        hitFlash.frame = view.bounds
        if aliens.isEmpty { resetWave() }
        player.y = view.bounds.height - 180
    }

    private func startGame() {
        score = 0; lives = 3; wave = 1
        particles.removeAll(); popups.removeAll()
        resetWave()
        let dl = CADisplayLink(target: self, selector: #selector(tick))
        // Cap to 60 fps. The game moves entities a fixed amount PER FRAME
        // (no delta-time), so on a 120 Hz ProMotion display an uncapped
        // display link would fire twice as often and the whole game would
        // run at double speed — unplayably fast. Pinning to 60 fps makes
        // it play at the intended speed on every device.
        if #available(iOS 15.0, *) {
            dl.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        } else {
            dl.preferredFramesPerSecond = 60
        }
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }

    private func resetWave() {
        aliens.removeAll()
        let cols = 8, rows = 4
        let startX: CGFloat = 30, startY: CGFloat = 80
        let dx: CGFloat = 40, dy: CGFloat = 36
        for r in 0..<rows { for c in 0..<cols {
            aliens.append(Alien(x: startX + CGFloat(c) * dx,
                                y: startY + CGFloat(r) * dy,
                                alive: true,
                                kind: r))
        } }
        alienDx = 1
        // Each wave starts a bit faster — keeps later waves tense.
        alienSpeed = min(1.2, 0.6 + 0.08 * CGFloat(wave - 1))
        bullets.removeAll(); enemyBullets.removeAll()
    }

    /// Spawn ~10 colored particles at (x,y) and a score popup.
    private func spawnExplosion(at point: CGPoint, color: UIColor, score: Int) {
        for _ in 0..<10 {
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let speed = CGFloat.random(in: 1.5...3.5)
            particles.append(Particle(
                x: point.x, y: point.y,
                vx: cos(angle) * speed, vy: sin(angle) * speed,
                life: 1.0, color: color))
        }
        popups.append(ScorePopup(
            x: point.x, y: point.y - 8,
            life: 1.0,
            text: "+\(score)",
            color: color))
    }

    @objc private func tick() {
        frameCount += 1
        // Move player
        let speed: CGFloat = 5
        if moveLeft  { player.x = max(20, player.x - speed) }
        if moveRight { player.x = min(view.bounds.width - 20, player.x + speed) }

        // Move alien wave
        alienStepTimer += alienSpeed
        if alienStepTimer >= 8 {
            alienStepTimer = 0
            var hitsEdge = false
            for i in aliens.indices where aliens[i].alive {
                aliens[i].x += alienDx * 6
                if aliens[i].x < 14 || aliens[i].x > view.bounds.width - 14 { hitsEdge = true }
            }
            if hitsEdge {
                alienDx *= -1
                for i in aliens.indices where aliens[i].alive { aliens[i].y += 14 }
                alienSpeed = min(1.6, alienSpeed + 0.05)
            }
            // Random enemy fire from a column's lowest alive alien
            if Bool.random() {
                let alive = aliens.filter { $0.alive }
                if let shooter = alive.randomElement() {
                    enemyBullets.append(CGPoint(x: shooter.x, y: shooter.y + 14))
                }
            }
        }

        // Move bullets
        bullets = bullets.map { CGPoint(x: $0.x, y: $0.y - 9) }.filter { $0.y > 0 }
        enemyBullets = enemyBullets.map { CGPoint(x: $0.x, y: $0.y + 6) }
            .filter { $0.y < view.bounds.height }

        // Player bullet vs aliens
        for bi in (0..<bullets.count).reversed() {
            for ai in aliens.indices where aliens[ai].alive {
                if abs(bullets[bi].x - aliens[ai].x) < 14
                    && abs(bullets[bi].y - aliens[ai].y) < 10 {
                    aliens[ai].alive = false
                    bullets.remove(at: bi)
                    let gain = (3 - aliens[ai].kind) * 10 + 10
                    score += gain
                    let col: UIColor = [.systemPink, .systemYellow, .systemCyan, .systemPurple][aliens[ai].kind % 4]
                    spawnExplosion(
                        at: CGPoint(x: aliens[ai].x, y: aliens[ai].y),
                        color: col, score: gain)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    break
                }
            }
        }

        // Tick particles + popups — fade lifespan + apply velocity.
        for i in particles.indices {
            particles[i].x += particles[i].vx
            particles[i].y += particles[i].vy
            particles[i].vy += 0.08  // light gravity so explosions arc
            particles[i].life -= 0.04
        }
        particles.removeAll { $0.life <= 0 }
        for i in popups.indices {
            popups[i].y -= 0.8
            popups[i].life -= 0.022
        }
        popups.removeAll { $0.life <= 0 }

        // Enemy bullet vs player
        for ebi in (0..<enemyBullets.count).reversed() {
            let b = enemyBullets[ebi]
            if abs(b.x - player.x) < 24 && abs(b.y - player.y) < 12 {
                enemyBullets.remove(at: ebi)
                lives -= 1
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                flashHit()
                if lives <= 0 { gameOver(); return }
            }
        }

        // Aliens reaching bottom = game over
        if aliens.contains(where: { $0.alive && $0.y > player.y - 30 }) {
            gameOver(); return
        }

        // Wave cleared
        if !aliens.contains(where: { $0.alive }) {
            wave += 1
            // Celebratory haptic on clear.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            resetWave()
        }

        draw()
    }

    private func draw() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        canvas.sublayers?.removeAll()

        // Star field — pseudo-random fixed dots at low alpha so the
        // black canvas reads as space instead of pure void.
        var rng = SystemRandomNumberGenerator()
        _ = rng  // keep deterministic look across draws by using a
                 // hashed seed of the frame number instead:
        for i in 0..<60 {
            let s = CAShapeLayer()
            let seed = Double(i)
            let sx = (seed * 197.3).truncatingRemainder(dividingBy: Double(view.bounds.width))
            // Slow parallax drift: nearer (bigger) stars fall faster.
            let fieldH = Double(view.bounds.height - 220)
            let drift = Double(frameCount) * ((seed.truncatingRemainder(dividingBy: 3) == 0) ? 0.35 : 0.18)
            let sy = ((seed * 89.7 + drift).truncatingRemainder(dividingBy: fieldH)) + 30
            let size = (seed.truncatingRemainder(dividingBy: 3) == 0) ? 1.4 : 0.8
            s.path = UIBezierPath(ovalIn: CGRect(x: sx, y: sy, width: size, height: size)).cgPath
            s.fillColor = UIColor.white.withAlphaComponent(0.18).cgColor
            canvas.addSublayer(s)
        }

        // Player — triangle ship + small wing accents + emerald glow.
        let pPath = UIBezierPath()
        let cx = player.x, cy = player.y
        let w = playerSize.width / 2, h = playerSize.height / 2 + 4
        pPath.move(to: CGPoint(x: cx, y: cy - h))               // nose
        pPath.addLine(to: CGPoint(x: cx + w, y: cy + h))         // right wing tip
        pPath.addLine(to: CGPoint(x: cx + w * 0.5, y: cy + h * 0.4))
        pPath.addLine(to: CGPoint(x: cx - w * 0.5, y: cy + h * 0.4))
        pPath.addLine(to: CGPoint(x: cx - w, y: cy + h))         // left wing tip
        pPath.close()
        let p = CAShapeLayer()
        p.path = pPath.cgPath
        p.fillColor = UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1).cgColor
        p.shadowColor = UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1).cgColor
        p.shadowOpacity = 0.6
        p.shadowRadius = 6
        p.shadowOffset = .zero
        canvas.addSublayer(p)

        // Aliens — rounded rect with two "eye" dots so each row reads
        // like a distinct creature, not an interchangeable blob.
        for a in aliens where a.alive {
            let col: UIColor = [.systemPink, .systemYellow, .systemCyan, .systemPurple][a.kind % 4]
            let s = CAShapeLayer()
            s.path = UIBezierPath(roundedRect:
                CGRect(x: a.x - 14, y: a.y - 10, width: 28, height: 20),
                cornerRadius: 6).cgPath
            s.fillColor = col.withAlphaComponent(0.95).cgColor
            s.shadowColor = col.cgColor
            s.shadowOpacity = 0.5
            s.shadowRadius = 3
            s.shadowOffset = .zero
            canvas.addSublayer(s)
            // Eyes.
            for ex: CGFloat in [-4, 4] {
                let e = CAShapeLayer()
                e.path = UIBezierPath(ovalIn:
                    CGRect(x: a.x + ex - 1.5, y: a.y - 2, width: 3, height: 3)).cgPath
                e.fillColor = UIColor.black.withAlphaComponent(0.7).cgColor
                canvas.addSublayer(e)
            }
        }

        // Player bullets — bright white with thin glow.
        for b in bullets {
            let s = CAShapeLayer()
            s.path = UIBezierPath(rect: CGRect(x: b.x - 1, y: b.y - 6, width: 2, height: 12)).cgPath
            s.fillColor = UIColor.white.cgColor
            s.shadowColor = UIColor.white.cgColor
            s.shadowOpacity = 0.85
            s.shadowRadius = 3
            canvas.addSublayer(s)
        }
        // Enemy bullets — red lozenges.
        for b in enemyBullets {
            let s = CAShapeLayer()
            s.path = UIBezierPath(roundedRect:
                CGRect(x: b.x - 1.5, y: b.y - 6, width: 3, height: 12),
                cornerRadius: 1.5).cgPath
            s.fillColor = UIColor.systemRed.cgColor
            s.shadowColor = UIColor.systemRed.cgColor
            s.shadowOpacity = 0.65
            s.shadowRadius = 3
            canvas.addSublayer(s)
        }

        // Explosion particles — fading colored dots.
        for p in particles {
            let s = CAShapeLayer()
            s.path = UIBezierPath(ovalIn:
                CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).cgPath
            s.fillColor = p.color.withAlphaComponent(p.life).cgColor
            s.shadowColor = p.color.cgColor
            s.shadowOpacity = Float(0.6 * p.life)
            s.shadowRadius = 4
            canvas.addSublayer(s)
        }
        // Score popups — floating text drawn via CATextLayer so they
        // composite on the same canvas as the rest of the game.
        for p in popups {
            let t = CATextLayer()
            t.string = p.text
            t.font = UIFont.systemFont(ofSize: 14, weight: .bold).rounded
            t.fontSize = 14
            t.foregroundColor = p.color.withAlphaComponent(p.life).cgColor
            t.alignmentMode = .center
            t.contentsScale = UIScreen.main.scale
            t.frame = CGRect(x: p.x - 24, y: p.y, width: 48, height: 18)
            canvas.addSublayer(t)
        }
        CATransaction.commit()

        scoreLabel.text = "SCORE  \(score)"
        livesLabel.text = "LIVES  \(String(repeating: "❤", count: max(0, lives)))"
        waveLabel.text = "WAVE  \(wave)"
    }

    private func fire() {
        if bullets.count < 3 {
            bullets.append(CGPoint(x: player.x, y: player.y - 10))
        }
    }

    /// Quick red veil when the player is hit. Drives `hitFlash.opacity`
    /// with an explicit CAAnimation so it's immune to the per-frame
    /// sublayer wipe in draw() (hitFlash is a sibling of canvas).
    private func flashHit() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.32
        a.toValue = 0.0
        a.duration = 0.32
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hitFlash.add(a, forKey: "hitFlash")
    }

    private func gameOver() {
        displayLink?.invalidate(); displayLink = nil
        HiddenGameScores.recordIfHigher("invaders.bestScore", score)
        let best = HiddenGameScores.best("invaders.bestScore")
        let a = UIAlertController(title: "Game over",
                                  message: "Score \(score). Best \(best). Replay?",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Replay", style: .default) { _ in
            self.startGame()
        })
        a.addAction(UIAlertAction(title: "Quit", style: .cancel) { _ in
            self.navigationController?.popViewController(animated: true)
        })
        present(a, animated: true)
    }

    // MARK: - Magic Keyboard
    //
    // Continuous arrow-key movement uses pressesBegan / pressesEnded
    // (NOT keyCommands — those only fire on the down-stroke and never
    // re-fire while the key is held, which would feel laggy for a
    // shooter). Space = fire is a one-shot, so it can ride along on
    // pressesBegan too.

    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            guard let code = p.key?.keyCode else { continue }
            switch code {
            case .keyboardLeftArrow:  moveLeft  = true;  handled = true
            case .keyboardRightArrow: moveRight = true;  handled = true
            case .keyboardSpacebar, .keyboardReturnOrEnter:
                fire(); handled = true
            default: break
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            guard let code = p.key?.keyCode else { continue }
            switch code {
            case .keyboardLeftArrow:  moveLeft  = false; handled = true
            case .keyboardRightArrow: moveRight = false; handled = true
            default: break
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Drop the movement flags if iOS yanks the press (e.g. user
        // pulls focus away). Otherwise the ship would keep gliding.
        moveLeft = false; moveRight = false
        super.pressesCancelled(presses, with: event)
    }

    deinit { displayLink?.invalidate() }
}
