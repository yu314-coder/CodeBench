import UIKit

final class ComparisonViewController: UIViewController {

    private let runner: LlamaRunner
    private let modelURLs: [ModelSlot: URL]
    private var selectedSlotA: ModelSlot?
    private var selectedSlotB: ModelSlot?
    private var isRunning = false

    private let promptInput = UITextView()
    private let compareButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let progressLabel = UILabel()

    private let panelA = ComparisonPanel()
    private let panelB = ComparisonPanel()
    private let selectorA = UIButton(type: .system)
    private let selectorB = UIButton(type: .system)

    init(runner: LlamaRunner, modelURLs: [ModelSlot: URL]) {
        self.runner = runner
        self.modelURLs = modelURLs
        // Default to first two available
        let available = ModelSlot.allCases.filter { modelURLs[$0] != nil }
        self.selectedSlotA = available.first
        self.selectedSlotB = available.count > 1 ? available[1] : available.first
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        setupUI()
    }

    private func setupUI() {
        // Background
        let bg = CAGradientLayer()
        bg.frame = view.bounds
        bg.type = .conic
        bg.startPoint = CGPoint(x: 0.5, y: 0.5)
        bg.colors = WorkspaceStyle.gradientColors
        bg.locations = [0, 0.25, 0.5, 0.75, 1.0]
        view.layer.insertSublayer(bg, at: 0)

        // Close button
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = WorkspaceStyle.mutedText
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        // Title
        let titleLabel = UILabel()
        titleLabel.text = "Model Comparison"
        titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = WorkspaceStyle.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        // Prompt input
        promptInput.font = UIFont.systemFont(ofSize: 15)
        promptInput.textColor = WorkspaceStyle.primaryText
        promptInput.backgroundColor = WorkspaceStyle.glassFill
        promptInput.layer.cornerRadius = WorkspaceStyle.radiusMedium
        promptInput.layer.cornerCurve = .continuous
        promptInput.layer.borderWidth = WorkspaceStyle.borderWidth
        promptInput.layer.borderColor = WorkspaceStyle.glassStroke.cgColor
        promptInput.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        promptInput.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(promptInput)

        // Model selectors
        setupModelSelector(selectorA, title: selectedSlotA?.title ?? "Model A", tag: 0)
        setupModelSelector(selectorB, title: selectedSlotB?.title ?? "Model B", tag: 1)

        // Compare button
        var compareConfig = UIButton.Configuration.filled()
        compareConfig.title = "Compare"
        compareConfig.baseBackgroundColor = WorkspaceStyle.accent
        compareConfig.baseForegroundColor = .white
        compareConfig.cornerStyle = .capsule
        compareButton.configuration = compareConfig
        compareButton.addTarget(self, action: #selector(compareTapped), for: .touchUpInside)
        compareButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(compareButton)

        // Cancel button
        var cancelConfig = UIButton.Configuration.tinted()
        cancelConfig.title = "Cancel"
        cancelConfig.baseBackgroundColor = .systemRed
        cancelConfig.baseForegroundColor = .systemRed
        cancelConfig.cornerStyle = .capsule
        cancelButton.configuration = cancelConfig
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.isHidden = true
        view.addSubview(cancelButton)

        // Progress
        progressLabel.font = UIFont.systemFont(ofSize: 14)
        progressLabel.textColor = WorkspaceStyle.mutedText
        progressLabel.textAlignment = .center
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressLabel)

        // Panels
        let panelStack = UIStackView(arrangedSubviews: [panelA, panelB])
        panelStack.axis = .horizontal
        panelStack.spacing = 12
        panelStack.distribution = .fillEqually
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panelStack)

