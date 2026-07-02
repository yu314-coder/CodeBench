import UIKit
import UniformTypeIdentifiers

/// "Settings" tab content. Grouped controls for the things users
/// actually adjust: editor + terminal font sizes, Monaco theme,
/// Manim render quality/fps, and a few maintenance buttons (clear
/// caches, reset workspace, view crash log).
///
/// All values persist via `Settings` (UserDefaults wrapper) which
/// posts `Settings.didChange` on mutation. Other VCs observe that
/// notification and refresh themselves — no manual plumbing per
/// control.
final class SettingsViewController: UIViewController {

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    // Same palette as the System tab so the two feel like siblings.
    private let bgColor      = UIColor(red: 0.098, green: 0.102, blue: 0.114, alpha: 1)
    private let surfaceColor = UIColor(red: 0.130, green: 0.137, blue: 0.157, alpha: 1)
    private let textColor    = UIColor(red: 0.820, green: 0.835, blue: 0.870, alpha: 1)
    private let dimColor     = UIColor(red: 0.520, green: 0.540, blue: 0.580, alpha: 1)
    private let accentColor  = UIColor(red: 0.400, green: 0.588, blue: 0.929, alpha: 1)

    // Redesign-only: a deeper "well" behind cards, an elevated card
    // surface, and a per-section accent ramp. These are additive — the
    // original bg/surface/text/dim/accent constants are untouched.
    private let wellColor    = UIColor(red: 0.071, green: 0.075, blue: 0.086, alpha: 1)
    private let cardColor    = UIColor(red: 0.140, green: 0.149, blue: 0.172, alpha: 1)
    private let hairline     = UIColor(white: 1, alpha: 0.07)

