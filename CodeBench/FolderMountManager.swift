import UIKit
import Foundation
import UniformTypeIdentifiers

/// Persistent mount table for folders outside the app sandbox.
/// User picks a folder once via UIDocumentPickerViewController in
/// `.folder` mode; we save a security-scoped bookmark; on every app
/// launch we resolve it and call `startAccessingSecurityScopedResource()`
/// so the path stays readable + writable for the whole session.
///
/// Mounted folders are exposed under `~/Documents/Mounts/<label>/` as
/// symlinks so the shell, ls, cd, and Python's open() all see them as
/// normal directories — no per-syscall scope bracketing required.
///
/// Bookmarks survive app restart (stored in
/// `~/Documents/.codebench_mounts.json`). On launch, every bookmark
/// is re-resolved; stale ones are auto-dropped with a log line.

final class FolderMountManager: NSObject {
    static let shared = FolderMountManager()

    struct Mount: Codable {
        var label: String
        var bookmark: Data
        // Re-populated each launch; not persisted (the URL changes if
        // the user's storage provider remounts at a new path).
        var resolvedURL: URL? = nil
        var isStale: Bool = false

        enum CodingKeys: String, CodingKey { case label, bookmark }
    }

    private(set) var mounts: [Mount] = []
    private let queue = DispatchQueue(label: "FolderMountManager.io")

    // MARK: - Paths

    private var manifestURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(".codebench_mounts.json")
    }
    var mountsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Mounts", isDirectory: true)
    }

    // MARK: - Init

    private override init() {
        super.init()
        try? FileManager.default.createDirectory(at: mountsDir, withIntermediateDirectories: true)
        load()
        // Resolve every bookmark at launch and acquire access for
        // the session. Symlinks get refreshed too.
        for i in mounts.indices {
            resolveAndActivate(index: i)
        }
        refreshSymlinks()
    }

    deinit {
        // Polite cleanup. iOS reaps on termination anyway.
        for m in mounts {
            m.resolvedURL?.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let list = try? JSONDecoder().decode([Mount].self, from: data)
        else { return }
        mounts = list
    }
    private func save() {
        guard let data = try? JSONEncoder().encode(mounts) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - Public API

    /// Present the system folder picker. On selection, record the
    /// bookmark, activate scoped access, create a symlink at
    /// `~/Documents/Mounts/<label>/` → resolved URL.
    func presentPicker(from host: UIViewController,
                       label proposedLabel: String? = nil,
                       completion: @escaping (Result<Mount, Error>) -> Void) {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        let coordinator = PickerCoordinator(
            proposedLabel: proposedLabel) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.adoptPickedFolder(url: url, label: proposedLabel,
                                       completion: completion)
            case .failure(let e):
                completion(.failure(e))
            }
        }
        picker.delegate = coordinator
        // Anchor coordinator to picker so it lives long enough.
        objc_setAssociatedObject(picker, &PickerCoordinator.key,
                                 coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        host.present(picker, animated: true)
    }

    private func adoptPickedFolder(url: URL, label: String?,
                                   completion: (Result<Mount, Error>) -> Void) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if !didStart { /* nothing to stop */ } }
        do {
            let bookmark = try url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil, relativeTo: nil)
            let chosenLabel = label?.isEmpty == false
                ? label! : url.lastPathComponent
            // Avoid duplicates by label.
            let unique = uniqueLabel(chosenLabel)
            var mount = Mount(label: unique, bookmark: bookmark,
                              resolvedURL: url, isStale: false)
            mounts.append(mount)
            save()
            createSymlink(for: mount)
            // Mount keeps the scope alive — don't stop here.
            mount.resolvedURL = url
            completion(.success(mount))
        } catch {
            url.stopAccessingSecurityScopedResource()
            completion(.failure(error))
        }
    }

    private func uniqueLabel(_ base: String) -> String {
        let existing = Set(mounts.map { $0.label })
        if !existing.contains(base) { return base }
        for n in 2...99 {
            let cand = "\(base)-\(n)"
            if !existing.contains(cand) { return cand }
        }
        return UUID().uuidString.prefix(8).description
    }

    /// Remove a mount by label: drops the symlink, releases scoped
    /// access, removes from the manifest.
    func unmount(label: String) -> Bool {
        guard let i = mounts.firstIndex(where: { $0.label == label }) else {
            return false
        }
        mounts[i].resolvedURL?.stopAccessingSecurityScopedResource()
        let link = mountsDir.appendingPathComponent(label)
        try? FileManager.default.removeItem(at: link)
        mounts.remove(at: i)
        save()
        return true
    }

    /// Print state for the shell. Returns lines, caller emits them.
    func describe() -> [String] {
        if mounts.isEmpty {
            return ["No mounts. Use `mount` to pick a folder."]
        }
        return mounts.map { m in
            let stale = m.isStale ? " [stale]" : ""
            let url = m.resolvedURL?.path ?? "(not resolved)"
            return "\(m.label.padding(toLength: 20, withPad: " ", startingAt: 0)) → \(url)\(stale)"
        }
    }

    // MARK: - Bookmark resolution

    private func resolveAndActivate(index i: Int) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: mounts[i].bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale) else {
            mounts[i].isStale = true
            return
        }
        mounts[i].resolvedURL = url
        mounts[i].isStale = isStale
        if isStale {
            // Try to refresh the bookmark from the new URL.
            if let fresh = try? url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil) {
                mounts[i].bookmark = fresh
                mounts[i].isStale = false
                save()
            }
        }
        _ = url.startAccessingSecurityScopedResource()
    }

    private func refreshSymlinks() {
        // Wipe + recreate all symlinks under Mounts/ so stale ones
        // disappear and labels match current state.
        if let existing = try? FileManager.default.contentsOfDirectory(at: mountsDir,
                                                                       includingPropertiesForKeys: nil) {
            for u in existing where u.path.hasSuffix("") {
                try? FileManager.default.removeItem(at: u)
            }
        }
        for m in mounts { createSymlink(for: m) }
    }

    private func createSymlink(for m: Mount) {
        guard let url = m.resolvedURL else { return }
        let link = mountsDir.appendingPathComponent(m.label)
        try? FileManager.default.removeItem(at: link)
        do {
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: url)
        } catch {
            // Symlinks across sandbox sometimes blocked — fall back
            // to writing a tiny .txt that points to the real path so
            // at least `ls Mounts/` shows something.
            let hint = url.path.data(using: .utf8) ?? Data()
            try? hint.write(to: link.appendingPathExtension("path"))
        }
    }
}

/// Coordinator pinned to the picker via objc-associated storage so
/// it outlives the picker's parent without forcing every caller to
/// retain it manually.
private final class PickerCoordinator: NSObject, UIDocumentPickerDelegate {
    static var key: UInt8 = 0
    let proposedLabel: String?
    let onResult: (Result<URL, Error>) -> Void

    init(proposedLabel: String?, onResult: @escaping (Result<URL, Error>) -> Void) {
        self.proposedLabel = proposedLabel
        self.onResult = onResult
    }
    func documentPicker(_ c: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let u = urls.first else {
            onResult(.failure(NSError(domain: "FolderMount", code: 0,
                                      userInfo: [NSLocalizedDescriptionKey: "no folder picked"])))
            return
        }
        onResult(.success(u))
    }
    func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) {
        onResult(.failure(NSError(domain: "FolderMount", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "cancelled"])))
    }
}
