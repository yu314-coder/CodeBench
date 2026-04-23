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
    private let getStartedButton = UIButton(type: .system)
    private var cardViews: [UIView] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        setupBackground()
        setupScrollView()
        setupPageControl()
        setupGetStartedButton()
        buildPages()
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
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageControl)
        NSLayoutConstraint.activate([
            pageControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageControl.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12)
        ])
    }

    private func setupGetStartedButton() {
        var config = UIButton.Configuration.filled()
        config.title = "Get Started"
        config.baseBackgroundColor = WorkspaceStyle.accent
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 40, bottom: 14, trailing: 40)
        getStartedButton.configuration = config
        getStartedButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        getStartedButton.addTarget(self, action: #selector(getStartedTapped), for: .touchUpInside)
        getStartedButton.translatesAutoresizingMaskIntoConstraints = false
        getStartedButton.alpha = 0
        view.addSubview(getStartedButton)
        NSLayoutConstraint.activate([
            getStartedButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            getStartedButton.topAnchor.constraint(equalTo: pageControl.bottomAnchor, constant: 16)
        ])
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

    @objc private func getStartedTapped() {
        HapticService.shared.success()
        UserDefaults.standard.set(true, forKey: "onboarding.completed")
        dismiss(animated: true)
    }

    private func updateGetStartedVisibility() {
        let isLastPage = pageControl.currentPage == pages.count - 1
        UIView.animate(withDuration: 0.3) {
            self.getStartedButton.alpha = isLastPage ? 1 : 0
        }
    }
}

extension OnboardingViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let page = Int(round(scrollView.contentOffset.x / max(1, scrollView.bounds.width)))
        pageControl.currentPage = max(0, min(page, pages.count - 1))
        updateGetStartedVisibility()
    }
}
