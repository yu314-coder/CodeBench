import UIKit

final class OnboardingViewController: UIViewController {

    /// Build the onboarding pages. Runs once per VC lifetime so the
    /// device-specific copy ("your iPhone" / "your iPad" / "your Mac")
    /// is captured at launch — changing orientation or switching Stage
    /// Manager doesn't re-render these strings mid-session.
    private static func buildPages() -> [(icon: String, title: String, body: String)] {
        // Pick a device-specific noun. Mac Catalyst / Designed-for-iPad
        // on macOS reports iPad but users perceive it as "Mac"; the
        // rest of the app already handles that path so we stay
        // consistent with "device" for Mac and name the hardware
        // directly on touch devices.
        let device: String
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: device = "iPhone"
        case .pad:   device = "iPad"
        case .mac:   device = "Mac"
        default:     device = "device"
        }

        return [
            ("terminal.fill",
             "CodeBench",
             "A full developer and scientific workstation on your \(device). "
             + "Code, compute, write papers, and chat with local AI — "
             + "everything runs on-device."),
            ("chevron.left.forwardslash.chevron.right",
             "Code in Any Language",
             "Python 3.14 with 30+ native libraries (numpy, scipy, PyTorch, "
             + "manim, sympy, matplotlib, transformers, Pillow, …), plus "
             + "native C, C++, and Fortran interpreters — all with a "
             + "Monaco editor and VS-Code-style IntelliSense."),
            ("function",
             "Scientific Computing + LaTeX",
             "Real pdflatex compiles beamer / TikZ / pgfplots documents "
             + "on-device via busytex. SwiftMath renders live math. "
             + "Jupyter-style scientific workflows without a server."),
            ("wifi.slash",
             "Works Completely Offline",
             "Everything runs locally. No internet. No cloud. No accounts. "
             + "No subscriptions. Your code, data, and conversations "
             + "never leave your \(device)."),
            ("brain",
             "Local AI, Optional",
             "Download a language model once and chat privately — or skip "
             + "it and use CodeBench purely as a coding environment. "
             + "llama.cpp (GGUF) and ExecuTorch runtimes are built in."),
            ("sparkles",
             "Get Started",
             "Tap below to begin.")
        ]
    }

    private lazy var pages: [(icon: String, title: String, body: String)] =
        OnboardingViewController.buildPages()

    private let scrollView = UIScrollView()
    private let pageControl = UIPageControl()
    private let actionButton = UIButton(type: .system)   // morphs Next → Get Started
    private let backButton   = UIButton(type: .system)
    private let skipButton   = UIButton(type: .system)
    private var cardViews: [UIView] = []

    /// Mac Catalyst / iPad keyboards / accessibility need this VC to
    /// be in the responder chain to receive keyCommands. Returning
    /// `true` from canBecomeFirstResponder + a becomeFirstResponder()
    /// call in viewDidAppear gets us there reliably.
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        setupBackground()
        setupScrollView()
        setupPageControl()
        setupNavButtons()
        buildPages()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = scrollView.bounds.width
        for (i, card) in cardViews.enumerated() {
            card.frame = CGRect(x: CGFloat(i) * w + 40, y: 40, width: w - 80, height: scrollView.bounds.height - 80)
        }
        scrollView.contentSize = CGSize(width: w * CGFloat(pages.count), height: scrollView.bounds.height)
    }

    private func setupBackground() {
        let gradient = CAGradientLayer()
        gradient.frame = view.bounds
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.colors = WorkspaceStyle.gradientColors
        gradient.locations = [0, 0.25, 0.5, 0.75, 1.0]
        view.layer.insertSublayer(gradient, at: 0)
    }

    private func setupScrollView() {
        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -120)
        ])
    }

    private func setupPageControl() {
        pageControl.numberOfPages = pages.count
        pageControl.currentPage = 0
        pageControl.currentPageIndicatorTintColor = WorkspaceStyle.accent
        pageControl.pageIndicatorTintColor = WorkspaceStyle.mutedText.withAlphaComponent(0.3)
        // Tapping a dot jumps directly to that page — Mac Catalyst /
        // iPad-with-cursor users expect this; without the target, the
        // dots are decorative-only.
        pageControl.addTarget(self, action: #selector(pageControlChanged),
                              for: .valueChanged)
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageControl)
        NSLayoutConstraint.activate([
            pageControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageControl.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12)
        ])
    }

    /// Three buttons: Skip (top-right, always visible until last page),
    /// Back (bottom-left, hidden on first page), and the morphing
    /// Next/Get-Started action button (bottom-center, always visible).
    /// Designed so cursor users always have a clickable target — the
    /// previous build relied entirely on swipe gestures, which don't
    /// work with a trackpad/mouse on Catalyst.
    private func setupNavButtons() {
        // Action button (Next → Get Started)
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = WorkspaceStyle.accent
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: 40, bottom: 14, trailing: 40)
        actionButton.configuration = config
        actionButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        actionButton.addTarget(self, action: #selector(actionTapped),
                               for: .touchUpInside)
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        // Back button — plain link style
        var backConfig = UIButton.Configuration.plain()
        backConfig.title = "Back"
        backConfig.image = UIImage(systemName: "chevron.left")
        backConfig.imagePadding = 4
        backConfig.imagePlacement = .leading
        backConfig.baseForegroundColor = WorkspaceStyle.secondaryText
        backButton.configuration = backConfig
        backButton.addTarget(self, action: #selector(backTapped),
                             for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        // Skip button — corner placement; dismisses immediately
        var skipConfig = UIButton.Configuration.plain()
        skipConfig.title = "Skip"
        skipConfig.baseForegroundColor = WorkspaceStyle.secondaryText
        skipButton.configuration = skipConfig
        skipButton.addTarget(self, action: #selector(skipTapped),
                             for: .touchUpInside)
        skipButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(actionButton)
        view.addSubview(backButton)
        view.addSubview(skipButton)

        NSLayoutConstraint.activate([
            actionButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            actionButton.topAnchor.constraint(equalTo: pageControl.bottomAnchor, constant: 16),

            backButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            skipButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            skipButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])

        updateNavState()
    }

    private func buildPages() {
        for page in pages {
            let card = makeCard(icon: page.icon, title: page.title, body: page.body)
            scrollView.addSubview(card)
            cardViews.append(card)
        }
    }

    private func makeCard(icon: String, title: String, body: String) -> UIView {
        let card = UIView()
        card.backgroundColor = WorkspaceStyle.glassFill
        card.layer.cornerRadius = WorkspaceStyle.radiusLarge
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = WorkspaceStyle.borderWidth
        card.layer.borderColor = WorkspaceStyle.glassStroke.cgColor
        card.clipsToBounds = true

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: WorkspaceStyle.glassBlurStyle))
        blur.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(blur)

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = WorkspaceStyle.accent
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = WorkspaceStyle.primaryText
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = UILabel()
        bodyLabel.text = body
        bodyLabel.font = UIFont.systemFont(ofSize: 17)
        bodyLabel.textColor = WorkspaceStyle.secondaryText
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(iconView)
        card.addSubview(titleLabel)
        card.addSubview(bodyLabel)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: card.topAnchor),
            blur.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            iconView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 60),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            bodyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            bodyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24)
        ])

        return card
    }

    // MARK: - Navigation

    private func currentPage() -> Int {
        let w = max(1, scrollView.bounds.width)
        return Int(round(scrollView.contentOffset.x / w))
    }

    private func goToPage(_ index: Int, animated: Bool = true) {
        let bounded = max(0, min(index, pages.count - 1))
        let w = scrollView.bounds.width
        scrollView.setContentOffset(
            CGPoint(x: CGFloat(bounded) * w, y: 0), animated: animated)
        pageControl.currentPage = bounded
        updateNavState()
    }

    @objc private func pageControlChanged() {
        // Tapping the dots only fires .valueChanged; sync the scroll view.
        goToPage(pageControl.currentPage)
    }

    @objc private func actionTapped() {
        HapticService.shared.tapLight()
        let page = currentPage()
        if page >= pages.count - 1 {
            finishOnboarding()
        } else {
            goToPage(page + 1)
        }
    }

    @objc private func backTapped() {
        HapticService.shared.tapLight()
        goToPage(currentPage() - 1)
    }

    @objc private func skipTapped() {
        finishOnboarding()
    }

    private func finishOnboarding() {
        HapticService.shared.success()
        UserDefaults.standard.set(true, forKey: "onboarding.completed")
        dismiss(animated: true)
    }

    /// Refresh the action / back / skip button labels based on which
    /// page is current. Called from scrollViewDidScroll, page-tap,
    /// and key-command handlers so it stays in sync no matter how
    /// the page changed.
    private func updateNavState() {
        let page = currentPage()
        let isLast  = page >= pages.count - 1
        let isFirst = page == 0

        actionButton.configuration?.title = isLast ? "Get Started" : "Next"
        actionButton.configuration?.image =
            isLast ? UIImage(systemName: "sparkles")
                   : UIImage(systemName: "chevron.right")
        actionButton.configuration?.imagePlacement = .trailing
        actionButton.configuration?.imagePadding = 6

        UIView.animate(withDuration: 0.18) {
            self.backButton.alpha = isFirst ? 0 : 1
            self.skipButton.alpha = isLast ? 0 : 1
        }
        backButton.isUserInteractionEnabled = !isFirst
        skipButton.isUserInteractionEnabled = !isLast
    }

    // MARK: - Keyboard support (Mac Catalyst, iPad with keyboard)

    /// Arrow keys / Tab / Space / Return / Escape navigate the
    /// onboarding without needing the trackpad. Mac Designed-for-iPad
    /// in particular has no swipe-affordance, so a keyboard path is
    /// the only fast way through the cards.
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputRightArrow,
                         modifierFlags: [],
                         action: #selector(actionTapped)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow,
                         modifierFlags: [],
                         action: #selector(actionTapped)),
            UIKeyCommand(input: "\t", modifierFlags: [],
                         action: #selector(actionTapped)),
            UIKeyCommand(input: " ",  modifierFlags: [],
                         action: #selector(actionTapped)),
            UIKeyCommand(input: "\r", modifierFlags: [],
                         action: #selector(actionTapped)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow,
                         modifierFlags: [],
                         action: #selector(backTapped)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow,
                         modifierFlags: [],
                         action: #selector(backTapped)),
            UIKeyCommand(input: UIKeyCommand.inputEscape,
                         modifierFlags: [],
                         action: #selector(skipTapped)),
        ]
    }
}

extension OnboardingViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let page = currentPage()
        let bounded = max(0, min(page, pages.count - 1))
        if pageControl.currentPage != bounded {
            pageControl.currentPage = bounded
        }
        updateNavState()
    }
}
