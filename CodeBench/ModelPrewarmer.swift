import Foundation

/// Pre-load the most recently used GGUF model on app launch so the
/// user's first AI prompt doesn't pay a 5-10 second warm-up.
///
/// RAM safety: we only pre-load when ALL of the following hold:
///   • A "most recently loaded" path is recorded.
///   • The file still exists.
///   • The model's on-disk size is < 60% of available memory at boot.
///   • The user hasn't disabled this in Settings (opt-out).
///
/// Without these guards, pre-loading a 5 GB model on a freshly-
/// booted 8 GB iPad would push the app into jetsam range before the
/// user even saw the editor.

enum ModelPrewarmer {
    private static let mruPathKey = "model.mru.path"
    private static let mruSlotKey  = "model.mru.slot"
    private static let disableKey  = "model.prewarm.disabled"

    /// Call after the model was successfully loaded for any slot.
    /// Persists the path so the NEXT launch can pre-load it.
    static func recordLoaded(path: String, slot: Int) {
        UserDefaults.standard.set(path, forKey: mruPathKey)
        UserDefaults.standard.set(slot, forKey: mruSlotKey)
    }

    /// Drives the pre-load. Call once from `applicationDidFinishLaunching`
    /// (or scene-connect) on a background queue. Safe to call multiple
    /// times — idempotent.
    static func prewarmIfSensible(loader: @escaping (URL, Int) -> Void) {
        guard !UserDefaults.standard.bool(forKey: disableKey) else { return }
        guard let path = UserDefaults.standard.string(forKey: mruPathKey),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }
        let slot = UserDefaults.standard.integer(forKey: mruSlotKey)
        let avail = availableMemoryBytes()
        let modelSize = (try? FileManager.default
            .attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        // 60% budget: model + KV cache + transient buffers under it.
        guard modelSize > 0,
              avail > Int(Double(modelSize) * 1.7) else {
            NSLog("[prewarm] skipping — model=\(modelSize / (1024*1024)) MB, avail=\(avail / (1024*1024)) MB")
            return
        }
        NSLog("[prewarm] eligible — loading \(URL(fileURLWithPath: path).lastPathComponent) in background")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            // 1.5 s delay so the editor finishes laying out first.
            loader(URL(fileURLWithPath: path), slot)
        }
    }

    static func disable() { UserDefaults.standard.set(true, forKey: disableKey) }
    static func enable()  { UserDefaults.standard.set(false, forKey: disableKey) }
    static var isDisabled: Bool { UserDefaults.standard.bool(forKey: disableKey) }

    private static func availableMemoryBytes() -> Int {
        guard let h = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                            "os_proc_available_memory") else { return 0 }
        let fn = unsafeBitCast(h, to: (@convention(c) () -> Int).self)
        return fn()
    }
}
