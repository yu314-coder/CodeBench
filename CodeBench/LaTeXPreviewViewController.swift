import UIKit

/// Interactive LaTeX preview — type a LaTeX expression and see it rendered
/// in real-time using SwiftMath (native CoreText, no WebView).
final class LaTeXPreviewViewController: UIViewController {

    private let bgColor = UIColor(red: 30/255, green: 30/255, blue: 46/255, alpha: 1)
    private let surfaceColor = UIColor(red: 49/255, green: 50/255, blue: 68/255, alpha: 1)
    private let textColor = UIColor(red: 205/255, green: 214/255, blue: 244/255, alpha: 1)
    private let accentColor = UIColor(red: 137/255, green: 180/255, blue: 250/255, alpha: 1)

    private let inputField = UITextField()
    private let mathLabel = MTMathUILabel()
    private let previewContainer = UIView()
    private let statusLabel = UILabel()

    // Preset expressions
    private let presets: [(String, String)] = [
        ("Quadratic", "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}"),
        ("Einstein", "E = mc^2"),
        ("Pythagorean", "a^2 + b^2 = c^2"),
        ("Integral", "\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}"),
        ("Euler", "e^{i\\pi} + 1 = 0"),
        ("Sum", "\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}"),
        ("Matrix", "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"),
        ("Limit", "\\lim_{x \\to 0} \\frac{\\sin x}{x} = 1"),
        ("Derivative", "\\frac{d}{dx} e^x = e^x"),
        ("Binomial", "\\binom{n}{k} = \\frac{n!}{k!(n-k)!}"),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor
        setupUI()
        // Load first preset
        renderLaTeX(presets[0].1)
        inputField.text = presets[0].1
    }

    private func setupUI() {
        // Title
        let titleLabel = UILabel()
        titleLabel.text = "LaTeX Preview"
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = textColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = UILabel()
        subtitleLabel.text = "SwiftMath native renderer"
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = UIColor(red: 147/255, green: 153/255, blue: 178/255, alpha: 1)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Input field
        inputField.placeholder = "Type LaTeX here..."
        inputField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        inputField.textColor = textColor
        inputField.backgroundColor = surfaceColor
        inputField.borderStyle = .none
        inputField.layer.cornerRadius = 8
        inputField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        inputField.leftViewMode = .always
        inputField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        inputField.rightViewMode = .always
        inputField.autocorrectionType = .no
        inputField.autocapitalizationType = .none
        inputField.spellCheckingType = .no
        inputField.keyboardAppearance = .dark
        inputField.returnKeyType = .done
        inputField.addTarget(self, action: #selector(inputChanged), for: .editingChanged)
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false

        // Preview container
        previewContainer.backgroundColor = .black
        previewContainer.layer.cornerRadius = 12
        previewContainer.clipsToBounds = true
        previewContainer.translatesAutoresizingMaskIntoConstraints = false

        // Math label (SwiftMath native rendering)
        mathLabel.textColor = .white
        mathLabel.fontSize = 28
        mathLabel.labelMode = .display
        mathLabel.textAlignment = .center
        mathLabel.backgroundColor = .clear
        mathLabel.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(mathLabel)

        // Status label
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = UIColor(red: 147/255, green: 153/255, blue: 178/255, alpha: 1)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Preset buttons
        let presetsScroll = UIScrollView()
        presetsScroll.showsHorizontalScrollIndicator = false
        presetsScroll.translatesAutoresizingMaskIntoConstraints = false

        let presetsStack = UIStackView()
        presetsStack.axis = .horizontal
        presetsStack.spacing = 8
        presetsStack.translatesAutoresizingMaskIntoConstraints = false
        presetsScroll.addSubview(presetsStack)

        for (i, (name, _)) in presets.enumerated() {
            let btn = UIButton(type: .system)
            var cfg = UIButton.Configuration.filled()
            cfg.title = name
            cfg.baseBackgroundColor = surfaceColor
            cfg.baseForegroundColor = accentColor
            cfg.cornerStyle = .capsule
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
                var attr = attr
                attr.font = UIFont.systemFont(ofSize: 12, weight: .medium)
                return attr
            }
            btn.configuration = cfg
            btn.tag = i
            btn.addTarget(self, action: #selector(presetTapped(_:)), for: .touchUpInside)
            presetsStack.addArrangedSubview(btn)
        }

        // Layout
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(inputField)
        view.addSubview(presetsScroll)
        view.addSubview(previewContainer)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            subtitleLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),

            inputField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            inputField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            inputField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            inputField.heightAnchor.constraint(equalToConstant: 40),

            presetsScroll.topAnchor.constraint(equalTo: inputField.bottomAnchor, constant: 10),
            presetsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            presetsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            presetsScroll.heightAnchor.constraint(equalToConstant: 36),

            presetsStack.topAnchor.constraint(equalTo: presetsScroll.topAnchor),
            presetsStack.leadingAnchor.constraint(equalTo: presetsScroll.leadingAnchor),
            presetsStack.trailingAnchor.constraint(equalTo: presetsScroll.trailingAnchor),
            presetsStack.bottomAnchor.constraint(equalTo: presetsScroll.bottomAnchor),
            presetsStack.heightAnchor.constraint(equalTo: presetsScroll.heightAnchor),

            previewContainer.topAnchor.constraint(equalTo: presetsScroll.bottomAnchor, constant: 12),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            previewContainer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            mathLabel.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 16),
            mathLabel.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 16),
            mathLabel.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -16),
            mathLabel.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -16),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
    }

    private func renderLaTeX(_ latex: String) {
        mathLabel.latex = latex

        var error: NSError?
        let _ = MTMathListBuilder.build(fromString: latex, error: &error)
        if let error = error {
            statusLabel.text = "Parse error: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.text = "Rendered with SwiftMath (Latin Modern font)"
            statusLabel.textColor = UIColor(red: 147/255, green: 153/255, blue: 178/255, alpha: 1)
        }
    }

    @objc private func inputChanged() {
        guard let text = inputField.text, !text.isEmpty else { return }
        renderLaTeX(text)
    }

    @objc private func presetTapped(_ sender: UIButton) {
        let (_, latex) = presets[sender.tag]
        inputField.text = latex
        renderLaTeX(latex)
    }
}

extension LaTeXPreviewViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