    /// Distinct accent per section, used on the card's icon chip + rail.
    private enum Section { case editor, terminal, manim, workspace, models, privacy, about }
    private func accent(_ s: Section) -> UIColor {
        switch s {
        case .editor:    return UIColor(red: 0.40, green: 0.59, blue: 0.93, alpha: 1) // blue
        case .terminal:  return UIColor(red: 0.36, green: 0.78, blue: 0.55, alpha: 1) // green
        case .manim:     return UIColor(red: 0.74, green: 0.52, blue: 0.96, alpha: 1) // violet
        case .workspace: return UIColor(red: 0.96, green: 0.69, blue: 0.36, alpha: 1) // amber
        case .models:    return UIColor(red: 0.40, green: 0.74, blue: 0.93, alpha: 1) // cyan
        case .privacy:   return UIColor(red: 0.93, green: 0.49, blue: 0.55, alpha: 1) // rose
        case .about:     return UIColor(red: 0.55, green: 0.58, blue: 0.64, alpha: 1) // slate
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = wellColor
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Re-build so cached size labels (e.g. "Manim cache: 12 MB")
        // reflect any work since the user last opened the tab.
        rebuild()
    }

    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.indicatorStyle = .white
        // Horizontal-drag controls (steppers/sliders) live inside this
        // vertical scroll view. By default the scroll view delays and
        // can cancel content touches, which steals a control's pan
        // before it registers. Disable both so embedded controls track
        // touches immediately and the scroll view never yanks them away.
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 40, right: 16)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        rebuild()
    }

    fileprivate func rebuild() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        contentStack.addArrangedSubview(makeHeader())

        // ── Editor ─────────────────────────────────────────────
        contentStack.addArrangedSubview(makeCard(.editor, title: "Editor",
                                                 icon: "chevron.left.forwardslash.chevron.right",
                                                 footer: "Theme and font changes apply the next time the editor opens a file.",
                                                 rows: [
            stepperRow(title: "Font size",
                      icon: "textformat.size",
                      value: Float(Settings.editorFontSize),
                      min: 9, max: 22, step: 1, unit: "pt") { v in
                Settings.editorFontSize = Int(v)
            },
            segmentRow(title: "Theme",
                       options: ["Dark", "Light", "Auto"],
                       subtitle: "Auto follows the iOS system appearance.",
                       selected: Settings.editorThemeIndex) { idx in
                Settings.editorThemeIndex = idx
            },
            switchRow(title: "Word wrap",
                      icon: "arrow.turn.down.right",
                      isOn: Settings.editorWordWrap) { on in
                Settings.editorWordWrap = on
            },
            switchRow(title: "Auto-save",
                      icon: "square.and.arrow.down",
                      subtitle: "Save current file every 5 seconds",
                      isOn: Settings.autoSaveEnabled) { on in
                Settings.autoSaveEnabled = on
            },
        ]))

        // ── Terminal ───────────────────────────────────────────
        contentStack.addArrangedSubview(makeCard(.terminal, title: "Terminal",
                                                 icon: "terminal",
                                                 rows: [
            stepperRow(title: "Font size",
                      icon: "textformat.size",
                      value: Float(Settings.terminalFontSize),
                      min: 9, max: 22, step: 1, unit: "pt") { v in
                Settings.terminalFontSize = Int(v)
            },
            switchRow(title: "Visual bell",
                      icon: "bell",
                      subtitle: "Flash on Ctrl+G instead of beep",
                      isOn: Settings.terminalVisualBell) { on in
                Settings.terminalVisualBell = on
            },
            switchRow(title: "Confirm paste",
                      icon: "doc.on.clipboard",
                      subtitle: "Ask before pasting clipboard text into the shell",
                      isOn: Settings.terminalConfirmPaste) { on in
                Settings.terminalConfirmPaste = on
            },
        ]))

        // ── Manim render defaults ──────────────────────────────
        contentStack.addArrangedSubview(makeCard(.manim, title: "Manim render",
                                                 icon: "wand.and.stars",
                                                 footer: "Applies to new renders only — existing videos keep their original settings.",
                                                 rows: [
            segmentRow(title: "Quality",
                       options: ["480p", "720p", "1080p", "1440p", "4K", "8K"],
                       subtitle: "Higher quality renders slower and uses more storage. 4K/8K need lots of free RAM — the renderer checks first and falls back if memory is tight.",
                       selected: Settings.manimQualityIndex) { idx in
                Settings.manimQualityIndex = idx
            },
            stepperRow(title: "FPS",
                      icon: "speedometer",
                      value: Float(Settings.manimFPS),
                      min: 10, max: 60, step: 5, unit: "fps") { v in
                Settings.manimFPS = Int(v)
            },
            switchRow(title: "GPU rendering (Metal)",
                      icon: "cpu",
                      subtitle: "Experimental: render manim on the GPU via CairoMetal. Falls back to CPU automatically if it can't initialize. Applies to the next render.",
                      isOn: Settings.manimGPU) { on in
                Settings.manimGPU = on
            },
        ]))

        // ── Workspace / maintenance ────────────────────────────
        contentStack.addArrangedSubview(makeCard(.workspace, title: "Workspace",
                                                 icon: "folder",
                                                 rows: [
            buttonRow(title: "Switch workspace",
                      subtitle: workspaceSubtitle(),
                      destructive: false) { [weak self] in
                guard let self else { return }
                WorkspaceRegistry.presentPicker(from: self,
                                                anchor: self.contentStack)
            },
            buttonRow(title: "Keyboard shortcuts",
                      subtitle: "Show all ⌘ bindings (also ⌘/)",
                      destructive: false) { [weak self] in
                guard let self else { return }
                let vc = KeyboardShortcutsViewController()
                let nav = UINavigationController(rootViewController: vc)
                nav.modalPresentationStyle = .formSheet
                self.present(nav, animated: true)
            },
            buttonRow(title: "Clear Manim cache",
                      subtitle: cacheSubtitle(.manim),
                      destructive: false) { [weak self] in
                self?.confirmClear(.manim)
            },
            buttonRow(title: "Clear LaTeX scratch",
                      subtitle: cacheSubtitle(.latex),
                      destructive: false) { [weak self] in
                self?.confirmClear(.latex)
            },
            buttonRow(title: "Clear pip cache",
                      subtitle: cacheSubtitle(.pip),
                      destructive: false) { [weak self] in
                self?.confirmClear(.pip)
            },
            buttonRow(title: "Open crash log",
                      subtitle: "Show ~/Documents/log.txt",
                      destructive: false) { [weak self] in
                self?.openCrashLog()
            },
            buttonRow(title: "Reset all settings",
                      subtitle: "Restore editor, terminal, and render defaults",
                      destructive: true) { [weak self] in
                self?.confirmResetSettings()
            },
        ]))

        // ── AI Models — install custom GGUFs ───────────────────
        contentStack.addArrangedSubview(makeCard(.models, title: "AI Models",
                                                 icon: "cpu",
                                                 rows: [
            buttonRow(title: "Upload GGUF model",
                      subtitle: "Pick a .gguf file from Files / iCloud — copies into ~/Documents/Models",
                      destructive: false) { [weak self] in
                self?.pickGGUFFile()
            },
            buttonRow(title: "Open Models folder",
                      subtitle: modelsFolderSubtitle(),
                      destructive: false) { [weak self] in
                self?.openModelsFolder()
            },
            buttonRow(title: "Browse the registry",
                      subtitle: "15 curated models — Qwen, Gemma, Llama, Phi, Mistral…",
                      destructive: false) { [weak self] in
                self?.openModelsTab()
            },
        ]))

        // ── Privacy & Data ─────────────────────────────────────
        contentStack.addArrangedSubview(makeCard(.privacy, title: "Privacy & Data",
                                                 icon: "lock.shield",
                                                 footer: "Browser data stays on this device and is never uploaded.",
                                                 rows: [
            buttonRow(title: "Browser history & cookies",
                      subtitle: "Review or clear data saved by the in-app browser",
                      destructive: false) { [weak self] in
                self?.openBrowserData()
            },
        ]))

        // ── About ──────────────────────────────────────────────
        contentStack.addArrangedSubview(makeCard(.about, title: "About",
                                                 icon: "info.circle",
                                                 rows: [
            kvRow(key: "Version",   value: appVersion()),
            kvRow(key: "Build",     value: appBuild()),
            kvRow(key: "Python",    value: pythonVersionString()),
            kvRow(key: "Workspace", value: workspaceShortPath()),
        ]))

        // ── Footer signature ───────────────────────────────────────
        contentStack.addArrangedSubview(makeFooter())
    }

    // MARK: - Row builders

    /// Tap-only numeric stepper rendered as a "−  value  +" pill.
    ///
    /// Replaces the old in-scroll-view UISlider, whose horizontal pan
    /// fought the vertical scroll view and made it undraggable. Two
    /// buttons step by `step`, clamped to [minV, maxV]; each change
    /// snaps to the step grid, updates the value pill, and fires the
    /// same `onChange` the slider used — so the persisted setter
    /// (e.g. `Settings.editorFontSize = Int(v)`) is untouched.
    private func stepperRow(title: String,
                            icon: String? = nil,
                            value: Float,
                            min minV: Float, max maxV: Float, step: Float,
                            unit: String,
                            onChange: @escaping (Float) -> Void) -> UIView {
        let row = paddedRow()

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = textColor

        // Snap the incoming value onto the step grid and clamp it.
        var current: Float = Swift.min(maxV, Swift.max(minV,
            (value / step).rounded() * step))

        let valueLabel = UILabel()
        valueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        valueLabel.textColor = textColor
        valueLabel.textAlignment = .center
        valueLabel.text = "\(Int(current)) \(unit)"
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        func makeStepButton(_ symbol: String) -> UIButton {
            let b = UIButton(type: .system)
            let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            b.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
            b.tintColor = accentColor
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            return b
        }

        let minus = makeStepButton("minus")
        let plus  = makeStepButton("plus")

        // Capture labels weakly inside the closures; `current` is a local
        // captured by reference (closures share the same var).
        func refreshEnabled() {
            minus.isEnabled = current > minV
            plus.isEnabled  = current < maxV
            minus.alpha = minus.isEnabled ? 1 : 0.35
            plus.alpha  = plus.isEnabled  ? 1 : 0.35
        }
        func apply(_ next: Float) {
            let clamped = Swift.min(maxV, Swift.max(minV, next))
            guard clamped != current else { return }
            current = clamped
            valueLabel.text = "\(Int(current)) \(unit)"
            refreshEnabled()
            onChange(current)
        }
        minus.addAction(UIAction { _ in apply(current - step) }, for: .touchUpInside)
        plus.addAction(UIAction  { _ in apply(current + step) }, for: .touchUpInside)
        refreshEnabled()

        // The pill: [ − | value | + ] on a recessed rounded background.
        let pill = UIStackView(arrangedSubviews: [minus, valueLabel, plus])
        pill.axis = .horizontal
        pill.alignment = .center
        pill.distribution = .fill
        pill.spacing = 0
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = UIColor(white: 1, alpha: 0.05)
        pill.layer.cornerRadius = 9
        pill.layer.borderWidth = 0.5
        pill.layer.borderColor = UIColor(white: 1, alpha: 0.10).cgColor
        pill.isLayoutMarginsRelativeArrangement = true
        pill.layoutMargins = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        // Minimum width so the value never looks cramped at "9 pt".
        valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true

        let titleStack = UIStackView(arrangedSubviews: rowIcon(icon) + [titleLabel])
        titleStack.axis = .horizontal
        titleStack.spacing = 8
        titleStack.alignment = .center

        let stack = UIStackView(arrangedSubviews: [titleStack, UIView(), pill])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        // The empty spacer view expands; title hugs left, pill hugs right.
        titleStack.setContentHuggingPriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        pin(stack, in: row)
        return row
    }

    private func switchRow(title: String,
                           icon: String? = nil,
                           subtitle: String? = nil,
                           isOn: Bool,
                           onChange: @escaping (Bool) -> Void) -> UIView {
        let row = paddedRow()

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = textColor

        let labelStack = UIStackView(arrangedSubviews: [titleLabel])
        labelStack.axis = .vertical
        labelStack.spacing = 2

        if let subtitle = subtitle {
            let sub = UILabel()
            sub.text = subtitle
            sub.font = .systemFont(ofSize: 12)
            sub.textColor = dimColor
            sub.numberOfLines = 0
            labelStack.addArrangedSubview(sub)
        }

        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.onTintColor = accentColor
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.addAction(UIAction { _ in onChange(toggle.isOn) },
                         for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: rowIcon(icon) + [labelStack, toggle])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        pin(stack, in: row)
        return row
    }

    private func segmentRow(title: String,
                            options: [String],
                            subtitle: String? = nil,
                            selected: Int,
                            onChange: @escaping (Int) -> Void) -> UIView {
        let row = paddedRow()

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = textColor

        let segment = UISegmentedControl(items: options)
        segment.selectedSegmentIndex = max(0, min(selected, options.count - 1))
        segment.selectedSegmentTintColor = accentColor.withAlphaComponent(0.4)
        segment.setTitleTextAttributes([.foregroundColor: textColor], for: .normal)
        segment.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        segment.addAction(UIAction { _ in
            onChange(segment.selectedSegmentIndex)
        }, for: .valueChanged)

        let labelStack = UIStackView(arrangedSubviews: [titleLabel])
        labelStack.axis = .vertical
        labelStack.spacing = 2
        if let subtitle = subtitle {
            let sub = UILabel()
            sub.text = subtitle
            sub.font = .systemFont(ofSize: 12)
            sub.textColor = dimColor
            sub.numberOfLines = 0
            labelStack.addArrangedSubview(sub)
        }

        let stack = UIStackView(arrangedSubviews: [labelStack, segment])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        pin(stack, in: row)
        return row
    }

    private func buttonRow(title: String,
                           subtitle: String,
                           destructive: Bool,
                           action: @escaping () -> Void) -> UIView {
        let row = paddedRow()

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = destructive ? UIColor.systemRed : accentColor

        let sub = UILabel()
        sub.text = subtitle
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = dimColor
        sub.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, sub])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        pin(stack, in: row)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleRowTap(_:)))
        row.addGestureRecognizer(tap)
        row.tag = registerAction(action)
        return row
    }

    private func kvRow(key: String, value: String) -> UIView {
        let row = paddedRow()

        let k = UILabel()
        k.text = key
        k.font = .systemFont(ofSize: 13, weight: .medium)
        k.textColor = dimColor

        let v = UILabel()
        v.text = value
        v.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        v.textColor = textColor
        v.textAlignment = .right
        v.numberOfLines = 0
        v.lineBreakMode = .byTruncatingMiddle

        let stack = UIStackView(arrangedSubviews: [k, v])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.distribution = .fill
        k.setContentHuggingPriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        pin(stack, in: row)
        return row
    }

    private func paddedRow() -> UIView {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        return v
    }

    /// Optional 16×16 accent glyph for a row's leading edge. Returns an
    /// empty array when `name` is nil so call sites can splat it into a
    /// stack with `rowIcon(icon) + [...]` and get today's layout back
    /// unchanged. Tinted dim (not full accent) so it stays a quiet
    /// affordance rather than competing with controls.
    private func rowIcon(_ name: String?) -> [UIView] {
        guard let name = name,
              let img = UIImage(systemName: name) else { return [] }
        let iv = UIImageView(image: img)
        iv.tintColor = dimColor
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),
        ])
        return [iv]
    }

    private func pin(_ inner: UIView, in row: UIView) {
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            inner.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            inner.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -12),
        ])
    }

    private func makeCard(_ section: Section,
                          title: String,
                          icon: String,
                          footer: String? = nil,
                          rows: [UIView]) -> UIView {
        let tint = accent(section)

        let card = UIView()
        card.backgroundColor = cardColor
        card.layer.cornerRadius = 18
        card.layer.borderWidth = 0.5
        card.layer.borderColor = hairline.cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.28
        card.layer.shadowRadius = 12
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.translatesAutoresizingMaskIntoConstraints = false

        // Left accent rail — a 3pt tinted bar pinned to the card's left
        // edge, giving each section an at-a-glance identity colour.
        let rail = UIView()
        rail.backgroundColor = tint
        rail.layer.cornerRadius = 1.5
        rail.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rail)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            rail.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            rail.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            rail.widthAnchor.constraint(equalToConstant: 3),
        ])

        // Tinted icon "chip": rounded square, section colour at low alpha,
        // glyph in full section colour. Replaces the bare accent glyph.
        let chip = UIView()
        chip.backgroundColor = tint.withAlphaComponent(0.16)
        chip.layer.cornerRadius = 8
        chip.translatesAutoresizingMaskIntoConstraints = false
        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = tint
        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(iconView)
        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: 30),
            chip.heightAnchor.constraint(equalToConstant: 30),
            iconView.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])

        // Bigger, mixed-case section title (was tiny uppercase kerned).
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = textColor

        let header = UIStackView(arrangedSubviews: [chip, titleLabel])
        header.axis = .horizontal
        header.spacing = 10
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false

        let body = UIStackView(arrangedSubviews: [header] + interleaveDividers(rows))
        body.axis = .vertical
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        body.isLayoutMarginsRelativeArrangement = true
        // Left margin clears the rail; right/top/bottom give breathing room.
        body.layoutMargins = UIEdgeInsets(top: 14, left: 18, bottom: 6, right: 16)
        body.setCustomSpacing(10, after: header)

        if let footer = footer {
            let footerLabel = UILabel()
            footerLabel.text = footer
            footerLabel.font = .systemFont(ofSize: 12)
            footerLabel.textColor = dimColor
            footerLabel.numberOfLines = 0
            let footerDivider = UIView()
            footerDivider.backgroundColor = hairline
            footerDivider.translatesAutoresizingMaskIntoConstraints = false
            footerDivider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
            body.addArrangedSubview(footerDivider)
            body.addArrangedSubview(footerLabel)
            body.setCustomSpacing(10, after: footerDivider)
            body.setCustomSpacing(8, after: body.arrangedSubviews[body.arrangedSubviews.count - 3])
        }

        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: card.topAnchor),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    private func interleaveDividers(_ rows: [UIView]) -> [UIView] {
        var out: [UIView] = []
        for (i, r) in rows.enumerated() {
            out.append(r)
            if i < rows.count - 1 {
                let d = UIView()
                d.backgroundColor = UIColor(white: 1, alpha: 0.05)
                d.translatesAutoresizingMaskIntoConstraints = false
                d.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                out.append(d)
            }
        }
        return out
    }

    private func makeHeader() -> UIView {
        // Full-bleed gradient banner. Uses a CAGradientLayer sized via a
        // self-laying-out container subclass so it tracks bounds without
        // needing viewDidLayoutSubviews plumbing on the VC.
        let banner = GradientView()
        banner.colors = [
            accentColor.withAlphaComponent(0.30),
            UIColor(red: 0.74, green: 0.52, blue: 0.96, alpha: 0.18), // violet
            cardColor.withAlphaComponent(0.0),
        ]
        banner.startPoint = CGPoint(x: 0, y: 0)
        banner.endPoint = CGPoint(x: 1, y: 1)
        banner.layer.cornerRadius = 20
        banner.layer.borderWidth = 0.5
        banner.layer.borderColor = hairline.cgColor
        banner.clipsToBounds = true
        banner.translatesAutoresizingMaskIntoConstraints = false

        // App glyph in a glassy circle.
        let glyphWrap = UIView()
        glyphWrap.backgroundColor = UIColor(white: 1, alpha: 0.10)
        glyphWrap.layer.cornerRadius = 24
        glyphWrap.layer.borderWidth = 0.5
        glyphWrap.layer.borderColor = UIColor(white: 1, alpha: 0.16).cgColor
        glyphWrap.translatesAutoresizingMaskIntoConstraints = false
        let glyph = UIImageView(image: UIImage(systemName: "slider.horizontal.3"))
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyphWrap.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyphWrap.widthAnchor.constraint(equalToConstant: 48),
            glyphWrap.heightAnchor.constraint(equalToConstant: 48),
            glyph.centerXAnchor.constraint(equalTo: glyphWrap.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: glyphWrap.centerYAnchor),
        ])

        // Title — hosts the hidden 5-tap → openBrowserData gesture.
        let title = UILabel()
        title.text = "Settings"
        title.font = .systemFont(ofSize: 30, weight: .bold)
        title.textColor = .white
        title.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(openBrowserData))
        tap.numberOfTapsRequired = 5
        title.addGestureRecognizer(tap)

        let sub = UILabel()
        sub.text = "Tune the editor, terminal, render defaults, and storage."
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = UIColor(white: 1, alpha: 0.62)
        sub.numberOfLines = 0

        let titleText = UIStackView(arrangedSubviews: [title, sub])
        titleText.axis = .vertical
        titleText.spacing = 3

        let topRow = UIStackView(arrangedSubviews: [glyphWrap, titleText])
        topRow.axis = .horizontal
        topRow.spacing = 14
        topRow.alignment = .center

        // Live status chips (read-only): active workspace + model count.
        let chips = UIStackView(arrangedSubviews: [
            statusChip(icon: "folder.fill",
                       text: SessionRestore.lastWorkspace?.lastPathComponent ?? "default"),
            statusChip(icon: "cpu.fill", text: modelCountChipText()),
        ])
        chips.axis = .horizontal
        chips.spacing = 8
        chips.alignment = .center
        chips.distribution = .fillProportionally

        let content = UIStackView(arrangedSubviews: [topRow, chips])
        content.axis = .vertical
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        content.isLayoutMarginsRelativeArrangement = true
        content.layoutMargins = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        banner.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: banner.topAnchor),
            content.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
        ])
        return banner
    }

    /// Small rounded pill: tinted glyph + short label. Read-only — used
    /// in the hero header to surface live workspace/model status without
    /// adding any new persisted state.
    private func statusChip(icon: String, text: String) -> UIView {
        let wrap = UIView()
        wrap.backgroundColor = UIColor(white: 1, alpha: 0.10)
        wrap.layer.cornerRadius = 13
        wrap.layer.borderWidth = 0.5
        wrap.layer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let iv = UIImageView(image: UIImage(systemName: icon))
        iv.tintColor = UIColor(white: 1, alpha: 0.85)
        iv.contentMode = .scaleAspectFit
        iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 13).isActive = true

        let lbl = UILabel()
        lbl.text = text
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = UIColor(white: 1, alpha: 0.85)
        lbl.lineBreakMode = .byTruncatingTail

        let s = UIStackView(arrangedSubviews: [iv, lbl])
        s.axis = .horizontal
        s.spacing = 6
        s.alignment = .center
        s.translatesAutoresizingMaskIntoConstraints = false
        s.isLayoutMarginsRelativeArrangement = true
        s.layoutMargins = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        wrap.addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: wrap.topAnchor),
            s.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            s.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    /// "N models" / "No models" for the hero chip. Reuses the same on-disk
    /// scan the AI Models card already performs — purely informational.
    private func modelCountChipText() -> String {
        let dir = modelsDir()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        let n = urls.filter { $0.pathExtension.lowercased() == "gguf" }.count
        return n == 0 ? "No models" : "\(n) model\(n == 1 ? "" : "s")"
    }

    private func makeFooter() -> UIView {
        let label = UILabel()
        label.text = "CodeBench · v\(appVersion()) (\(appBuild()))"
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = dimColor
        label.textAlignment = .center
        label.numberOfLines = 0

        let wrap = UIStackView(arrangedSubviews: [label])
        wrap.axis = .vertical
        wrap.alignment = .center
        wrap.isLayoutMarginsRelativeArrangement = true
        wrap.layoutMargins = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return wrap
    }

    @objc private func openBrowserData() {
        let vc = BrowserHistoryViewController()
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        nav.navigationBar.barStyle = .black
        nav.navigationBar.isTranslucent = false
        nav.navigationBar.barTintColor = surfaceColor
        nav.navigationBar.titleTextAttributes = [.foregroundColor: textColor]
        present(nav, animated: true)
    }

    // MARK: - Tap dispatch (closure tags)

    private var actions: [Int: () -> Void] = [:]
    private var nextActionTag = 1000

    private func registerAction(_ a: @escaping () -> Void) -> Int {
        let tag = nextActionTag
        nextActionTag += 1
        actions[tag] = a
        return tag
    }

    @objc private func handleRowTap(_ g: UITapGestureRecognizer) {
        guard let row = g.view, let action = actions[row.tag] else { return }
        UIView.animate(withDuration: 0.08, animations: {
            row.alpha = 0.5
        }, completion: { _ in
            UIView.animate(withDuration: 0.18) { row.alpha = 1 }
            action()
        })
    }

    // MARK: - Cache management

    private enum CacheKind { case manim, latex, pip }

    private func cacheSubtitle(_ kind: CacheKind) -> String {
        let bytes = cacheBytes(kind)
        return "Currently using \(humanBytes(bytes))"
    }

    private func cacheBytes(_ kind: CacheKind) -> Int64 {
        let docs = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false).path) ?? "~/Documents"
        let candidates: [String]
        switch kind {
        case .manim:
            candidates = ["\(docs)/manim_output", "\(docs)/.manim_cache",
                          "\(docs)/media", NSTemporaryDirectory() + "manim"]
        case .latex:
            candidates = [NSTemporaryDirectory() + "latex_signals",
                          NSTemporaryDirectory() + "busytex_work",
                          "\(docs)/.latex_scratch"]
        case .pip:
            candidates = ["\(NSHomeDirectory())/Library/Caches/pip",
                          "\(docs)/.pip_cache"]
        }
        var total: Int64 = 0
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            total += folderSize(path)
        }
        return total
    }

    private func folderSize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard let en = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let f as URL in en {
            let rv = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if rv?.isRegularFile == true {
                total += Int64(rv?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private func confirmClear(_ kind: CacheKind) {
        let name: String
        switch kind {
        case .manim: name = "Manim cache"
        case .latex: name = "LaTeX scratch"
        case .pip:   name = "pip cache"
        }
        let bytes = cacheBytes(kind)
        let alert = UIAlertController(
            title: "Clear \(name)?",
            message: "This frees \(humanBytes(bytes)) of disk space. Files cannot be recovered.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            self?.clearCache(kind)
            self?.rebuild()
        })
        present(alert, animated: true)
    }

    private func clearCache(_ kind: CacheKind) {
        let docs = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false).path) ?? "~/Documents"
        let paths: [String]
        switch kind {
        case .manim:
            paths = ["\(docs)/manim_output", "\(docs)/.manim_cache",
                     "\(docs)/media", NSTemporaryDirectory() + "manim"]
        case .latex:
            paths = [NSTemporaryDirectory() + "latex_signals",
                     NSTemporaryDirectory() + "busytex_work",
                     "\(docs)/.latex_scratch"]
        case .pip:
            paths = ["\(NSHomeDirectory())/Library/Caches/pip",
                     "\(docs)/.pip_cache"]
        }
        for p in paths {
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    private func confirmResetSettings() {
        let alert = UIAlertController(
            title: "Reset all settings?",
            message: "Editor, terminal, and Manim render preferences return to their defaults. Your files, models, and caches are not affected.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            Settings.resetToDefaults()
            self?.rebuild()
            self?.showToast("Settings reset to defaults")
        })
        present(alert, animated: true)
    }

    private func openCrashLog() {
        let docs = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false).path) ?? "~/Documents"
        let path = "\(docs)/log.txt"
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            let alert = UIAlertController(title: "No crash log",
                message: "No crashes have been recorded — \(path) doesn't exist yet.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        // Show last ~50KB tail in a scrollable text view.
        let tailBytes = data.suffix(50_000)
        let text = String(data: tailBytes, encoding: .utf8)
            ?? "<\(data.count) bytes — not utf-8>"
        let vc = UIViewController()
        vc.view.backgroundColor = bgColor
        vc.title = "Crash log (last 50 KB)"
        let tv = UITextView()
        tv.text = text
        tv.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.backgroundColor = bgColor
        tv.textColor = textColor
        tv.isEditable = false
        tv.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            tv.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.bottomAnchor),
        ])
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self,
            action: #selector(dismissModal))
        // Scroll to end so the freshest entries are visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let last = NSRange(location: text.count, length: 0)
            tv.scrollRangeToVisible(last)
        }
        present(nav, animated: true)
    }

    @objc private func dismissModal() {
        dismiss(animated: true)
    }

    // MARK: - About info

    private func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func appBuild() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private func pythonVersionString() -> String {
        // Read sys.version via ProcessInfo so we don't have to hop into
        // PythonRuntime — the value is set in Settings on first launch.
        return Settings.cachedPythonVersion
    }

    private func workspaceShortPath() -> String {
        let docs = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false).path) ?? "~/Documents"
        let workspace = AppPaths.workspaceURL.path
        return workspace.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func humanBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    // MARK: - GGUF model upload

    /// Path to ~/Documents/Models, created if missing. The same dir
    /// `offlinai_ai._models_dir()` and `ModelsManagerViewController`
    /// scan, so an uploaded file is picked up by every subsystem
    /// without further plumbing.
    private func modelsDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        let models = docs.appendingPathComponent("Models")
        try? FileManager.default.createDirectory(
            at: models, withIntermediateDirectories: true)
        return models
    }

    private func modelsFolderSubtitle() -> String {
        let dir = modelsDir()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        let ggufs = urls.filter { $0.pathExtension.lowercased() == "gguf" }
        if ggufs.isEmpty {
            return "No models installed yet"
        }
        let totalBytes: Int64 = ggufs.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return "\(ggufs.count) installed · \(humanBytes(totalBytes)) total"
    }

    /// Open UIDocumentPicker scoped to .gguf files. Picked files are
    /// copied (not moved) into ~/Documents/Models so the original
    /// stays in iCloud / external storage. We also accept
    /// public.data as a permissive fallback because Files mis-tags
    /// some sideloaded GGUFs as "data" rather than recognising the
    /// custom UTI.
    private func pickGGUFFile() {
        // Build a content-type list that accepts .gguf extension AND
        // generic data (for the case where Files doesn't recognize
        // the custom type). Filtering happens in
        // documentPicker(_:didPickDocumentsAt:) by extension check.
        let types: [UTType]
        if let ggufType = UTType(filenameExtension: "gguf") {
            types = [ggufType, .data]
        } else {
            types = [.data]
        }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.modalPresentationStyle = .formSheet
        present(picker, animated: true)
    }

    /// Show ~/Documents/Models in a simple modal list. Tapping a
    /// row offers Delete / Use / Cancel via an action sheet. iOS
    /// Files app can also show this folder directly (CodeBench
    /// exposes Documents via UIFileSharingEnabled), but giving an
    /// in-app browser keeps the interaction inside Settings.
    private func openModelsFolder() {
        let dir = modelsDir()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        let ggufs = urls.filter { $0.pathExtension.lowercased() == "gguf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        if ggufs.isEmpty {
            let alert = UIAlertController(
                title: "No models yet",
                message: "Tap “Upload GGUF model” to install a custom .gguf, or use the Models tab to download one from the curated registry.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        let nav = UINavigationController(rootViewController:
            ModelsFolderListController(models: ggufs, parent: self))
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    /// Switch to the Models tab in the editor's sidebar. (The dedicated
    /// model browser exists already at ModelsManagerViewController —
    /// the listener may not be wired in every layout, so we also fall
    /// through to presenting it modally as a guaranteed open path.)
    /// we don't reimplement it here.)
    private func openModelsTab() {
        // Notify GameViewController in case it wants to switch to its
        // embedded models pane.
        NotificationCenter.default.post(
            name: .codeBenchOpenModelsManager, object: nil)
        // And present the browser modally — guaranteed to work even
        // when no listener is wired (e.g. when Settings is the first
        // tab the user touched).
        let manager = ModelsManagerViewController()
        manager.isEmbedded = false
        let nav = UINavigationController(rootViewController: manager)
        nav.modalPresentationStyle = .pageSheet
        nav.navigationBar.tintColor = accentColor
        manager.title = "Models"
        manager.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissModalManager))
        present(nav, animated: true)
    }

    @objc private func dismissModalManager() {
        presentedViewController?.dismiss(animated: true)
    }

    private func workspaceSubtitle() -> String {
        let recents = WorkspaceRegistry.recents()
        let cur = SessionRestore.lastWorkspace
        let curName = cur?.lastPathComponent ?? "(default)"
        if recents.isEmpty {
            return "Active: \(curName) · only one tracked so far"
        }
        return "Active: \(curName) · \(recents.count) recent"
    }

    /// Quick toast for non-blocking feedback.
    private func showToast(_ text: String) {
        let label = UILabel()
        label.text = "  \(text)  "
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = UIColor(white: 0.05, alpha: 0.92)
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        UIView.animate(withDuration: 0.25) { label.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.35,
                           animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }
}


