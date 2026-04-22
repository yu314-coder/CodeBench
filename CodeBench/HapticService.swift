import UIKit

final class HapticService {
    static let shared = HapticService()

    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()

    private let enabledKey = "haptics.enabled"

    private var isEnabled: Bool {
        // Default to true if not set
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    var enabled: Bool {
        get { isEnabled }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private init() {
        lightImpact.prepare()
        mediumImpact.prepare()
    }

    func tapLight() {
        guard isEnabled else { return }
        lightImpact.impactOccurred()
    }

    func tapMedium() {
        guard isEnabled else { return }
        mediumImpact.impactOccurred()
    }

    func send() {
        guard isEnabled else { return }
        mediumImpact.impactOccurred(intensity: 0.8)
    }

    func modelSwitch() {
        guard isEnabled else { return }
        heavyImpact.impactOccurred(intensity: 0.6)
    }

    func success() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
    }

    func error() {
        guard isEnabled else { return }
        notification.notificationOccurred(.error)
    }
}
