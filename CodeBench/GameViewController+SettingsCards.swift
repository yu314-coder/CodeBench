//
//  GameViewController+SettingsCards.swift
//  CodeBench
//
//  Pure UI factories for the Settings panel — cards, stat chips,
//  badges, separators. Extracted from GameViewController.swift as
//  part of the Tier-2 audit refactor (split files >5 k lines into
//  focused extensions).
//
//  Why these methods are safe to live in an extension:
//   • They take all data through arguments and return fresh views.
//   • They touch no stored properties of GameViewController.
//   • They use `WorkspaceStyle` (a static enum) and standard UIKit only.
//
//  Access was widened from `private` → `internal` (no modifier) so
//  the main GameViewController body can still call them across files.
//  This is harmless: the methods are still scoped to GameViewController
//  instances and have no side-effects.
//

import UIKit

extension GameViewController {

    func makeSettingsCard(header: String, icon: String, tint: UIColor, content: UIView) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemGroupedBackground
        container.layer.cornerRadius = 16
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true

        // Header
        let iconBg = UIView()
        iconBg.backgroundColor = tint.withAlphaComponent(0.15)
        iconBg.layer.cornerRadius = 8
        iconBg.layer.cornerCurve = .continuous
        iconBg.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconBg.widthAnchor.constraint(equalToConstant: 28),
            iconBg.heightAnchor.constraint(equalToConstant: 28)
        ])

        let iconImg = UIImageView(image: UIImage(systemName: icon)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
        iconImg.tintColor = tint
        iconImg.contentMode = .center
        iconImg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.addSubview(iconImg)
        NSLayoutConstraint.activate([
            iconImg.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            iconImg.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor)
        ])

        let headerLabel = UILabel()
        headerLabel.text = header
        headerLabel.font = UIFont.systemFont(ofSize: 15, weight: .bold).rounded
        headerLabel.textColor = .label

        let headerStack = UIStackView(arrangedSubviews: [iconBg, headerLabel])
        headerStack.axis = .horizontal; headerStack.spacing = 10; headerStack.alignment = .center

        // Separator under header
        let sep = UIView()
        sep.backgroundColor = UIColor.separator.withAlphaComponent(0.3)
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 0.5).isActive = true

        let outerStack = UIStackView(arrangedSubviews: [headerStack, sep, content])
        outerStack.axis = .vertical
        outerStack.spacing = 12
        outerStack.setCustomSpacing(10, after: headerStack)
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.isLayoutMarginsRelativeArrangement = true
        outerStack.layoutMargins = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        container.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: container.topAnchor),
            outerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outerStack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    func makeStatChip(icon: String, text: String, color: UIColor) -> UIView {
        let container = UIView()
        container.backgroundColor = color.withAlphaComponent(0.1)
        container.layer.cornerRadius = 10
        container.layer.cornerCurve = .continuous

        let iconView = UIImageView(image: UIImage(systemName: icon)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))
        iconView.tintColor = color
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: 11, weight: .semibold).rounded
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.axis = .horizontal; stack.spacing = 4; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8)
        ])

        return container
    }

    func makeStatBadge(value: String, label: String, color: UIColor) -> UIView {
        let container = UIView()

        let valueLbl = UILabel()
        valueLbl.text = value
        valueLbl.font = UIFont.systemFont(ofSize: 22, weight: .bold).rounded
        valueLbl.textColor = color

        let labelLbl = UILabel()
        labelLbl.text = label
        labelLbl.font = UIFont.systemFont(ofSize: 11, weight: .medium).rounded
        labelLbl.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [valueLbl, labelLbl])
        stack.axis = .vertical; stack.spacing = 2; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        return container
    }

    func makeSettingsSeparator() -> UIView {
        let sep = UIView()
        sep.backgroundColor = UIColor.separator.withAlphaComponent(0.3)
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return sep
    }
}