// MARK: - UIDocumentPickerDelegate (GGUF upload)

extension SettingsViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        let modelsDir = self.modelsDir()
        var copied = 0
        var skipped: [String] = []
        var failed: [(String, String)] = []

        for src in urls {
            // Filter by extension since we accepted public.data.
            if src.pathExtension.lowercased() != "gguf" {
                skipped.append("\(src.lastPathComponent) (not .gguf)")
                continue
            }
            // The picker was asked-as-copy, so iOS already copied the
            // file into our app sandbox. We start security-scoped
            // access defensively in case an extension provider gave
            // us a non-copy URL anyway.
            let needsScope = src.startAccessingSecurityScopedResource()
            defer { if needsScope { src.stopAccessingSecurityScopedResource() } }

            let dest = modelsDir.appendingPathComponent(src.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    // Append a uniqueness suffix rather than silently
                    // overwriting — protects against accidental
                    // double-upload of an in-progress download.
                    let unique = SettingsViewController.uniqueDestination(for: dest)
                    try FileManager.default.copyItem(at: src, to: unique)
                } else {
                    try FileManager.default.copyItem(at: src, to: dest)
                }
                copied += 1
            } catch {
                failed.append((src.lastPathComponent,
                               error.localizedDescription))
            }
        }

        // Refresh the AI Models card so the totals reflect the new files.
        rebuild()
        // Notify other parts of the app (ModelsManagerViewController,
        // model picker dropdowns) so they re-scan ~/Documents/Models
        // without waiting for a tab switch.
        NotificationCenter.default.post(
            name: .codeBenchModelsDidChange, object: nil)

        let summary: String
        switch (copied, skipped.count, failed.count) {
        case (let c, 0, 0):
            summary = "Imported \(c) model\(c == 1 ? "" : "s")"
        case (let c, _, 0):
            summary = "Imported \(c); skipped \(skipped.count) non-.gguf"
        case (let c, _, _):
            summary = "Imported \(c); \(failed.count) failed"
        }
        showToast(summary)

        if !failed.isEmpty {
            let lines = failed.map { "\($0.0): \($0.1)" }
                .joined(separator: "\n")
            let alert = UIAlertController(
                title: "Some imports failed",
                message: lines, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // No-op — user changed their mind.
    }

    /// Walk forward through `foo.gguf` → `foo-1.gguf` → `foo-2.gguf`
    /// until we find a name that doesn't exist on disk. Bounded to
    /// 999 attempts so a wedged FS can't loop forever.
    private static func uniqueDestination(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 1...999 {
            let cand = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            if !FileManager.default.fileExists(atPath: cand.path) {
                return cand
            }
        }
        return url
    }
}


