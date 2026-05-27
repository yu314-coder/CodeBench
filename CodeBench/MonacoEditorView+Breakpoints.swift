//
//  MonacoEditorView+Breakpoints.swift
//  CodeBench
//
//  Persists per-file breakpoint sets to disk (~/.codebench/breakpoints/)
//  and bridges them to the Monaco JS side so the glyph-margin dots
//  appear immediately when a file is opened.
//
//  Storage format: one line per breakpoint, decimal line numbers, no
//  trailing newline. Matches what the Python `debug` builtin reads in
//  `offlinai_shell._debug`.
//
//  Extracted from MonacoEditorView.swift as part of the Tier-2 audit
//  refactor (split 10k-line files into focused extensions). The
//  stored property `currentScriptPath` lives in the class body —
//  Swift disallows stored properties in extensions.
//

import Foundation
import WebKit

extension MonacoEditorView {

    // MARK: - File-system layout

    /// Path used by the Python `debug` builtin to load saved breakpoints.
    /// Must match `bp_dir` in offlinai_shell.py `_debug`.
    fileprivate var breakpointStoreDir: URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.deletingLastPathComponent()
            .appendingPathComponent(".codebench", isDirectory: true)
            .appendingPathComponent("breakpoints", isDirectory: true)
    }

    /// Maps a file path to its breakpoint store filename — same
    /// transform as the Python side (replace / with _, strip leading _).
    fileprivate func breakpointFile(for scriptPath: String) -> URL {
        var name = scriptPath.replacingOccurrences(of: "/", with: "_")
        while name.hasPrefix("_") { name = String(name.dropFirst()) }
        return breakpointStoreDir.appendingPathComponent("\(name).bps")
    }

    // MARK: - JS bridge

    /// Called from the WKScriptMessageHandler switch when the user
    /// taps Monaco's glyph margin. Toggles the line in the persisted
    /// set and pushes the new set back to JS so the gutter dot
    /// appears/disappears.
    func toggleBreakpoint(line: Int) {
        guard let path = currentScriptPath else { return }
        var lines = loadBreakpoints(for: path)
        if lines.contains(line) {
            lines.removeAll { $0 == line }
        } else {
            lines.append(line)
            lines.sort()
        }
        saveBreakpoints(lines, for: path)
        pushBreakpointsToJS(lines)
    }

    /// Called by CodeEditorViewController right after `loadFile` — paints
    /// the saved breakpoints for the newly-opened script into the gutter.
    func refreshBreakpointsForCurrentFile() {
        guard let path = currentScriptPath else {
            pushBreakpointsToJS([]); return
        }
        let lines = loadBreakpoints(for: path)
        pushBreakpointsToJS(lines)
    }

    // MARK: - Persistence

    fileprivate func loadBreakpoints(for path: String) -> [Int] {
        let url = breakpointFile(for: path)
        guard let txt = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return txt.split(separator: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    fileprivate func saveBreakpoints(_ lines: [Int], for path: String) {
        let dir = breakpointStoreDir
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = breakpointFile(for: path)
        let txt = lines.map(String.init).joined(separator: "\n")
        try? txt.write(to: url, atomically: true, encoding: .utf8)
    }

    fileprivate func pushBreakpointsToJS(_ lines: [Int]) {
        let arr = "[" + lines.map(String.init).joined(separator: ",") + "]"
        webView.evaluateJavaScript("window.__editor.setBreakpoints(\(arr))")
    }
}
