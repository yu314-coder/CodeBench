import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// `ActivityAttributes` for the long-running-render Live Activity. Shared
/// between the main app (which calls `Activity.request`) and the Widget
/// Extension (which provides the lock-screen / Dynamic Island UI).
///
/// `attributes` are immutable for the activity's lifetime — set once
/// at start. `ContentState` holds the values that change as the render
/// progresses (elapsed time, status string, optional progress %).
struct RenderActivityAttributes: Codable, Hashable {

    /// Mutable state — updated as the script makes progress. Keep it
    /// small (Apple recommends < 4 KB total per update) and Codable.
    struct ContentState: Codable, Hashable {
        /// Wall-clock when the activity started. Widget renders an
        /// auto-updating relative timer from this — so we don't have
        /// to push an update every second.
        var startedAt: Date
        /// Short status, e.g. "Rendering scene…" or "Compiling LaTeX…"
        var status: String
        /// Optional 0…1 progress; widget shows a bar when non-nil.
        var progress: Double?
    }

    /// Shown as the activity's headline (the script / scene name, etc.).
    /// Kept on attributes (not state) so it doesn't change mid-render.
    var title: String

    // ActivityAttributes conformance (added below behind the os check —
    // the protocol only exists on iOS 16.1+).
}

#if canImport(ActivityKit)
@available(iOS 16.1, *)
extension RenderActivityAttributes: ActivityAttributes {}
#endif


// MARK: - Controller

/// Single-instance controller that owns the in-flight Live Activity
/// (if any) for a long-running compute. `BackgroundExecutionGuard`
/// drives this from start/stop.
///
/// Runtime requirements:
///   • iOS 16.1 or later (older OSes simply do nothing)
///   • A Widget Extension target with `ActivityConfiguration<RenderActivityAttributes>`
///     in the same app group — without it, `Activity.request` returns
///     nil and we just no-op silently.
///   • `NSSupportsLiveActivities` set to true in the main Info.plist.
final class RenderLiveActivityController {
    static let shared = RenderLiveActivityController()
    private init() {}

#if canImport(ActivityKit)
    @available(iOS 16.1, *)
    private final class Box {
        let activity: Activity<RenderActivityAttributes>
        init(_ a: Activity<RenderActivityAttributes>) { self.activity = a }
    }
    // `Any` so the property compiles on iOS < 16.1 too. We unbox via
    // `as? Box` inside the @available guards.
    private var current: Any?
    private let lock = NSLock()

    func start(title: String, status: String) {
        guard #available(iOS 16.1, *) else { return }
        lock.lock(); defer { lock.unlock() }

        // ActivityKit gates this on user permission + iOS settings —
        // .areActivitiesEnabled flips false if the user has disabled
        // Live Activities for this app. Bail quietly in that case;
        // the bg-task / audio-session guard still keeps us alive.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[LiveActivity] activities disabled by user / system; skipping")
            return
        }
        if current != nil {
            NSLog("[LiveActivity] start() called while one is already active — ignoring")
            return
        }
        let attrs = RenderActivityAttributes(title: title)
        let state = RenderActivityAttributes.ContentState(
            startedAt: Date(), status: status, progress: nil)
        do {
            let act: Activity<RenderActivityAttributes>
            if #available(iOS 16.2, *) {
                // 16.2+ wraps state in an `ActivityContent` that also
                // carries a `staleDate` and (16.2+) relevance score.
                let content = ActivityContent(state: state, staleDate: nil)
                act = try Activity.request(
                    attributes: attrs, content: content, pushType: nil)
            } else {
                act = try Activity.request(
                    attributes: attrs, contentState: state, pushType: nil)
            }
            current = Box(act)
            NSLog("[LiveActivity] started id=%@ title=%@", act.id, title)
        } catch {
            // Common failures here:
            //   (1) No Widget Extension target registered an
            //       ActivityConfiguration<RenderActivityAttributes> —
            //       error.localizedDescription typically mentions
            //       "no widget" or returns the generic
            //       "The operation couldn't be completed".
            //   (2) The user disabled Live Activities for this app
            //       in Settings > <app> > Live Activities.
            //   (3) Memory pressure (rare).
            // Print an actionable hint exactly once per process so the
            // setup gap is obvious from Xcode console.
            NSLog("[LiveActivity] Activity.request failed: %@  "
                  + "— if you haven't added the Widget Extension target yet, "
                  + "see CodeBenchActivityWidget/README.md for the 30s setup. "
                  + "(BackgroundExecutionGuard's local-notification fallback "
                  + "still surfaces a 'still running' alert if the run "
                  + "outlives foreground.)",
                  error.localizedDescription)
        }
    }

    func update(status: String, progress: Double? = nil) {
        guard #available(iOS 16.1, *) else { return }
        lock.lock(); defer { lock.unlock() }
        guard let box = current as? Box else { return }
        Task {
            let new = RenderActivityAttributes.ContentState(
                startedAt: await box.activity.content.state.startedAt,
                status: status,
                progress: progress)
            if #available(iOS 16.2, *) {
                await box.activity.update(
                    ActivityContent(state: new, staleDate: nil))
            } else {
                await box.activity.update(using: new)
            }
        }
    }

    func stop(finalStatus: String = "Done") {
        guard #available(iOS 16.1, *) else { return }
        lock.lock()
        let take = current as? Box
        current = nil
        lock.unlock()
        guard let box = take else { return }
        Task {
            let final = RenderActivityAttributes.ContentState(
                startedAt: await box.activity.content.state.startedAt,
                status: finalStatus,
                progress: 1.0)
            if #available(iOS 16.2, *) {
                await box.activity.end(
                    ActivityContent(state: final, staleDate: nil),
                    dismissalPolicy: .after(Date().addingTimeInterval(8)))
            } else {
                await box.activity.end(using: final, dismissalPolicy: .immediate)
            }
            NSLog("[LiveActivity] ended id=%@", box.activity.id)
        }
    }
#else
    // ActivityKit unavailable (build for non-iOS, or pre-16.1 SDK).
    // No-ops so callers don't need their own #if canImport guards.
    func start(title: String, status: String) {}
    func update(status: String, progress: Double? = nil) {}
    func stop(finalStatus: String = "Done") {}
#endif
}