// MARK: - Notification names

extension Notification.Name {
    static let codeBenchModelsDidChange =
        Notification.Name("CodeBenchModelsDidChange")
    static let codeBenchOpenModelsManager =
        Notification.Name("CodeBenchOpenModelsManager")
    /// Fired by the preload button (top toolbar in the editor) when
    /// the user taps it. Payload: `["path": String, "slot": Int]`.
    /// Observed by GameViewController, which owns the LlamaRunner.
    static let codeBenchRequestLoadModel =
        Notification.Name("CodeBenchRequestLoadModel")
}


// MARK: - Inline browser for ~/Documents/Models

/// Minimal table view for listing and deleting installed GGUFs.
/// Long-press → delete confirmation. Tap → action sheet (Delete /
/// Show file size). Kept inline rather than reusing
/// ModelsManagerViewController because that one is built around the
/// catalog (download buttons, registry rows) and we just want a list
/// of files-on-disk here.
private final class ModelsFolderListController: UITableViewController {
    private var models: [URL]
    private weak var settingsHost: SettingsViewController?

    init(models: [URL], parent: SettingsViewController) {
        self.models = models
        self.settingsHost = parent
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Installed Models"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self,
            action: #selector(dismissSelf))
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView,
                             numberOfRowsInSection section: Int) -> Int {
        models.count
    }

