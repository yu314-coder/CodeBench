import AVFoundation
import UIKit
import UserNotifications

/// Keeps long-running computation alive when the app is backgrounded.
///
/// iOS will suspend a regular foreground app within ~5 seconds of the
/// user swiping away or locking the screen. `beginBackgroundTask` alone
/// gives at most ~3 minutes of grace period — enough for short scripts
/// but not for a full manim render (often 5–15 minutes).
///
/// To survive longer, this guard combines two mechanisms:
///
///  1. **`UIApplication.beginBackgroundTask`** — covers the brief gap
///     while the audio session is being activated, and provides a clean
///     expiration handler if iOS ever revokes our background privilege.
///  2. **Silent audio loop on `AVAudioSession(.playback)`** — declares
///     the app as actively playing audio, which qualifies for the
///     "audio" `UIBackgroundModes` entry. The buffer is genuinely
///     zero-amplitude silence (no user-audible output, mixes with
///     other audio so we don't interrupt music), but the OS treats
///     the app as audio-active and lets the entire process keep
///     running indefinitely while the audio engine is running.
///
/// In addition we listen for AVAudioSession interruption + media-server-
/// reset notifications. iOS will tear down the audio session if a phone
/// call comes in, the route changes (Bluetooth disconnect), or the
/// media services daemon restarts. When that happens we re-activate the
/// session so the background privilege isn't permanently lost.
///
/// Reference-counted: nested start()/stop() pairs are safe — only the
/// outermost stop() actually tears down the session, so two concurrent
/// runs (Python + the AI generator, say) won't fight over it.
final class BackgroundExecutionGuard {
    static let shared = BackgroundExecutionGuard()

    private let lock = NSLock()
    private var depth: Int = 0
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var bufferAttached = false
    private var sessionActive = false
    private var notificationsRegistered = false

    private init() {}

    /// Begin keeping the app alive in background. Idempotent — call once
    /// per logical unit of work; nested calls are tracked via a depth
    /// counter so the guard only actually starts once.
    /// Title remembered between start() and stop() so the lock-screen
    /// banner / local-notification fallback show the actual script name.
    private var currentTitle: String = "CodeBench"
    private var currentSubtitle: String = "Running script…"
    /// Pending UNNotificationRequest identifier for the "still running"
    /// fallback alert, cancelled in stopMain().
    private static let backgroundReminderID = "CodeBench.bgReminder"

    /// Backwards-compatible entry point — same as the old `start()`.
    /// Prefer `start(title:subtitle:)` so the Live Activity / fallback
    /// notification can show what's actually running.
    func start() { start(title: nil, subtitle: nil) }

    /// Begin keeping the app alive in background. Idempotent — call once
    /// per logical unit of work; nested calls are tracked via a depth
    /// counter so the guard only actually starts once.
    ///
    /// `title` is what the user sees in the Dynamic Island / lock-screen
    /// banner (e.g. the script filename or scene name). `subtitle` is
    /// the dynamic status (e.g. "Rendering scene"). Both are optional —
    /// defaults are used when nil/empty.
    func start(title: String?, subtitle: String?) {
        // Audio session and engine setup hits Core Audio APIs that
        // strongly prefer the main thread. If we're being called from
        // a background queue, hop to main synchronously so the rest of
        // our state machine is consistent.
        let t = (title?.isEmpty == false) ? title! : "CodeBench"
        let s = (subtitle?.isEmpty == false) ? subtitle! : "Running script…"
        if Thread.isMainThread {
            startMain(title: t, subtitle: s)
        } else {
            DispatchQueue.main.sync { self.startMain(title: t, subtitle: s) }
        }
    }

    func stop() {
        if Thread.isMainThread {
            stopMain()
        } else {
            DispatchQueue.main.sync { stopMain() }
        }
    }

