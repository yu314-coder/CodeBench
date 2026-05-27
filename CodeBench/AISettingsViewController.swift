//
//  AISettingsViewController.swift
//  CodeBench
//
//  Standalone settings sheet for AI provider selection + editor
//  preferences (vim mode toggle, inline-completion on/off). Self-
//  contained — present it from anywhere with
//  `present(AISettingsViewController(), animated: true)`.
//
//  AI settings are persisted via `AIRemoteConfig` (UserDefaults) and
//  `AIKeychain` (Security framework). Editor settings live in
//  UserDefaults under `editor.*` keys.
//

import UIKit

final class AISettingsViewController: UIViewController {

    // MARK: - State

    private var config: AIRemoteConfig = AIRemoteConfig.load()

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let providerSegment = UISegmentedControl(
        items: ["Bundled GGUF", "OpenAI", "Anthropic", "Compat"])
    private let baseURLField = UITextField()
    private let modelField = UITextField()
    private let apiKeyField = UITextField()
    private let temperatureSlider = UISlider()
    private let temperatureValueLabel = UILabel()
    private let maxTokensField = UITextField()
    private let vimToggle = UISwitch()
    private let inlineCompletionToggle = UISwitch()
    private let statusLabel = UILabel()

    /// Hook so the presenter can react to the new vim setting
    /// (without depending on UserDefaults notifications).
    var onVimToggleChanged: ((Bool) -> Void)?
    /// Hook so the presenter can react to the inline-completion setting.
    var onInlineCompletionToggleChanged: ((Bool) -> Void)?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "AI & Editor Settings"
        view.backgroundColor = .systemBackground