        let selectorStack = UIStackView(arrangedSubviews: [selectorA, selectorB])
        selectorStack.axis = .horizontal
        selectorStack.spacing = 12
        selectorStack.distribution = .fillEqually
        selectorStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(selectorStack)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),

            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            promptInput.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            promptInput.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            promptInput.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            promptInput.heightAnchor.constraint(equalToConstant: 80),

            selectorStack.topAnchor.constraint(equalTo: promptInput.bottomAnchor, constant: 12),
            selectorStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            selectorStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            selectorStack.heightAnchor.constraint(equalToConstant: 36),

            compareButton.topAnchor.constraint(equalTo: selectorStack.bottomAnchor, constant: 12),
            compareButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            cancelButton.topAnchor.constraint(equalTo: selectorStack.bottomAnchor, constant: 12),
            cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            progressLabel.topAnchor.constraint(equalTo: compareButton.bottomAnchor, constant: 8),
            progressLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progressLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            panelStack.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 12),
            panelStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            panelStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            panelStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }

    private func setupModelSelector(_ button: UIButton, title: String, tag: Int) {
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.baseForegroundColor = WorkspaceStyle.accent
        config.cornerStyle = .capsule
        button.configuration = config
        button.tag = tag
        button.showsMenuAsPrimaryAction = true
        button.translatesAutoresizingMaskIntoConstraints = false

        let actions = ModelSlot.allCases.compactMap { slot -> UIAction? in
            guard modelURLs[slot] != nil else { return nil }
            return UIAction(title: slot.title) { [weak self] _ in
                if tag == 0 {
                    self?.selectedSlotA = slot
                    button.configuration?.title = slot.title
                } else {
                    self?.selectedSlotB = slot
                    button.configuration?.title = slot.title
                }
            }
        }
        button.menu = UIMenu(children: actions)
    }

    @objc private func closeTapped() {
        if isRunning { runner.cancelGeneration() }
        dismiss(animated: true)
    }

    @objc private func cancelTapped() {
        runner.cancelGeneration()
        isRunning = false
        compareButton.isHidden = false
        cancelButton.isHidden = true
        progressLabel.text = "Cancelled"
    }

    @objc private func compareTapped() {
        let prompt = promptInput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let slotA = selectedSlotA, let slotB = selectedSlotB else { return }
        guard let urlA = modelURLs[slotA], let urlB = modelURLs[slotB] else { return }

        isRunning = true
        compareButton.isHidden = true
        cancelButton.isHidden = false
        panelA.reset()
        panelB.reset()
        panelA.titleLabel.text = slotA.title
        panelB.titleLabel.text = slotB.title

        let messages = [
            ChatMessage(role: .system, content: "You are a helpful assistant."),
            ChatMessage(role: .user, content: prompt)
        ]

        let config = LlamaRunner.Config()

        // Run model A
        progressLabel.text = "Loading \(slotA.title)..."
        runner.loadModel(at: urlA, config: config) { [weak self] result in
            guard let self, self.isRunning else { return }
            if case .failure(let err) = result {
                self.progressLabel.text = "Error: \(err.localizedDescription)"
                self.resetButtons()
                return
            }

            self.progressLabel.text = "Generating with \(slotA.title)..."
            let startA = Date()
            var tokensA = 0
            self.runner.generate(messages: messages, maxTokens: 2048, onToken: { [weak self] token in
                tokensA += 1
                self?.panelA.appendText(token)
            }, completion: { [weak self] resultA in
                guard let self, self.isRunning else { return }
                let timeA = Date().timeIntervalSince(startA)
                let tpsA = timeA > 0 ? Double(tokensA) / timeA : 0
                self.panelA.setStats(tokens: tokensA, tokPerSec: tpsA, time: timeA)
                self.runner.unload()

                // Run model B
                self.progressLabel.text = "Loading \(slotB.title)..."
                self.runner.loadModel(at: urlB, config: config) { [weak self] result2 in
                    guard let self, self.isRunning else { return }
                    if case .failure(let err) = result2 {
                        self.progressLabel.text = "Error: \(err.localizedDescription)"
                        self.resetButtons()
                        return
                    }

                    self.progressLabel.text = "Generating with \(slotB.title)..."
                    let startB = Date()
                    var tokensB = 0
                    self.runner.generate(messages: messages, maxTokens: 2048, onToken: { [weak self] token in
                        tokensB += 1
                        self?.panelB.appendText(token)
                    }, completion: { [weak self] _ in
                        guard let self else { return }
                        let timeB = Date().timeIntervalSince(startB)
                        let tpsB = timeB > 0 ? Double(tokensB) / timeB : 0
                        self.panelB.setStats(tokens: tokensB, tokPerSec: tpsB, time: timeB)
                        self.runner.unload()

                        self.progressLabel.text = "Comparison complete"
                        self.isRunning = false
                        self.resetButtons()
                    })
                }
            })
        }
    }

    private func resetButtons() {
        compareButton.isHidden = false
        cancelButton.isHidden = true
    }
}

// MARK: - Comparison Panel

final class ComparisonPanel: UIView {
    let titleLabel = UILabel()
    let textView = UITextView()
    let statsLabel = UILabel()
    private var rawText = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        backgroundColor = WorkspaceStyle.glassFill
        layer.cornerRadius = WorkspaceStyle.radiusLarge
        layer.cornerCurve = .continuous
        layer.borderWidth = WorkspaceStyle.borderWidth
        layer.borderColor = WorkspaceStyle.glassStroke.cgColor
        clipsToBounds = true

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: WorkspaceStyle.glassBlurStyle))
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = WorkspaceStyle.accent
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        textView.isEditable = false
        textView.font = UIFont.systemFont(ofSize: 14)
        textView.textColor = WorkspaceStyle.primaryText
        textView.backgroundColor = .clear
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)

        statsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statsLabel.textColor = WorkspaceStyle.mutedText
        statsLabel.textAlignment = .center
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statsLabel)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            textView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textView.bottomAnchor.constraint(equalTo: statsLabel.topAnchor, constant: -8),

            statsLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statsLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            statsLabel.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    func reset() {
        rawText = ""
        textView.text = ""
        statsLabel.text = ""
    }

    func appendText(_ token: String) {
        rawText += token
        textView.text = rawText
    }

    func setStats(tokens: Int, tokPerSec: Double, time: TimeInterval) {
        statsLabel.text = String(format: "%.1f tok/s • %d tokens • %.1fs", tokPerSec, tokens, time)
    }
}