    override func tableView(_ tableView: UITableView,
                             cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell",
                                                  for: indexPath)
        let url = models[indexPath.row]
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey])
                            .fileSize) ?? 0
        var content = cell.defaultContentConfiguration()
        content.text = url.lastPathComponent
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        content.secondaryText = f.string(fromByteCount: Int64(size))
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView,
                             didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let url = models[indexPath.row]
        let alert = UIAlertController(
            title: url.lastPathComponent, message: nil,
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            try? FileManager.default.removeItem(at: url)
            self.models.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            self.settingsHost?.rebuild()
            NotificationCenter.default.post(
                name: .codeBenchModelsDidChange, object: nil)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = alert.popoverPresentationController,
           let cell = tableView.cellForRow(at: indexPath) {
            pop.sourceView = cell
            pop.sourceRect = cell.bounds
        }
        present(alert, animated: true)
    }
}


/// Module-wide settings store. Single source of truth for every
/// user-tunable; reads/writes UserDefaults and posts a notification
/// after each mutation so observing VCs can refresh.
///
/// Defaults live in code (not Info.plist) so a fresh install starts
/// with sensible values without a one-time-setup ritual. New keys
/// just add a property here and consumers pick them up automatically.
enum Settings {
    static let didChange = Notification.Name("CodeBenchSettingsDidChange")
    private static let d = UserDefaults.standard

