import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        if window == nil {
            window = UIWindow(windowScene: windowScene)
        }
        window?.makeKeyAndVisible()

        // Show onboarding on first launch
        if !UserDefaults.standard.bool(forKey: "onboarding.completed") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let root = self?.window?.rootViewController else { return }
                let onboarding = OnboardingViewController()
                onboarding.modalPresentationStyle = .fullScreen
                root.present(onboarding, animated: true)
            }
        }
    }
}
