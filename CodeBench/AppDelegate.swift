//
//  AppDelegate.swift
//  CodeBench
//
//  Created by Euler on 1/31/26.
//

import UIKit
import BackgroundTasks

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    /// BGTaskScheduler identifiers. Must match
    /// ``BGTaskSchedulerPermittedIdentifiers`` in Info.plist exactly,
    /// or ``register(forTaskWithIdentifier:)`` raises at launch.
    static let bgRenderTaskID = "ai.codebench.background-render"
    static let bgAITaskID     = "ai.codebench.background-ai"
    /// Stash the keep-alive results somewhere global so the compiler
    /// can't dead-code-eliminate the calls. Swift global lets always
    /// emit a real load, which transitively forces the linker to
    /// keep the @_cdecl symbols Python reaches via dlopen(NULL):
    ///   - cb_metal_available / cb_metal_matmul_ex  (PyTorch GPU bridge)
    ///   - cb_bg_acquire / cb_bg_release / cb_bg_time_remaining
    ///       (background-time extension)
    ///   - cb_swift_execute / cb_swift_free
    ///       (Swift tree-walking interpreter — `swift file.swift` from
    ///       the terminal)
    private static let _metalBridgeAnchor: Int = _cbMetalBridgeKeepAlive()
    private static let _backgroundBridgeAnchor: Double = _cbBackgroundKeepAlive()
    private static let _swiftBridgeAnchor: Int = _cbSwiftBridgeKeepAlive()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = AppDelegate._metalBridgeAnchor       // touch anchors at launch
        _ = AppDelegate._backgroundBridgeAnchor
        _ = AppDelegate._swiftBridgeAnchor

        // Register BGTaskScheduler handlers for the identifiers declared
        // in Info.plist. MUST happen synchronously in didFinishLaunching
        // — calling register() after launch raises a fatal exception
        // ("All launch handlers must be registered before application
        // finishes launching"). The handlers fire later (when iOS
        // schedules them — typically minutes to hours after submit())
        // to give long-running renders / inference up to 10 extra
        // minutes after the app has been backgrounded and the initial
        // ``beginBackgroundTask`` grace ran out. The actual work is
        // delegated to BackgroundExecutionGuard so the Python side
        // (which holds the long-running state) can resume cleanly.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppDelegate.bgRenderTaskID, using: nil
        ) { task in
            AppDelegate.handleBackgroundTask(task as? BGProcessingTask,
                                              kind: "render")
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppDelegate.bgAITaskID, using: nil
        ) { task in
            AppDelegate.handleBackgroundTask(task as? BGProcessingTask,
                                              kind: "ai")
        }
        return true
    }

    /// Common BGProcessingTask handler — fires when iOS decides to
    /// give us a 10-minute background slot. The actual continuation
    /// of Python work happens via BackgroundExecutionGuard, which
    /// keeps the audio session active to extend execution time;
    /// here we just observe the task lifecycle and tell iOS when
    /// we're done so it doesn't deprioritise future scheduling.
    private static func handleBackgroundTask(_ task: BGProcessingTask?,
                                             kind: String) {
        guard let task = task else { return }
        NSLog("[BGTask:%@] fired", kind)

        // Schedule the next one immediately — BGProcessingTask is
        // one-shot, so without this any subsequent suspension would
        // get no continuation slot. earliestBeginDate=15min so we
        // don't spam the scheduler if work is already done.
        scheduleNextBackgroundTask(kind: kind)

        // Expiration handler — iOS calls this ~30s before reclaiming
        // our slot. Tell BackgroundExecutionGuard to flush + tear
        // down so the Python side can checkpoint cleanly.
        task.expirationHandler = {
            NSLog("[BGTask:%@] iOS reclaiming slot — stopping guard", kind)
            BackgroundExecutionGuard.shared.stop()
            task.setTaskCompleted(success: false)
        }

        // Re-acquire the guard so silent-audio + beginBackgroundTask
        // are both alive for the full slot. Python's already running
        // somewhere in the persistent interpreter; this just keeps
        // the process from being suspended while it does.
        BackgroundExecutionGuard.shared.start(
            title: "CodeBench (background)",
            subtitle: "Continuing long-running task")

        // We don't have a clean "Python is done" signal from here,
        // so just hold the slot for ~9.5 minutes and then complete.
        // The Python work continues regardless until the audio
        // session is torn down or iOS kills us.
        DispatchQueue.global(qos: .background).asyncAfter(
            deadline: .now() + 9.5 * 60
        ) {
            NSLog("[BGTask:%@] held slot to budget — completing", kind)
            task.setTaskCompleted(success: true)
        }
    }

    /// Submit a BGProcessingTaskRequest for the given identifier.
    /// Called from ``handleBackgroundTask`` (chain to next slot) and
    /// from BackgroundExecutionGuard.start() (initial schedule on
    /// app background entry).
    static func scheduleNextBackgroundTask(kind: String) {
        let identifier = (kind == "ai") ? bgAITaskID : bgRenderTaskID
        let request = BGProcessingTaskRequest(identifier: identifier)
        // We genuinely want this scheduled even when the user is
        // on battery — long compute is the point. iOS may still
        // prefer plugged-in/idle and delay accordingly.
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        // 15 min minimum delay so we don't oscillate when a slot
        // completes and re-schedules immediately. iOS may delay
        // further based on system conditions.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            NSLog("[BGTask:%@] scheduled for %@",
                  kind, request.earliestBeginDate?.description ?? "later")
        } catch {
            NSLog("[BGTask:%@] schedule FAILED: %@",
                  kind, error.localizedDescription)
        }
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
