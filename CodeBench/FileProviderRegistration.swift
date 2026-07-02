import FileProvider

/// Registers the CodeBench Workspace as a File Provider domain (the top-level
/// Files Location, like iSH) and keeps it live by signalling the system
/// whenever the Workspace changes. Call `registerIfPossible()` once at launch,
/// and `signalChange()` after the app mutates files / on foreground.
///
/// Entirely gated on the App Group being provisioned: without the
/// `group.euleryu.CodeBench` entitlement everything here is a no-op.
enum FileProviderRegistration {

    private static let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(rawValue: AppPaths.fileProviderDomainID),
        displayName: "CodeBench")

    private static var watchSources: [DispatchSourceFileSystemObject] = []
    private static let watchQueue = DispatchQueue(label: "ai.codebench.fpwatch")
    private static var debounce: DispatchWorkItem?

    /// Domain identifiers from earlier app generations — removed on launch so
    /// the user never keeps a stale/duplicate "CodeBench" Location. Both were
    /// the iOS-16 *replicated* extension (the ones that got stuck "Paused");
    /// the current domain uses the legacy non-replicated model instead. Files
    /// live in the App Group, so removing a domain's replica never loses data.
    private static let legacyDomainIDs = ["CodeBenchWorkspace", "CodeBenchFiles", "CodeBenchLocal", "CodeBenchLocal2", "CodeBenchRep", "CodeBenchHome"]

    static func registerIfPossible() {
        guard AppPaths.appGroupAvailable else {
            AppPaths.fpLog("app.register SKIPPED — App Group unavailable")
            return
        }
        AppPaths.fpLog("app.register start domain=\(AppPaths.fileProviderDomainID)")

        // Make sure the shared Workspace exists and holds the user's files.
        AppPaths.migrateWorkspaceIfNeeded()
        AppPaths.ensureWorkspace()

        // Drop any earlier-generation domain first, THEN add the current one,
        // so the new Documents-rooted Location replaces it cleanly instead of
        // reconciling a stale replica.
        removeLegacyDomains {
            NSFileProviderManager.add(domain) { error in
                if let error = error {
                    AppPaths.fpLog("app.add FAILED: \(error.localizedDescription)")
                    NSLog("[FileProvider] failed to add domain: \(error.localizedDescription)")
                } else {
                    AppPaths.fpLog("app.add OK domain=\(AppPaths.fileProviderDomainID)")
                    NSLog("[FileProvider] CodeBench Location registered (Documents-rooted)")
                    signalChange()                      // populate promptly
                }
            }
        }
        startWatching()
    }

    private static func removeLegacyDomains(_ done: @escaping () -> Void) {
        let group = DispatchGroup()
        for id in legacyDomainIDs where id != AppPaths.fileProviderDomainID {
            group.enter()
            let legacy = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: id), displayName: "CodeBench")
            NSFileProviderManager.remove(legacy) { error in
                AppPaths.fpLog("app.removeLegacy \(id): \(error?.localizedDescription ?? "ok")")
                group.leave()
            }
        }
        group.notify(queue: .main, execute: done)
    }

    /// Tell the Files app the Workspace changed so it re-enumerates. Signals the
    /// **working set** (Apple's documented change channel) plus the root
    /// container. Both enumerations are now shallow + paged, so this is cheap to
    /// service. No-op without the App Group.
    static func signalChange() {
        guard AppPaths.appGroupAvailable else { return }
        let mgr = NSFileProviderManager(for: domain)
        mgr?.signalEnumerator(for: .workingSet) { _ in }
        mgr?.signalEnumerator(for: .rootContainer) { _ in }
        // Also refresh the Workspace container directly, so an open Workspace
        // view picks up new files (7z/binwalk output) live — the root/working
        // set are shallow and wouldn't otherwise reach into it.
        let wsID = AppPaths.identifier(forURL: AppPaths.workspaceURL)
        if wsID != AppPaths.rootIdentifier {
            mgr?.signalEnumerator(for: NSFileProviderItemIdentifier(wsID)) { _ in }
        }
        // The Location root is the container (Library + Documents); the user's
        // files live one level in, under Documents. Signal that container too so
        // an open Documents view refreshes when its children (Workspace,
        // ToolOutputs, Imported, …) change — the root/workingSet sit above it and
        // wouldn't otherwise reach in.
        let docID = AppPaths.identifier(forURL: AppPaths.documentsURL)
        if docID != AppPaths.rootIdentifier {
            mgr?.signalEnumerator(for: NSFileProviderItemIdentifier(docID)) { _ in }
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
    /// storm during big extractions that made the Location show "Paused".
    /// Changes deeper inside a subfolder refresh when the user opens it (its own
    /// enumerator reads disk fresh) and on the next app foreground.
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
    /// no enumerator flood, no throttling.
    private static func onWatchEvent() {
        debounce?.cancel()
        let work = DispatchWorkItem { signalChange() }
        debounce = work
        watchQueue.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Optional: remove the Location (e.g. from a Settings toggle).
    static func unregister() {
        NSFileProviderManager.remove(domain) { _ in }
    }
}