        // Close / Done
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(saveTapped))

        setupLayout()
        loadState()
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 20, left: 20, bottom: 30, right: 20)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // ── AI Provider ───────────────────────────────────────────
        contentStack.addArrangedSubview(sectionHeader("AI Provider"))
        contentStack.addArrangedSubview(sectionHelp(
            "Bundled uses the on-device GGUF model (no internet). " +
            "Remote providers stream over HTTPS and let you use any model " +
            "your endpoint supports. API keys are stored in Keychain."))

        providerSegment.addTarget(self, action: #selector(providerChanged), for: .valueChanged)
        contentStack.addArrangedSubview(providerSegment)

        // ── Base URL / Model / API Key ────────────────────────────
        contentStack.addArrangedSubview(spacer(8))
        contentStack.addArrangedSubview(fieldLabel("Base URL"))
        baseURLField.placeholder = "https://api.openai.com/v1"
        baseURLField.autocapitalizationType = .none
        baseURLField.autocorrectionType = .no
        baseURLField.keyboardType = .URL
        styleField(baseURLField)
        contentStack.addArrangedSubview(baseURLField)

        contentStack.addArrangedSubview(spacer(6))
        contentStack.addArrangedSubview(fieldLabel("Model"))
        modelField.placeholder = "gpt-4o-mini / claude-3-5-sonnet-20241022 / llama3.1:8b"
        modelField.autocapitalizationType = .none
        modelField.autocorrectionType = .no
        styleField(modelField)
        contentStack.addArrangedSubview(modelField)

        contentStack.addArrangedSubview(spacer(6))
        contentStack.addArrangedSubview(fieldLabel("API Key (stored in Keychain)"))
        apiKeyField.placeholder = "sk-... or your provider key"
        apiKeyField.autocapitalizationType = .none
        apiKeyField.autocorrectionType = .no
        apiKeyField.isSecureTextEntry = true
        styleField(apiKeyField)
        contentStack.addArrangedSubview(apiKeyField)

        // ── Sampling ──────────────────────────────────────────────
        contentStack.addArrangedSubview(spacer(12))
        contentStack.addArrangedSubview(sectionHeader("Sampling"))

        let tempRow = UIStackView()
        tempRow.axis = .horizontal; tempRow.spacing = 12; tempRow.alignment = .center
        let tempLabel = fieldLabel("Temperature")
        temperatureValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        temperatureValueLabel.textColor = .label
        temperatureValueLabel.text = "0.20"
        temperatureValueLabel.textAlignment = .right
        temperatureValueLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true
        tempRow.addArrangedSubview(tempLabel)
        tempRow.addArrangedSubview(UIView())
        tempRow.addArrangedSubview(temperatureValueLabel)
        contentStack.addArrangedSubview(tempRow)

        temperatureSlider.minimumValue = 0
        temperatureSlider.maximumValue = 2
        temperatureSlider.addTarget(self, action: #selector(temperatureChanged), for: .valueChanged)
        contentStack.addArrangedSubview(temperatureSlider)

        contentStack.addArrangedSubview(spacer(6))
        contentStack.addArrangedSubview(fieldLabel("Max Tokens"))
        maxTokensField.placeholder = "2048"
        maxTokensField.keyboardType = .numberPad
        styleField(maxTokensField)
        contentStack.addArrangedSubview(maxTokensField)

        // ── Editor Preferences ────────────────────────────────────
        contentStack.addArrangedSubview(spacer(20))
        contentStack.addArrangedSubview(sectionHeader("Editor"))

        contentStack.addArrangedSubview(toggleRow(
            title: "Vim Mode (vim-lite)",
            help: "Normal/Insert/Visual modes with hjkl, dd, yy, p, /, :w, gg, G, w/b, x, u. ESC enters Normal.",
            toggle: vimToggle,
            action: #selector(vimToggleChanged)))

        contentStack.addArrangedSubview(toggleRow(
            title: "Inline AI Completion",
            help: "Ghost-text suggestions as you type, debounced 350 ms. Uses the configured AI provider.",
            toggle: inlineCompletionToggle,
            action: #selector(inlineCompletionToggleChanged)))

        // ── Status footer ─────────────────────────────────────────
        contentStack.addArrangedSubview(spacer(20))
        statusLabel.font = .systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        contentStack.addArrangedSubview(statusLabel)
    }

    // MARK: - Section/field helpers

    private func sectionHeader(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 17, weight: .bold)
        l.textColor = .label
        return l
    }
    private func sectionHelp(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12, weight: .regular)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        return l
    }
    private func fieldLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .label
        return l
    }
    private func styleField(_ tf: UITextField) {
        tf.font = .systemFont(ofSize: 15)
        tf.borderStyle = .roundedRect
        tf.backgroundColor = .secondarySystemBackground
        tf.heightAnchor.constraint(equalToConstant: 38).isActive = true
    }
    private func spacer(_ h: CGFloat) -> UIView {
        let v = UIView()
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }
    private func toggleRow(title: String, help: String, toggle: UISwitch, action: Selector) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .label

        toggle.addTarget(self, action: action, for: .valueChanged)

        let topRow = UIStackView(arrangedSubviews: [label, UIView(), toggle])
        topRow.axis = .horizontal; topRow.alignment = .center; topRow.spacing = 12

        let helpLbl = UILabel()
        helpLbl.text = help
        helpLbl.font = .systemFont(ofSize: 12)
        helpLbl.textColor = .secondaryLabel
        helpLbl.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [topRow, helpLbl])
        stack.axis = .vertical; stack.spacing = 4
        return stack
    }

    // MARK: - State load/save

    private func loadState() {
        // Provider segment
        switch config.kind {
        case .bundledGGUF:  providerSegment.selectedSegmentIndex = 0
        case .openAI:       providerSegment.selectedSegmentIndex = 1
        case .anthropic:    providerSegment.selectedSegmentIndex = 2
        case .openAICompat: providerSegment.selectedSegmentIndex = 3
        }
        baseURLField.text = config.baseURL
        modelField.text   = config.modelName
        apiKeyField.text  = AIKeychain.key(for: config.kind) ?? ""
        temperatureSlider.value = Float(config.temperature)
        temperatureValueLabel.text = String(format: "%.2f", config.temperature)
        maxTokensField.text = String(config.maxTokens)

        // Editor preferences
        vimToggle.isOn = UserDefaults.standard.bool(forKey: "editor.vimEnabled")
        // Inline completion defaults to ON; key only set when toggled off.
        let hasInlineKey = UserDefaults.standard.object(forKey: "editor.inlineCompletionEnabled") != nil
        inlineCompletionToggle.isOn = hasInlineKey
            ? UserDefaults.standard.bool(forKey: "editor.inlineCompletionEnabled")
            : true

        refreshProviderFieldsVisibility()
        refreshStatus()
    }

    private func refreshProviderFieldsVisibility() {
        let isBundled = (providerSegment.selectedSegmentIndex == 0)
        baseURLField.isEnabled = !isBundled
        modelField.isEnabled   = !isBundled
        apiKeyField.isEnabled  = !isBundled
        let alpha: CGFloat = isBundled ? 0.4 : 1.0
        baseURLField.alpha = alpha
        modelField.alpha   = alpha
        apiKeyField.alpha  = alpha
    }

    private func refreshStatus() {
        let providerName: String
        switch providerSegment.selectedSegmentIndex {
        case 0: providerName = "On-device GGUF model"
        case 1: providerName = "OpenAI (api.openai.com)"
        case 2: providerName = "Anthropic (api.anthropic.com)"
        case 3: providerName = "OpenAI-compatible endpoint"
        default: providerName = "?"
        }
        statusLabel.text = "Provider: \(providerName)"
    }

    // MARK: - Actions

    @objc private func providerChanged() {
        // Switching provider also refreshes the API-key field with that
        // provider's stored key (each provider has its own slot).
        let kind = currentKindForSegment()
        apiKeyField.text = AIKeychain.key(for: kind) ?? ""
        // Auto-fill the default base URL for known providers if blank.
        if baseURLField.text?.isEmpty ?? true {
            switch kind {
            case .openAI:    baseURLField.text = "https://api.openai.com/v1"
            case .anthropic: baseURLField.text = "https://api.anthropic.com/v1"
            case .openAICompat: baseURLField.text = ""   // user's own endpoint
            case .bundledGGUF:  baseURLField.text = ""
            }
        }
        refreshProviderFieldsVisibility()
        refreshStatus()
    }

    @objc private func temperatureChanged() {
        temperatureValueLabel.text = String(format: "%.2f", temperatureSlider.value)
    }

    @objc private func vimToggleChanged() {
        let on = vimToggle.isOn
        UserDefaults.standard.set(on, forKey: "editor.vimEnabled")
        onVimToggleChanged?(on)
    }

    @objc private func inlineCompletionToggleChanged() {
        let on = inlineCompletionToggle.isOn
        UserDefaults.standard.set(on, forKey: "editor.inlineCompletionEnabled")
        onInlineCompletionToggleChanged?(on)
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        // Persist AI config
        var cfg = config
        cfg.kind = currentKindForSegment()
        cfg.baseURL = baseURLField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        cfg.modelName = modelField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        cfg.temperature = Double(temperatureSlider.value)
        cfg.maxTokens = Int(maxTokensField.text ?? "") ?? 2048
        cfg.save()
        // Persist API key under the active provider slot
        let key = apiKeyField.text ?? ""
        AIKeychain.setKey(key, for: cfg.kind)

        dismiss(animated: true)
    }

    private func currentKindForSegment() -> AIProviderKind {
        switch providerSegment.selectedSegmentIndex {
        case 1: return .openAI
        case 2: return .anthropic
        case 3: return .openAICompat
        default: return .bundledGGUF
        }
    }

    // MARK: - Presentation helper

    /// Convenience: wrap in a UINavigationController and present from
    /// the given view controller. Used by the existing settings panel
    /// and any future "AI" button.
    static func present(from presenter: UIViewController,
                        onVimToggleChanged: ((Bool) -> Void)? = nil,
                        onInlineToggleChanged: ((Bool) -> Void)? = nil) {
        let vc = AISettingsViewController()
        vc.onVimToggleChanged = onVimToggleChanged
        vc.onInlineCompletionToggleChanged = onInlineToggleChanged
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(nav, animated: true)
    }
}
