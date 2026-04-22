//
//  AppDelegate.swift
//  CodeBench
//
//  Created by Euler on 1/31/26.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}

    // MARK: - Cache Cleanup

    func applicationWillTerminate(_ application: UIApplication) {
        cleanupToolOutputCache()
    }

    /// Delete ToolOutputs directory (manim renders, plots, etc.) on app close.
    /// These are ephemeral — the user can always re-run to regenerate.
    private func cleanupToolOutputCache() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let toolOutputs = docs.appendingPathComponent("ToolOutputs")
        if fm.fileExists(atPath: toolOutputs.path) {
            do {
                let size = fm.allocatedSizeOfDirectory(at: toolOutputs)
                try fm.removeItem(at: toolOutputs)
                print("[Cleanup] Deleted ToolOutputs cache (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
            } catch {
                print("[Cleanup] Failed to delete ToolOutputs: \(error.localizedDescription)")
            }
        }
        // Also clean temp LaTeX files
        let latexSignals = NSTemporaryDirectory() + "latex_signals"
        let latexWork = NSTemporaryDirectory() + "latex_work"
        try? fm.removeItem(atPath: latexSignals)
        try? fm.removeItem(atPath: latexWork)
    }
}

extension FileManager {
    /// Calculate total allocated size of a directory and its contents.
    func allocatedSizeOfDirectory(at url: URL) -> UInt64 {
        guard let enumerator = self.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
               let size = values.totalFileAllocatedSize {
                total += UInt64(size)
            }
        }
        return total
    }
}