    // MARK: Editor
    static var editorFontSize: Int {
        get { d.object(forKey: "settings.editor.fontSize") as? Int ?? 14 }
        set { d.set(newValue, forKey: "settings.editor.fontSize"); post() }
    }
    static var editorThemeIndex: Int {
        get { d.object(forKey: "settings.editor.theme") as? Int ?? 0 }
        set { d.set(newValue, forKey: "settings.editor.theme"); post() }
    }
    static var editorWordWrap: Bool {
        get { d.object(forKey: "settings.editor.wordWrap") as? Bool ?? true }
        set { d.set(newValue, forKey: "settings.editor.wordWrap"); post() }
    }
    static var autoSaveEnabled: Bool {
        get { d.object(forKey: "settings.editor.autoSave") as? Bool ?? true }
        set { d.set(newValue, forKey: "settings.editor.autoSave"); post() }
    }

    // MARK: Terminal
    static var terminalFontSize: Int {
        get { d.object(forKey: "settings.terminal.fontSize") as? Int ?? 13 }
        set { d.set(newValue, forKey: "settings.terminal.fontSize"); post() }
    }
    static var terminalVisualBell: Bool {
        get { d.object(forKey: "settings.terminal.visualBell") as? Bool ?? true }
        set { d.set(newValue, forKey: "settings.terminal.visualBell"); post() }
    }
    static var terminalConfirmPaste: Bool {
        get { d.object(forKey: "settings.terminal.confirmPaste") as? Bool ?? false }
        set { d.set(newValue, forKey: "settings.terminal.confirmPaste"); post() }
    }

