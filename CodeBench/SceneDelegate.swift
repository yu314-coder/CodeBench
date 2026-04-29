import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
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
        guard let docsBase = fm.urls(for: .documentDirectory,
                                     in: .userDomainMask).first else { return }
        let importedDir = docsBase.appendingPathComponent("Imported")
        try? fm.createDirectory(at: importedDir,
                                withIntermediateDirectories: true)

        for ctx in contexts {
            let src = ctx.url
            // Files app URLs are security-scoped — must start access
            // before reading and stop after copying.
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }

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

            do {
                try fm.copyItem(at: src, to: dst)
                NSLog("[scene] imported %@ → %@",
                      src.lastPathComponent, dst.path)
                NotificationCenter.default.post(name: .openExternalFile,
                                                object: dst)
            } catch {
                NSLog("[scene] import failed for %@: %@",
                      src.lastPathComponent,
                      error.localizedDescription)
            }
        }
    }
}