    private func startMain(title: String, subtitle: String) {
        lock.lock()
        defer { lock.unlock() }
        depth += 1
        guard depth == 1 else {
            NSLog("[BGGuard] start (re-entrant, depth now %d)", depth)
            return
        }
        currentTitle = title
        currentSubtitle = subtitle
        registerNotificationsLocked()
        beginBackgroundTaskLocked()
        startAudioLocked()
        // Surface a Live Activity so the user can see their render is
        // still working from the lock screen / Dynamic Island. No-op on
        // iOS < 16.1, when the user has disabled activities, or when no
        // Widget Extension target is registered for the attributes type
        // (we then fall through to the local-notification path below).
        RenderLiveActivityController.shared.start(
            title: title, status: subtitle)
        // Belt-and-braces: if the Live Activity can't display (no
        // widget extension installed yet, or user denied permission),
        // schedule a local notification that fires ~10s after the
        // app backgrounds so the user still gets a "render in
        // progress" surface. Cancelled in stopMain when the run
        // finishes — so users only see it if the run actually
        // outlives the foreground session.
        scheduleBackgroundReminderLocked(title: title, subtitle: subtitle)
        NSLog("[BGGuard] start title=%@ subtitle=%@  state: depth=%d sessionActive=%d engineRunning=%d bgTask=%lu  appState=%d",
              title, subtitle, depth,
              sessionActive ? 1 : 0,
              audioEngine.isRunning ? 1 : 0,
              UInt(bgTaskID.rawValue),
              UIApplication.shared.applicationState.rawValue)
    }

    private func stopMain() {
        lock.lock()
        defer { lock.unlock() }
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else {
            NSLog("[BGGuard] stop (still held, depth now %d)", depth)
            return
        }
        stopAudioLocked()
        endBackgroundTaskLocked()
        RenderLiveActivityController.shared.stop(finalStatus: "Done")
        cancelBackgroundReminderLocked()
        NSLog("[BGGuard] released (title=%@)", currentTitle)
    }

    /// Optional: callers can push a finer-grained progress message
    /// while the activity is alive (e.g. "Rendering frame 240/600").
    /// Wraps `RenderLiveActivityController.update` so the Python
    /// runtime doesn't have to know about ActivityKit.
    func updateLiveStatus(_ status: String, progress: Double? = nil) {
        currentSubtitle = status
        RenderLiveActivityController.shared.update(
            status: status, progress: progress)
    }

    // MARK: - Local-notification fallback

