import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        if window == nil {
            // Plain UIWindow. The KeyCaptureWindow subclass used to
            // sit here to forward arrow keys to the Konami tracker
            // (up-up-down-down → Developer Panel), but that easter
            // egg was removed; no need to override sendEvent anymore.
            window = UIWindow(windowScene: windowScene)
        }
        window?.makeKeyAndVisible()

        // Dark-only app: force the entire window — every view controller,
        // every modal, and the onboarding flow — to dark so UIKit system
        // dynamic colors can never resolve to their light / white variants.
        // (Light / auto device appearance was turning the content pane solid
        // white while the hard-coded-dark sidebar stayed dark; the in-app
        // theme is dark everywhere.)
        window?.overrideUserInterfaceStyle = .dark

        // Pre-warm a WKWebView so the first preview pane / pywebview
        // page comes up instantly instead of waiting on WebContent
        // process launch (which is 150-400 ms cold).
        WebViewWarmupPool.shared.warmUp()

        // Show onboarding on first launch
        if !UserDefaults.standard.bool(forKey: "onboarding.completed") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let root = self?.window?.rootViewController else { return }
                let onboarding = OnboardingViewController()
                onboarding.modalPresentationStyle = .fullScreen
                root.present(onboarding, animated: true)
            }
        }

        // Cold-launch path: user picked CodeBench from Files-app's
        // "Open With…" sheet, dropped a file onto our icon, etc.
        // The URLs arrive in connectionOptions.urlContexts. Defer the
        // file-load until the editor scene has had a chance to wire
        // its NotificationCenter observer (~0.5 s after launch).
        if !connectionOptions.urlContexts.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.handleIncomingURLs(connectionOptions.urlContexts)
            }
        }
    }

    /// About to switch away (very often to the Files app) — push the latest
    /// Workspace state so the CodeBench Location is up to date when they look.
    func sceneDidEnterBackground(_ scene: UIScene) {
        FileProviderRegistration.signalChange()
    }

    /// Returning to CodeBench — re-signal in case the Location drifted.
    func sceneWillEnterForeground(_ scene: UIScene) {
        FileProviderRegistration.signalChange()
    }

    /// Already-running app, user opens another file via Files /
    /// Share Sheet / drag-drop while CodeBench is foreground.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handleIncomingURLs(URLContexts)
    }

    /// Copy each external file into our Documents/Imported/ dir (so the
    /// security-scoped URL goes away cleanly — the editor's auto-save
    /// path doesn't need to keep `startAccessingSecurityScopedResource`
    /// active forever) and post a notification per file. The editor
    /// observer in CodeEditorViewController loads the most recent one.
    private func handleIncomingURLs(_ contexts: Set<UIOpenURLContext>) {
        let fm = FileManager.default
        // Inside the App Group Workspace so imported files show in the Files
        // Location alongside the user's projects.
        let importedDir = AppPaths.importedURL
        try? fm.createDirectory(at: importedDir,
                                withIntermediateDirectories: true)

        for ctx in contexts {
            let src = ctx.url
            // Pick a unique destination filename so re-importing doesn't
            // clobber an earlier copy.
            var dst = importedDir.appendingPathComponent(src.lastPathComponent)
            var n = 1
            let stem = (src.lastPathComponent as NSString).deletingPathExtension
            let ext  = (src.lastPathComponent as NSString).pathExtension
            while fm.fileExists(atPath: dst.path) {
                let candidateName = ext.isEmpty ? "\(stem)_\(n)"
                                                : "\(stem)_\(n).\(ext)"
                dst = importedDir.appendingPathComponent(candidateName)
                n += 1
            }
            let dstFinal = dst

            // Copy OFF the main thread. A large file (video, dataset, or a big
            // HTML embedding a base64 video) makes a synchronous copyItem block
            // the UI — the app looks frozen during "Open with…". The security-
            // scoped access must stay open for the whole copy, so we start/stop
            // it inside the background closure and post the notification back on
            // main once the copy finishes.
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = src.startAccessingSecurityScopedResource()
                defer { if scoped { src.stopAccessingSecurityScopedResource() } }
                do {
                    try fm.copyItem(at: src, to: dstFinal)
                    NSLog("[scene] imported %@ → %@", src.lastPathComponent, dstFinal.path)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .openExternalFile, object: dstFinal)
                    }
                } catch {
                    NSLog("[scene] import failed for %@: %@",
                          src.lastPathComponent, error.localizedDescription)
                }
            }
        }
    }
}
