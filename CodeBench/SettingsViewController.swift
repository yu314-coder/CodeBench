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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor
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
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
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
        contentStack.addArrangedSubview(makeCard(title: "Editor",
                                                 icon: "chevron.left.forwardslash.chevron.right",
                                                 rows: [
            sliderRow(title: "Font size",
                      value: Float(Settings.editorFontSize),
                      min: 9, max: 22, step: 1, unit: "pt") { v in
                Settings.editorFontSize = Int(v)
            },
            segmentRow(title: "Theme",
                       options: ["Dark", "Light", "Auto"],
                       selected: Settings.editorThemeIndex) { idx in
                Settings.editorThemeIndex = idx
            },
            switchRow(title: "Word wrap",
                      isOn: Settings.editorWordWrap) { on in
                Settings.editorWordWrap = on
            },
            switchRow(title: "Auto-save",
                      subtitle: "Save current file every 5 seconds",
                      isOn: Settings.autoSaveEnabled) { on in
                Settings.autoSaveEnabled = on
            },
        ]))

        // ── Terminal ───────────────────────────────────────────
        contentStack.addArrangedSubview(makeCard(title: "Terminal",
                                                 icon: "terminal",
                                                 rows: [
            sliderRow(title: "Font size",
                      value: Float(Settings.terminalFontSize),
                      min: 9, max: 22, step: 1, unit: "pt") { v in
                Settings.terminalFontSize = Int(v)
            },
            switchRow(title: "Visual bell",
                      subtitle: "Flash on Ctrl+G instead of beep",
                      isOn: Settings.terminalVisualBell) { on in
                Settings.terminalVisualBell = on
            },
        ]))

        // ── Manim render defaults ──────────────────────────────
        contentStack.addArrangedSubview(makeCard(title: "Manim render",
                                                 icon: "wand.and.stars",
                                                 rows: [
            segmentRow(title: "Quality",
                       options: ["Low (480p)", "Med (720p)", "High (1080p)"],
                       selected: Settings.manimQualityIndex) { idx in
                Settings.manimQualityIndex = idx
            },
            sliderRow(title: "FPS",
                      value: Float(Settings.manimFPS),
                      min: 10, max: 60, step: 5, unit: "fps") { v in
                Settings.manimFPS = Int(v)
            },
        ]))

        // ── Workspace / maintenance ────────────────────────────
        contentStack.addArrangedSubview(makeCard(title: "Workspace",
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
        ]))

        // ── AI Models — install custom GGUFs ───────────────────
        contentStack.addArrangedSubview(makeCard(title: "AI Models",
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

        // ── About ──────────────────────────────────────────────
        contentStack.addArrangedSubview(makeCard(title: "About",
                                                 icon: "info.circle",
                                                 rows: [
            kvRow(key: "Version",   value: appVersion()),
            kvRow(key: "Build",     value: appBuild()),
            kvRow(key: "Python",    value: pythonVersionString()),
            kvRow(key: "Workspace", value: workspaceShortPath()),
        ]))
    }

    // MARK: - Row builders

    private func sliderRow(title: String,
                           value: Float,
                           min minV: Float, max maxV: Float, step: Float,
                           unit: String,
                           onChange: @escaping (Float) -> Void) -> UIView {
        let row = paddedRow()

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = textColor

        let valueLabel = UILabel()
        valueLabel.text = "\(Int(value)) \(unit)"
        valueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textColor = dimColor
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let topRow = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        topRow.axis = .horizontal
        topRow.spacing = 8

        let slider = UISlider()
        slider.minimumValue = minV
        slider.maximumValue = maxV
        slider.value = value
        slider.tintColor = accentColor
        slider.addAction(UIAction { [weak valueLabel] _ in
            // Snap to nearest step.
            let snapped = (slider.value / step).rounded() * step
            slider.value = snapped
            valueLabel?.text = "\(Int(snapped)) \(unit)"
            onChange(snapped)
        }, for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [topRow, slider])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        pin(stack, in: row)
        return row
    }

    private func switchRow(title: String,
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

        let stack = UIStackView(arrangedSubviews: [labelStack, toggle])
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

        let stack = UIStackView(arrangedSubviews: [titleLabel, segment])
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

    private func pin(_ inner: UIView, in row: UIView) {
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            inner.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            inner.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -12),
        ])
    }

    private func makeCard(title: String, icon: String, rows: [UIView]) -> UIView {
        let card = UIView()
        card.backgroundColor = surfaceColor
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor(white: 1, alpha: 0.06).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 8
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.translatesAutoresizingMaskIntoConstraints = false

        // Header: icon + title.
        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = accentColor
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
        ])

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = dimColor

        let header = UIStackView(arrangedSubviews: [iconView, titleLabel])
        header.axis = .horizontal
        header.spacing = 8
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false

        let body = UIStackView(arrangedSubviews: [header] + interleaveDividers(rows))
        body.axis = .vertical
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        body.isLayoutMarginsRelativeArrangement = true
        body.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 4, right: 14)
        body.setCustomSpacing(8, after: header)

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
        let title = UILabel()
        title.text = "Settings"
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = textColor
        // Hidden gesture: 5 quick taps on the title open the embedded
        // browser data viewer (history + cookies). No menu surface; the
        // user has to know it exists.
        title.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(openBrowserData))
        tap.numberOfTapsRequired = 5
        title.addGestureRecognizer(tap)

        let sub = UILabel()
        sub.text = "Tune the editor, terminal, render defaults, and storage."
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = dimColor
        sub.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, sub])
        stack.axis = .vertical
        stack.spacing = 4
        return stack
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
        let workspace = "\(docs)/Workspace"
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

    // MARK: About — set once at launch by GameViewController.
    static var cachedPythonVersion: String {
        get { d.string(forKey: "settings.about.pythonVersion") ?? "Loading…" }
        set { d.set(newValue, forKey: "settings.about.pythonVersion") }
    }

    private static func post() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