    /// Schedule a "still running" alert ~10 seconds in the future.
    /// Designed to fire ONLY if the app is backgrounded by then; if
    /// the run finishes before the user backgrounds, stopMain cancels
    /// it and the user never sees anything. Avoids pestering the user
    /// for sub-10-second runs.
    ///
    /// This is the safety net for the case where the Widget Extension
    /// target hasn't been added yet — without it, the Live Activity
    /// won't appear, but a local notification still gives the user a
    /// "yes your script is still working" signal from the lock screen.
    private func scheduleBackgroundReminderLocked(title: String, subtitle: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, err in
            if let err = err {
                NSLog("[BGGuard] notification auth failed: %@",
                      err.localizedDescription)
            }
            guard granted else {
                NSLog("[BGGuard] notifications not authorized — skipping fallback alert")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Still running: \(title)"
            content.body = subtitle
            content.sound = nil
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: 10, repeats: false)
            let req = UNNotificationRequest(
                identifier: Self.backgroundReminderID,
                content: content, trigger: trigger)
            center.add(req) { err in
                if let err = err {
                    NSLog("[BGGuard] reminder schedule failed: %@",
                          err.localizedDescription)
                }
            }
        }
    }

    private func cancelBackgroundReminderLocked() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.backgroundReminderID])
        // If it already fired (run outlived the 10s threshold), also
        // pull from the delivered list so the lock screen clears.
        center.removeDeliveredNotifications(
            withIdentifiers: [Self.backgroundReminderID])
    }

    // MARK: - Background task

    private func beginBackgroundTaskLocked() {
        // The expiration handler fires if iOS revokes the background
        // privilege early (rare with the audio session active, but
        // possible if memory pressure spikes). Just clean up our token —
        // the silent audio loop keeps us alive past this expiration.
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "OfflinaiCompute") { [weak self] in
            guard let self else { return }
            NSLog("[BGGuard] !!! beginBackgroundTask EXPIRED — iOS revoked the bg-task token (audio session should still keep us alive)")
            self.lock.lock()
            defer { self.lock.unlock() }
            self.endBackgroundTaskLocked()
        }
        if bgTaskID == .invalid {
            NSLog("[BGGuard] !!! beginBackgroundTask returned .invalid — running without bg-task fallback")
        }
    }

    private func endBackgroundTaskLocked() {
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
    }

    // MARK: - Silent audio

    private func startAudioLocked() {
        do {
            // `.playback` is the only category that's guaranteed to
            // continue when the screen locks. `.mixWithOthers` makes
            // sure music the user is already listening to keeps
            // playing; without it our silent stream would silence the
            // user's Spotify/Apple Music playback.
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true,
                options: [.notifyOthersOnDeactivation])
            sessionActive = true
            NSLog("[BGGuard] AVAudioSession activated (playback / mixWithOthers)")
        } catch {
            NSLog("[BGGuard] !!! AVAudioSession activate FAILED: %@", error.localizedDescription)
            return
        }

        // 22.05 kHz mono float32 — small footprint, plenty of bandwidth
        // for a constant-zero buffer.
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 22050, channels: 1)!
        let frameCount: AVAudioFrameCount = 22050  // 1 second
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: frameCount) else {
            NSLog("[BGGuard] !!! PCMBuffer alloc failed")
            return
        }
        buffer.frameLength = frameCount
        // Buffer is already zero-filled — calloc'd by the allocator.

        if !bufferAttached {
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode,
                                format: format)
            bufferAttached = true
        }

        do {
            try audioEngine.start()
            NSLog("[BGGuard] AudioEngine started")
        } catch {
            NSLog("[BGGuard] !!! AudioEngine start FAILED: %@", error.localizedDescription)
            return
        }
        // `.loops` makes the silent buffer repeat indefinitely without
        // CPU cost — the engine just keeps replaying the same memory.
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        player.play()
    }

    private func stopAudioLocked() {
        if player.isPlaying { player.stop() }
        if audioEngine.isRunning { audioEngine.stop() }
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false,
                options: [.notifyOthersOnDeactivation])
            sessionActive = false
        }
    }

    // MARK: - Interruption / app-state notifications

    private func registerNotificationsLocked() {
        guard !notificationsRegistered else { return }
        notificationsRegistered = true
        let nc = NotificationCenter.default

        nc.addObserver(self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil)
        nc.addObserver(self,
            selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil)
        nc.addObserver(self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil)
        nc.addObserver(self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil)
        nc.addObserver(self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil)
        nc.addObserver(self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            NSLog("[BGGuard] !!! interruption BEGAN — iOS suspended our audio session")
        case .ended:
            NSLog("[BGGuard] interruption ended — re-activating audio session")
            // Re-activate. If we hold the lock here we're fine because
            // notifications fire on the main run loop and start/stop
            // also acquire on main.
            lock.lock()
            defer { self.lock.unlock() }
            if depth > 0 {
                stopAudioLocked()
                startAudioLocked()
            }
        @unknown default:
            break
        }
    }

    @objc private func handleMediaServicesReset(_ note: Notification) {
        NSLog("[BGGuard] !!! media services were reset — rebuilding audio engine")
        lock.lock()
        defer { lock.unlock() }
        if depth > 0 {
            stopAudioLocked()
            // Audio engine is a long-lived object; after a media-server
            // reset its connections are stale. Reset bufferAttached so
            // we re-do attach/connect on next start.
            bufferAttached = false
            startAudioLocked()
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
        NSLog("[BGGuard] route change reason=%lu", reasonRaw)
    }

    @objc private func handleDidEnterBackground() {
        NSLog("[BGGuard] app -> background  (sessionActive=%d engineRunning=%d depth=%d)",
              sessionActive ? 1 : 0,
              audioEngine.isRunning ? 1 : 0,
              depth)
    }

    @objc private func handleWillEnterForeground() {
        NSLog("[BGGuard] app -> foreground  (sessionActive=%d engineRunning=%d depth=%d)",
              sessionActive ? 1 : 0,
              audioEngine.isRunning ? 1 : 0,
              depth)
    }

    @objc private func handleMemoryWarning() {
        // Just log — we can't do useful cleanup here (the heavy
        // allocations live in the manim Python heap, out of our reach
        // from Swift). But knowing a warning fired narrows down what
        // killed us if jetsam follows.
        NSLog("[BGGuard] !!! memory warning received  (depth=%d)", depth)
    }
}
