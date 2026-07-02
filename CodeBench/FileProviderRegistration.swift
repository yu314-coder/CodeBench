import FileProvider

/// Keeps the CodeBench Files-app Location (the **legacy** File Provider, like
/// iSH) live by signalling the system whenever the Workspace changes. Call
/// `registerIfPossible()` once at launch, and `signalChange()` after the app
/// mutates files / on foreground.
///
/// ## No domains anymore
/// The extension is the legacy `NSFileProviderExtension` with
/// `NSExtensionFileProviderDocumentGroup` — its Location appears in Files
/// automatically, with no `NSFileProviderDomain` and **no sync engine** (so no
/// sync badge and no "Sync Paused"; that's the iSH model). Every domain earlier
/// generations added is torn down at launch so the stale replicated Location —
/// the one with the perpetual badge — disappears. Files live in the App Group,
/// so removing a domain's replica never loses data.
///
/// Entirely gated on the App Group being provisioned: without the
/// `group.euleryu.CodeBench` entitlement everything here is a no-op.
enum FileProviderRegistration {

    private static var watchSources: [DispatchSourceFileSystemObject] = []
    private static let watchQueue = DispatchQueue(label: "ai.codebench.fpwatch")
    private static var debounce: DispatchWorkItem?

    /// Every domain identifier any earlier app generation added (the last two
    /// are the replicated-model ones). All removed on launch — the legacy
    /// provider needs none.
    private static let staleDomainIDs = [
        "CodeBenchWorkspace", "CodeBenchFiles", "CodeBenchLocal", "CodeBenchLocal2",
        "CodeBenchRep", "CodeBenchHome", "CodeBenchDocs", "CodeBenchDocs2",
    ]

    static func registerIfPossible() {
        guard AppPaths.appGroupAvailable else {
            AppPaths.fpLog("app.register SKIPPED — App Group unavailable")
            return
        }
        AppPaths.fpLog("app.register start (legacy provider, domain-less)")

        // Make sure the shared Workspace exists and holds the user's files.
        AppPaths.migrateWorkspaceIfNeeded()
        AppPaths.ensureWorkspace()

        // Tear down every domain older builds added; the legacy extension's
        // Location shows up on its own (NSExtensionFileProviderDocumentGroup).
        for id in staleDomainIDs {
            let stale = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: id),
                displayName: "CodeBench")
            NSFileProviderManager.remove(stale) { error in
                AppPaths.fpLog("app.removeStale \(id): \(error?.localizedDescription ?? "ok")")
            }
        }

        signalChange()          // populate promptly
        startWatching()
    }

    /// Tell Files the Workspace changed so it re-enumerates. The legacy
    /// provider signals through the **default** manager (no domains). The
    /// working set is Apple's documented change channel; the root container
    /// plus the folders users actually keep open cover live refresh.
    static func signalChange() {
        guard AppPaths.appGroupAvailable else { return }
        let mgr = NSFileProviderManager.default
        mgr.signalEnumerator(for: .workingSet) { _ in }
        mgr.signalEnumerator(for: .rootContainer) { _ in }
        // Signal the Workspace + Documents containers directly, so open views
        // of them pick up new files (7z/binwalk output) live — the
        // root/working set are shallow and wouldn't otherwise reach in.
        let wsID = AppPaths.identifier(forURL: AppPaths.workspaceURL)
        if wsID != AppPaths.rootIdentifier {
            mgr.signalEnumerator(for: NSFileProviderItemIdentifier(wsID)) { _ in }
        }
        let docID = AppPaths.identifier(forURL: AppPaths.documentsURL)
        if docID != AppPaths.rootIdentifier {
            mgr.signalEnumerator(for: NSFileProviderItemIdentifier(docID)) { _ in }
        }
    }

    /// Watch every top-level folder the user sees, so a change to any of them
    /// signals Files to refresh. Crucially this includes **ToolOutputs** (Python
    /// output), **Imported**, and **site-packages** (pip): a file written
    /// directly into one of those changes *that* folder's direct children but
    /// NOT the Documents root — so watching only root + Workspace (as before)
    /// let those changes go unsignalled, and the Location showed "not synced"
    /// until a manual pull-to-refresh.
    ///
    /// We still do NOT watch subfolders recursively — that produced an event
    /// storm during big extractions. Changes deeper inside a subfolder refresh
    /// when the user opens it (its own enumerator reads disk fresh) and on the
    /// next app foreground.
    private static func startWatching() {
        guard AppPaths.appGroupAvailable, watchSources.isEmpty else { return }
        let watched = [
            AppPaths.documentsURL,          // the home's Documents — where the user's folders live
            AppPaths.workspaceURL,
            AppPaths.toolOutputsURL,
            AppPaths.importedURL,
            AppPaths.userSitePackagesURL,
        ]
        for dir in watched {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename],
                queue: watchQueue)
            src.setEventHandler { onWatchEvent() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchSources.append(src)
        }
    }

    /// Coalesce bursts into a single signal. A 1.2 s debounce means a long
    /// extraction triggers roughly one signal per second instead of hundreds —
    /// no enumerator flood. (With the legacy provider a signal is only a
    /// "please re-enumerate" nudge — there's no sync engine to grind.)
    private static func onWatchEvent() {
        debounce?.cancel()
        let work = DispatchWorkItem { signalChange() }
        debounce = work
        watchQueue.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Optional: tear everything down (e.g. from a Settings toggle). The legacy
    /// provider has no domain to remove; stale ones are already handled at
    /// launch, so this only stops the watchers.
    static func unregister() {
        watchSources.forEach { $0.cancel() }
        watchSources.removeAll()
    }
}
