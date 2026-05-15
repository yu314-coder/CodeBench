import Foundation
import UIKit

/// Manages iOS background-time extension for long-running tasks (model
/// training in particular). Without this, iOS suspends the app ~30s
/// after the user moves it to the background, even when there's active
/// work in progress.
///
/// Python (in `_cb_background.py`) calls `cb_bg_acquire` to request the
/// extension and `cb_bg_release` when it's done. The expiration handler
/// calls release as well, so iOS can suspend cleanly without
/// force-killing — and the Python side has been auto-checkpointing all
/// along, so worst-case there's only a few steps of lost progress.
///
/// Uses `UIApplication.beginBackgroundTask` (immediate extension,
/// usually grants up to a few minutes; AC power tends to extend it
/// further). `BGProcessingTaskRequest` for hours-long runs is a
/// separate, more complex mechanism — not implemented here.

public final class BackgroundTimeManager {
    public static let shared = BackgroundTimeManager()
    private var taskId: UIBackgroundTaskIdentifier = .invalid
    private let lock = NSLock()

    public func acquire() {
        lock.lock(); defer { lock.unlock() }
        guard taskId == .invalid else { return }     // already holding
        taskId = UIApplication.shared.beginBackgroundTask(
            withName: "CodeBenchTraining"
        ) { [weak self] in
            // Expiration handler — iOS is about to kill us. End the
            // task so iOS suspends cleanly. Python's polling loop will
            // see `time_remaining()` drop below its threshold first
            // (the expiration handler fires only when it's already <5s
            // or so), so well-written training loops checkpoint before
            // we even get here.
            self?.release()
        }
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard taskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskId)
        taskId = .invalid
    }

    public func timeRemaining() -> Double {
        return UIApplication.shared.backgroundTimeRemaining
    }
}

// ─── C entry points reachable from Python via dlopen(NULL) + dlsym ──
// These three symbols are added to OTHER_LDFLAGS via -Wl,-exported_symbol
// (same mechanism as the Metal bridge) so they survive TestFlight /
// App Store dead-stripping.

@_cdecl("cb_bg_acquire")
public func cb_bg_acquire() {
    BackgroundTimeManager.shared.acquire()
}

@_cdecl("cb_bg_release")
public func cb_bg_release() {
    BackgroundTimeManager.shared.release()
}

@_cdecl("cb_bg_time_remaining")
public func cb_bg_time_remaining() -> Double {
    return BackgroundTimeManager.shared.timeRemaining()
}

/// Hard reference to all three @_cdecl entry points so iOS dead-
/// stripping can't drop them. Same pattern as _cbMetalBridgeKeepAlive
/// in MetalMatmulBridge.swift — taking the address alone isn't enough;
/// a direct call site (with side-effect-free args) is.
public func _cbBackgroundKeepAlive() -> Double {
    cb_bg_acquire()
    cb_bg_release()
    return cb_bg_time_remaining()
}