    // MARK: Manim
    // Same UserDefaults keys as the legacy popover in
    // CodeEditorViewController and PythonRuntime so both UIs stay in
    // sync — was previously two separate stores, the Settings tab
    // wrote to "settings.manim.*" while the actual render pipeline
    // read "manim_*", so adjusting the Settings tab toggles did
    // nothing at render time.
    static var manimQualityIndex: Int {
        get { d.object(forKey: "manim_quality") as? Int ?? 0 }
        set { d.set(newValue, forKey: "manim_quality"); post() }
    }
    static var manimFPS: Int {
        get { d.object(forKey: "manim_fps") as? Int ?? 15 }
        set { d.set(newValue, forKey: "manim_fps"); post() }
    }
    // Experimental GPU (Metal) manim backend. Off by default; PythonRuntime
    // reads "manim_gpu" and swaps in the CairoMetal shim (with CPU fallback).
    static var manimGPU: Bool {
        get { d.object(forKey: "manim_gpu") as? Bool ?? false }
        set { d.set(newValue, forKey: "manim_gpu"); post() }
    }

    // MARK: About — set once at launch by GameViewController.
    static var cachedPythonVersion: String {
        get { d.string(forKey: "settings.about.pythonVersion") ?? "Loading…" }
        set { d.set(newValue, forKey: "settings.about.pythonVersion") }
    }

