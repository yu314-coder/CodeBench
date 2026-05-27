import Foundation
import WebKit

/// Persistent log of every URL the embedded WKWebView (pywebview
/// preview, manim_app, random_matrix_ESD, etc.) navigates to, plus
/// an on-demand snapshot of cookies from `WKWebsiteDataStore.default`.
///
/// Stored under `Library/Application Support/CodeBench/`:
///   - `browser_history.json`    — append-only ring buffer (5,000 entries)
///   - `browser_cookies.json`    — refreshed each time the viewer opens
///
/// Reachable only via a hidden 5-tap gesture on the Settings title —
/// no menu entry, no surface area in the regular UI. Designed for the
/// user's own debugging / review when they want to see what the app's
/// embedded browser has been doing without a desktop devtools session.
final class BrowserDataStore {

    static let shared = BrowserDataStore()
    private init() { ensureDir() }

    struct Visit: Codable {
        let url: String
        let title: String
        let timestamp: Date
    }

    // MARK: - Paths

    private var baseDir: URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("CodeBench", isDirectory: true)
    }
    private var historyURL:   URL { baseDir.appendingPathComponent("browser_history.json") }
    private var cookiesURL:   URL { baseDir.appendingPathComponent("browser_cookies.json") }
    private var bookmarksURL: URL { baseDir.appendingPathComponent("browser_bookmarks.json") }

    // MARK: - Bookmarks

    struct Bookmark: Codable, Hashable {
        let url: String
        var title: String
        let added: Date
    }

    func loadBookmarks() -> [Bookmark] {
        queue.sync {
            guard let d = try? Data(contentsOf: bookmarksURL),
                  let list = try? JSONDecoder.iso.decode([Bookmark].self, from: d)
            else { return [] }
            return list
        }
    }

    func addBookmark(url: String, title: String) {
        queue.async { [self] in
            var list = readBookmarksUnsynced()
            list.removeAll { $0.url == url }
            list.append(Bookmark(url: url, title: title, added: Date()))
            writeBookmarks(list)
        }
    }

    func removeBookmark(url: String) {
        queue.async { [self] in
            var list = readBookmarksUnsynced()
            list.removeAll { $0.url == url }
            writeBookmarks(list)
        }
    }

    func isBookmarked(url: String) -> Bool {
        queue.sync { readBookmarksUnsynced().contains { $0.url == url } }
    }

    private func readBookmarksUnsynced() -> [Bookmark] {
        (try? JSONDecoder.iso.decode([Bookmark].self,
                                     from: Data(contentsOf: bookmarksURL))) ?? []
    }
    private func writeBookmarks(_ list: [Bookmark]) {
        if let d = try? JSONEncoder.iso.encode(list) {
            try? d.write(to: bookmarksURL, options: .atomic)
        }
    }

    private func ensureDir() {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    // MARK: - History

    private let queue = DispatchQueue(label: "BrowserDataStore.io")
    private let maxEntries = 5_000

    /// Append a visit. Called from PywebviewBridge.didFinish — the
    /// title is fetched async via `evaluateJavaScript("document.title")`
    /// so the entry is upserted: first written with empty title, then
    /// updated when the title resolves.
    func recordVisit(url: String, title: String = "") {
        guard !url.isEmpty,
              !url.hasPrefix("about:"),
              !url.hasPrefix("data:") else { return }
        queue.async { [self] in
            var list = readHistory()
            // Coalesce repeated reloads of the same URL within 2s.
            if let last = list.last,
               last.url == url,
               Date().timeIntervalSince(last.timestamp) < 2.0 {
                if !title.isEmpty {
                    list[list.count - 1] = Visit(url: url, title: title, timestamp: last.timestamp)
                }
            } else {
                list.append(Visit(url: url, title: title, timestamp: Date()))
            }
            if list.count > maxEntries {
                list.removeFirst(list.count - maxEntries)
            }
            writeHistory(list)
        }
    }

    /// Update the most recent entry for `url` with the resolved title.
    /// Cheap because we only walk back a few entries.
    func updateTitle(url: String, title: String) {
        guard !title.isEmpty else { return }
        queue.async { [self] in
            var list = readHistory()
            for i in stride(from: list.count - 1, through: max(0, list.count - 20), by: -1) {
                if list[i].url == url {
                    list[i] = Visit(url: url, title: title, timestamp: list[i].timestamp)
                    writeHistory(list)
                    return
                }
            }
        }
    }

    func loadHistory() -> [Visit] {
        queue.sync { readHistory() }
    }

    func clearHistory() {
        queue.async { [self] in writeHistory([]) }
    }

    private func readHistory() -> [Visit] {
        guard let data = try? Data(contentsOf: historyURL),
              let list = try? JSONDecoder.iso.decode([Visit].self, from: data) else {
            return []
        }
        return list
    }

    private func writeHistory(_ list: [Visit]) {
        if let data = try? JSONEncoder.iso.encode(list) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    // MARK: - Cookies

    struct CookieRow: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let isSecure: Bool
        let isHTTPOnly: Bool
        let expiresDate: Date?
    }

    /// Pull every cookie from `WKWebsiteDataStore.default()` and
    /// persist a JSON snapshot. Returns the rows so the viewer can
    /// render immediately.
    func snapshotCookies(completion: @escaping ([CookieRow]) -> Void) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { [self] cookies in
            let rows = cookies.map { c in
                CookieRow(name: c.name, value: c.value, domain: c.domain,
                          path: c.path, isSecure: c.isSecure, isHTTPOnly: c.isHTTPOnly,
                          expiresDate: c.expiresDate)
            }
            queue.async {
                if let data = try? JSONEncoder.iso.encode(rows) {
                    try? data.write(to: self.cookiesURL, options: .atomic)
                }
                DispatchQueue.main.async { completion(rows) }
            }
        }
    }

    /// Remove every cookie from the shared WKHTTPCookieStore AND
    /// erase the persisted snapshot. Used by the viewer's "Clear All"
    /// action.
    func clearCookies(completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            let group = DispatchGroup()
            for c in cookies {
                group.enter()
                store.delete(c) { group.leave() }
            }
            group.notify(queue: .main) { [self] in
                try? FileManager.default.removeItem(at: cookiesURL)
                completion()
            }
        }
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