    /// Clear the user-tunable keys so the computed getters fall back to
    /// their in-code defaults. Deliberately scoped to settings this tab
    /// owns — does NOT touch `settings.about.pythonVersion` (a launch
    /// cache, not a preference). Posts once so observers refresh.
    static func resetToDefaults() {
        let keys = [
            "settings.editor.fontSize",
            "settings.editor.theme",
            "settings.editor.wordWrap",
            "settings.editor.autoSave",
            "settings.terminal.fontSize",
            "settings.terminal.visualBell",
            "settings.terminal.confirmPaste",
            "manim_quality",
            "manim_fps",
        ]
        for k in keys { d.removeObject(forKey: k) }
        post()
    }

    private static func post() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}


// MARK: - Gradient helper (redesign)

/// A UIView backed by a CAGradientLayer that resizes itself, so callers
/// don't need to override the VC's layout pass. Used by the Settings
/// hero header banner.
private final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }

    var colors: [UIColor] = [] {
        didSet { gradient.colors = colors.map { $0.cgColor } }
    }
    var startPoint: CGPoint = CGPoint(x: 0, y: 0) {
        didSet { gradient.startPoint = startPoint }
    }
    var endPoint: CGPoint = CGPoint(x: 1, y: 1) {
        didSet { gradient.endPoint = endPoint }
    }
}
