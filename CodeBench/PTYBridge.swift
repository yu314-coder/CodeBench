import Foundation
import Darwin
import SwiftTerm
import GameController  // for GCKeyboard magic-keyboard detection

/// A pseudo-terminal (PTY) that bridges CPython's stdin/stdout/stderr
/// to a SwiftTerm TerminalView.
///
/// `openpty()` is available in the iOS libSystem without any entitlement
/// (only `fork`/`exec` are blocked in the app sandbox). We:
///   1. Create a PTY master/slave pair
///   2. dup2 the slave FD onto Python's stdin (0), stdout (1), stderr (2)
///   3. Spawn a background queue that `read()`s from the master FD and
///      feeds every byte into the SwiftTerm emulator, which renders it
///   4. Forward TerminalView input back into the master FD so stdin reads
///      in Python see the user's typed text
///   5. On TerminalView resize, fire TIOCSWINSZ so curses / textual /
///      rich's auto-width detection reflow
///
/// Once this is set up, `os.isatty(1)` returns True inside Python, which
/// is the signal pip/rich/tqdm/click/pytest all check to decide whether
/// to use interactive output vs buffered. They start "just working."
final class PTYBridge: NSObject, TerminalViewDelegate {

    static let shared = PTYBridge()

    /// PTY master FD — we read from here to get what Python wrote, and
    /// write to here to send user keystrokes back to Python's stdin.
    private(set) var masterFD: Int32 = -1

    /// PTY slave FD — dup2'd onto Python's 0/1/2. We keep a copy open
    /// so the PTY doesn't close when Python's file descriptors turn over.
    private var slaveFD: Int32 = -1

    /// Write end of the stdout pipe. With the pipe (not PTY) design on
    /// iOS, Python's sys.stdout gets redirected to this fd at the
    /// Python level (os.fdopen) instead of dup2'ing fd 1 process-wide —
    /// so Swift print() stays on Xcode console.
    private(set) var stdoutPipeWriteFD: Int32 = -1

    /// The terminal view we're rendering into. Weak — owned by the VC.
    weak var terminalView: TerminalView? {
        didSet {
            // Flush any bytes that arrived before the VC attached.
            flushPendingBytes()
        }
    }

    /// Optional callback fired for every chunk of bytes we feed into
    /// the terminal view. The VC uses this to keep its `terminalLogBuffer`
    /// in sync so the Copy / Export-log buttons still capture the full
    /// scrollback even though Python output now bypasses appendToTerminal.
    var onOutputBytes: (([UInt8]) -> Void)?

    /// Our background read source — pulls bytes off the master FD.
    private var readSource: DispatchSourceRead?

    /// Bytes that arrived from Python's stdout BEFORE terminalView was
    /// set. Without this buffer, the REPL's boot banner ("CodeBench shell
    /// — type help …") would vanish into the void.
    private var pendingBytes = [UInt8]()
    private let pendingLock = NSLock()

    private func flushPendingBytes() {
        pendingLock.lock()
        let bytes = pendingBytes
        pendingBytes.removeAll(keepingCapacity: false)
        pendingLock.unlock()
        guard !bytes.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.terminalView?.feed(byteArray: bytes[...])
            self.onOutputBytes?(bytes)
        }
    }

    /// Saved copies of the original stdin/stdout/stderr so tests can
    /// restore if they need to.
    private var savedStdin:  Int32 = -1
    private var savedStdout: Int32 = -1
    private var savedStderr: Int32 = -1

    /// Whether setup() has successfully run once. Guards against
    /// double-dup2 if called again.
    private(set) var isReady = false

    private override init() {
        super.init()
    }

    // MARK: - Setup

    /// Call this exactly once, typically from the app delegate, BEFORE
    /// any Python code that might write to stdout runs.
    ///
    /// iOS blocks `openpty()` (EPERM) for sandboxed apps. We use
    /// plain `pipe()` pairs instead:
    ///   • stdin pipe: user keystrokes → write-end → read-end = fd 0 in Python
    ///   • stdout pipe: Python writes → fd 1/2 = write-end → read-end → SwiftTerm
    /// We lose real TTY semantics (no kernel echo, no canonical mode,
    /// no termios) but keystrokes flow and `FORCE_COLOR=1` makes
    /// pip/rich/tqdm produce ANSI output anyway. Local echo is
    /// handled in `send(source:data:)` by feeding typed bytes back
    /// into the terminal view directly.
    func setupIfNeeded() {
        guard !isReady else { return }

        // stdin pipe: [0]=read end (dup2'd onto fd 0, Python reads),
        //             [1]=write end (we write keystrokes here).
        var stdinPipe: [Int32] = [-1, -1]
        // stdout pipe: [0]=read end (we read Python output),
        //              [1]=write end (dup2'd onto fd 1 & 2).
        var stdoutPipe: [Int32] = [-1, -1]

        guard Darwin.pipe(&stdinPipe) == 0 else {
            NSLog("[PTY] stdin pipe() failed: errno=\(errno)")
            return
        }
        guard Darwin.pipe(&stdoutPipe) == 0 else {
            NSLog("[PTY] stdout pipe() failed: errno=\(errno)")
            Darwin.close(stdinPipe[0]); Darwin.close(stdinPipe[1])
            return
        }

        // Save originals so we can restore them if ever needed.
        savedStdin  = dup(0)
        savedStdout = dup(1)
        savedStderr = dup(2)

        // Python stdin ← stdin-pipe read end (dup2'd onto fd 0 so
        // Python's sys.stdin naturally reads from our pipe).
        _ = dup2(stdinPipe[0], 0)
        Darwin.close(stdinPipe[0])

        // Python stdout / stderr: do NOT dup2 onto fd 1 / fd 2. Both
        // are shared with iOS and Swift:
        //   • fd 1 — Swift `print(...)` writes here. If hijacked,
        //     "[app] Returning to foreground" etc. bleed into the
        //     terminal.
        //   • fd 2 — iOS os_log / WebKit / notification subsystems
        //     flood this with OSLOG diagnostic messages.
        // Instead, keep the pipe write end alive here and let
        // PythonRuntime redirect sys.stdout / sys.stderr at the Python
        // level via os.fdopen(fd). Swift print() keeps its Xcode-
        // console destination; Python's output lands in the terminal.
        stdoutPipeWriteFD = stdoutPipe[1]

        // Set the stdout read end to non-blocking so our dispatch
        // source doesn't stall when Python is idle.
        _ = fcntl(stdoutPipe[0], F_SETFL,
                  fcntl(stdoutPipe[0], F_GETFL) | O_NONBLOCK)

        // fd 1 / fd 2 are NOT hijacked — Swift print / iOS os_log stay
        // on Xcode console. Python redirects sys.stdout/sys.stderr at
        // the Python level via stdoutPipeWriteFD (see PythonRuntime).

        // Public handles: masterFD keeps the name for historical
        // reasons — it's the stdin write end we push keystrokes into.
        masterFD = stdinPipe[1]
        // slaveFD now holds the stdout-pipe read end for the read loop.
        slaveFD = stdoutPipe[0]

        startReadLoop()

        isReady = true
        NSLog("[PTY] ready (pipes): stdin_w=\(stdinPipe[1]) stdout_r=\(stdoutPipe[0])")

        // Write one visible line through the stdout pipe's write end
        // directly (NOT fd 1 — that's Swift's print() territory and we
        // don't want to hijack it anymore).
        let banner = "\u{1b}[38;5;244m[terminal ready — type to Python]\u{1b}[0m\r\n"
        banner.withCString { cs in
            _ = Darwin.write(stdoutPipeWriteFD, cs, strlen(cs))
        }

        installMagicKeyboardObservers()
    }

    // MARK: - Magic keyboard detection

    private var magicKeyboardObserverInstalled = false
    private func installMagicKeyboardObservers() {
        guard !magicKeyboardObserverInstalled else { return }
        magicKeyboardObserverInstalled = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.logMagicKeyboard(state: "connected")
        }
        nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.logMagicKeyboard(state: "disconnected")
        }
        // Already-connected check on setup
        if GCKeyboard.coalesced != nil {
            logMagicKeyboard(state: "connected (already present)")
        }
    }

    private func logMagicKeyboard(state: String) {
        NSLog("[PTY] magic keyboard \(state)")
        let banner = "\u{1b}[38;5;244m[magic keyboard \(state)]\u{1b}[0m\r\n"
        DispatchQueue.main.async { [weak self] in
            self?.terminalView?.feed(text: banner)
        }
    }

    // MARK: - Read loop

    private func startReadLoop() {
        // With the pipe-based setup, the stdout-pipe READ end is in
        // `slaveFD` (name kept for backwards compat). This is what
        // Python's stdout/stderr writes land in.
        let readFD = slaveFD
        let queue = DispatchQueue(label: "offlinai.pty.reader", qos: .userInteractive)
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = buffer.withUnsafeMutableBufferPointer { bp in
                Darwin.read(readFD, bp.baseAddress, bp.count)
            }
            guard n > 0 else { return }
            let raw = Array(buffer[0..<n])

            // First pass: detect + strip our private OSC mode-switch
            // sequences. TUI apps (ncdu, vim, …) write
            //   "\x1b]offlinai;raw\x1b\\"    — enter raw input mode
            //   "\x1b]offlinai;cooked\x1b\\" — return to cooked mode
            // to tell LineBuffer to stop line-editing and forward each
            // keystroke directly. We strip them here so they never
            // reach SwiftTerm (which would show them as garbage chars).
            let rawModeMarker: [UInt8] = Array("\u{1B}]offlinai;raw\u{1B}\\".utf8)
            let cookedModeMarker: [UInt8] = Array("\u{1B}]offlinai;cooked\u{1B}\\".utf8)
            var modeStripped: [UInt8] = []
            modeStripped.reserveCapacity(raw.count)
            var i = 0
            while i < raw.count {
                if _indexOf(rawModeMarker, in: raw, at: i) {
                    DispatchQueue.main.async {
                        LineBuffer.shared.setRawMode(true)
                    }
                    i += rawModeMarker.count
                    continue
                }
                if _indexOf(cookedModeMarker, in: raw, at: i) {
                    DispatchQueue.main.async {
                        LineBuffer.shared.setRawMode(false)
                    }
                    i += cookedModeMarker.count
                    continue
                }
                modeStripped.append(raw[i])
                i += 1
            }

            // ONLCR emulation: a real PTY's termios layer translates
            // bare LF to CRLF on output so a newline both advances the
            // cursor AND returns it to column 0. Our pipe has no termios,
            // so Python's `\n` arrives here as plain 0x0A and SwiftTerm
            // interprets it as "cursor down, same column" — producing
            // prompts stair-stepped to the right of the previous line's
            // content. Convert every lone LF to CRLF here. Existing CRs
            // (CRLF sequences) are preserved untouched.
            var cooked: [UInt8] = []
            cooked.reserveCapacity(modeStripped.count + 16)
            var j = 0
            while j < modeStripped.count {
                let b = modeStripped[j]
                if b == 0x0A {
                    let prev = j > 0 ? modeStripped[j - 1] : (cooked.last ?? 0)
                    if prev != 0x0D {
                        cooked.append(0x0D)
                    }
                    cooked.append(0x0A)
                } else {
                    cooked.append(b)
                }
                j += 1
            }
            let slice = cooked

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let tv = self.terminalView {
                    tv.feed(byteArray: slice[...])
                } else {
                    // terminalView not attached yet — buffer for later
                    self.pendingLock.lock()
                    self.pendingBytes.append(contentsOf: slice)
                    self.pendingLock.unlock()
                }
                // Notify the VC so it can mirror into its scrollback
                // buffer (Copy / Export-log depend on this).
                self.onOutputBytes?(slice)
            }
        }

        source.resume()
        readSource = source
    }

    /// Return true iff `haystack[at...]` starts with `needle`. Used by
    /// the read loop to detect OSC mode-switch markers (raw / cooked).
    private func _indexOf(_ needle: [UInt8], in haystack: [UInt8], at: Int) -> Bool {
        guard at + needle.count <= haystack.count else { return false }
        for k in 0..<needle.count {
            if haystack[at + k] != needle[k] { return false }
        }
        return true
    }

    // MARK: - Env vars for pretty output

    /// Called before Py_Initialize so pip, rich, tqdm, click see the
    /// right tty-flavored environment and produce interactive output.
    static func exportTTYEnv(cols: Int = 80, rows: Int = 24) {
        setenv("TERM",              "xterm-256color", 1)
        setenv("COLORTERM",         "truecolor",       1)
        setenv("FORCE_COLOR",       "1",               1)
        setenv("CLICOLOR",          "1",               1)
        setenv("CLICOLOR_FORCE",    "1",               1)
        setenv("PYTHONUNBUFFERED",  "1",               1)
        setenv("PYTHONIOENCODING",  "utf-8",           1)
        setenv("COLUMNS",           String(cols),      1)
        setenv("LINES",             String(rows),      1)
        // Hint to pip and friends to not buffer
        setenv("PIP_NO_COLOR",      "0",               1)   // let rich color
        setenv("PAGER",             "cat",             1)   // `pip help` shouldn't page
    }

    // MARK: - Resize forwarding

    /// Forward the current TerminalView's columns/rows to the PTY so
    /// curses-like libraries reflow. Call from the TerminalViewDelegate
    /// `sizeChanged` hook.
    func updateWindowSize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var ws = winsize()
        ws.ws_col = cols
        ws.ws_row = rows
        ws.ws_xpixel = 0
        ws.ws_ypixel = 0
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &ws)
        setenv("COLUMNS", String(cols), 1)
        setenv("LINES",   String(rows), 1)
    }

    // MARK: - Writing to Python's stdin

    /// Push a byte array into the PTY master — appears to Python as if
    /// typed on stdin. Used by the TerminalView delegate for keystrokes.
    func send(data: [UInt8]) {
        if data.isEmpty { return }
        // On-demand PTY setup: if somehow we got a keystroke before
        // setupIfNeeded ran (app launch timing, terminal view attached
        // super early, etc.), open the PTY right now and retry. This
        // means the very first key the user taps always lands — no
        // more "send dropped: masterFD=-1" after the fix + rebuild.
        if masterFD < 0 {
            NSLog("[PTY] send before setup — calling setupIfNeeded now")
            setupIfNeeded()
            if masterFD < 0 {
                NSLog("[PTY] setupIfNeeded failed; dropping \(data.count) bytes")
                return
            }
        }
        let preview = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        NSLog("[PTY] → master(\(masterFD)): \(data.count) bytes: \(preview)")
        data.withUnsafeBufferPointer { bp in
            let n = Darwin.write(masterFD, bp.baseAddress, bp.count)
            if n < 0 {
                NSLog("[PTY] write failed: errno=\(errno)")
            } else if n != data.count {
                NSLog("[PTY] partial write: \(n) of \(data.count) bytes")
            }
        }
    }

    func send(text: String) {
        send(data: Array(text.utf8))
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // All line editing is done locally in Swift (see LineBuffer
        // below). This mirrors how a real PTY's kernel line discipline
        // works: the kernel handles char-by-char echoing, cursor
        // movement, backspace, history etc., and only delivers
        // COMPLETE LINES to the application when the user presses
        // Enter.
        //
        // Benefits over Python-side editing:
        //  • Works before Python has initialized (cold-launch typing).
        //  • No pipe round-trip per keystroke — instant echo.
        //  • Swift has direct access to the TerminalView so cursor
        //    math is simple and synchronous.
        //
        // When the user presses Enter, LineBuffer writes the full line
        // (plus \n) into our stdin pipe so Python reads it like a
        // normal line-mode stdin.
        LineBuffer.shared.handle(bytes: data, terminalView: source,
                                 pipeWrite: { [weak self] bytes in
            self?.send(data: bytes)
        })
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        updateWindowSize(cols: UInt16(newCols), rows: UInt16(newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // TerminalView sets this via the OSC 0 escape; the hosting VC can
        // observe if it wants to update the title bar, but we don't need
        // anything here by default.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Optional hook for cwd-aware UI.
    }

    func scrolled(source: TerminalView, position: Double) {
        // no-op
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        // no-op
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // SwiftTerm auto-detects anything path-shaped as a link (including
        // TeX's "(./beamer.cls" style stdout). Only hand http(s) URLs to
        // UIApplication — everything else just causes LaunchServices
        // error -50 "invalid input parameters" noise in the console.
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }

    func bell(source: TerminalView) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(data: content, encoding: .utf8)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        // iTerm2 proprietary escapes — ignore
    }
}


// MARK: - LineBuffer (Swift-side "cooked" line discipline)
//
// Replaces a kernel PTY's ICANON / ECHO line-editing. Takes raw bytes
// from SwiftTerm (arrow keys, control chars, printable text), maintains
// an internal line buffer + cursor position + history, echoes edits
// back to the TerminalView immediately, and only pushes a complete
// line into Python's stdin pipe when the user presses Enter.
//
// All operations happen on the main actor: the TerminalViewDelegate
// callback is main-thread and LineBuffer methods are only called from
// there.

final class LineBuffer {

    static let shared = LineBuffer()

    /// The current typed-line bytes (UTF-8).
    private var buf: [UInt8] = []
    /// Cursor byte offset within `buf`.
    private var cursor: Int = 0
    /// Command history, newest last.
    private var history: [String] = []
    /// Index into history when navigating with ↑ / ↓. Equal to
    /// history.count when not navigating.
    private var histIdx: Int = 0
    /// Saved partial line when the user starts history navigation.
    private var savedPartial: [UInt8] = []
    /// Partial CSI / SS3 escape sequence being accumulated from input.
    private var escBuf: [UInt8] = []
    /// Escape-sequence state machine: .idle, .esc (just saw ESC),
    /// .csi (saw ESC [), .ss3 (saw ESC O).
    private enum EscState { case idle, esc, csi, ss3 }
    private var escState: EscState = .idle

    /// When raw mode is on, every byte from the TerminalView is
    /// forwarded straight to Python's stdin with NO line editing,
    /// NO echo, NO history navigation. This is what ncurses TUI
    /// apps (ncdu, vim, htop, …) need so they can handle keypresses
    /// byte-by-byte themselves.
    ///
    /// Python switches the mode by writing our private OSC sequence:
    ///   "\x1b]offlinai;raw\x1b\\"     — enter raw mode
    ///   "\x1b]offlinai;cooked\x1b\\"  — return to cooked (line-buffered)
    /// The PTYBridge read loop detects these in outgoing bytes, strips
    /// them before feeding SwiftTerm, and calls `setRawMode`.
    private var _isRawMode = false

    func setRawMode(_ raw: Bool) {
        _isRawMode = raw
        if raw {
            // Discard any in-progress cooked-mode line so we don't
            // accidentally commit it when the app exits.
            buf.removeAll(keepingCapacity: false)
            cursor = 0
            histIdx = history.count
            escState = .idle
            escBuf.removeAll(keepingCapacity: false)
        }
        NSLog("[LineBuffer] raw mode → \(raw)")
    }

    var isRawMode: Bool { _isRawMode }

    private init() {}

    // MARK: - Public entry point

    /// Process a batch of bytes from SwiftTerm. Handles every key /
    /// escape sequence we care about, calls `pipeWrite(line+\n)` once
    /// per Enter press.
    func handle(bytes: ArraySlice<UInt8>,
                terminalView: TerminalView,
                pipeWrite: @escaping ([UInt8]) -> Void) {
        if _isRawMode {
            // TUI mode: forward every byte straight to Python with no
            // echo and no line editing. The TUI app (ncdu, vim, …)
            // handles each byte itself.
            pipeWrite(Array(bytes))
            return
        }
        for b in bytes {
            processByte(b, terminalView: terminalView, pipeWrite: pipeWrite)
        }
    }

    // MARK: - Echo helpers

    private func echo(_ bytes: [UInt8], _ terminalView: TerminalView) {
        if bytes.isEmpty { return }
        terminalView.feed(byteArray: ArraySlice(bytes))
    }

    private func echo(_ s: String, _ terminalView: TerminalView) {
        echo(Array(s.utf8), terminalView)
    }

    // MARK: - Byte dispatcher

    private func processByte(_ b: UInt8,
                             terminalView tv: TerminalView,
                             pipeWrite: @escaping ([UInt8]) -> Void) {
        // Escape-sequence state machine
        switch escState {
        case .esc:
            if b == 0x5B /* [ */ {
                escState = .csi
                escBuf.removeAll(keepingCapacity: true)
                return
            }
            if b == 0x4F /* O */ {
                escState = .ss3
                return
            }
            // Unknown ESC-prefixed byte; drop both.
            escState = .idle
            return

        case .csi:
            // CSI: ESC [ <params> <final-byte in 0x40..0x7E>
            if b >= 0x40 && b <= 0x7E {
                handleCSI(final: b, params: escBuf, terminalView: tv)
                escBuf.removeAll(keepingCapacity: true)
                escState = .idle
                return
            }
            escBuf.append(b)
            if escBuf.count > 16 { escState = .idle; escBuf.removeAll() }
            return

        case .ss3:
            handleSS3(b, terminalView: tv)
            escState = .idle
            return

        case .idle:
            break
        }

        // Regular byte handling
        switch b {
        case 0x1B: // ESC
            escState = .esc
        case 0x0D, 0x0A: // Enter (CR or LF)
            commitLine(terminalView: tv, pipeWrite: pipeWrite)
        case 0x7F, 0x08: // Backspace / BS
            backspace(terminalView: tv)
        case 0x03: // Ctrl-C
            // Two paths for interrupt — which one matters depends on
            // whether Python is reading stdin or executing code:
            //   1) If the REPL is blocked in os.read(0, …), the REPL
            //      will see the 0x03 byte and raise KeyboardInterrupt
            //      inside its own frame.
            //   2) If the user script is running (e.g. `while True:`),
            //      the REPL is NOT reading stdin — bytes pile up in the
            //      pipe. We need PyErr_SetInterrupt() which asynchronously
            //      raises KeyboardInterrupt in the Python main thread at
            //      the next bytecode boundary.
            echo([0x5e, 0x43, 0x0d, 0x0a], tv) // "^C\r\n"
            buf.removeAll(keepingCapacity: true)
            cursor = 0
            histIdx = history.count
            pipeWrite([0x03])
            PythonRuntime.shared.interruptPythonMainThread()
        case 0x04: // Ctrl-D — EOF if buffer empty, else forward-delete
            if buf.isEmpty {
                pipeWrite([0x04])
            } else {
                deleteForward(terminalView: tv)
            }
        case 0x01: // Ctrl-A — home
            moveHome(terminalView: tv)
        case 0x05: // Ctrl-E — end
            moveEnd(terminalView: tv)
        case 0x15: // Ctrl-U — clear line
            clearLine(terminalView: tv)
        case 0x0B: // Ctrl-K — clear to end
            clearToEnd(terminalView: tv)
        case 0x17: // Ctrl-W — kill word
            killWord(terminalView: tv)
        case 0x0C: // Ctrl-L — clear screen
            echo([0x1B, 0x5B, 0x32, 0x4A, 0x1B, 0x5B, 0x48], tv) // ESC[2J ESC[H
        case 0x09: // Tab — complete command or filename
            handleTab(terminalView: tv)
        default:
            if b >= 0x20 || b >= 0x80 {
                // Printable ASCII or UTF-8 continuation / lead byte
                insert([b], terminalView: tv)
            }
            // other control bytes: ignore
        }
    }

    // MARK: - CSI / SS3 dispatch (arrow keys, home, end, delete)

    private func handleCSI(final: UInt8, params: [UInt8], terminalView tv: TerminalView) {
        let p = String(bytes: params, encoding: .ascii) ?? ""
        switch final {
        case 0x41: historyPrev(terminalView: tv)    // A — up
        case 0x42: historyNext(terminalView: tv)    // B — down
        case 0x43: moveRight(terminalView: tv)      // C — right
        case 0x44: moveLeft(terminalView: tv)       // D — left
        case 0x48: moveHome(terminalView: tv)       // H — home
        case 0x46: moveEnd(terminalView: tv)        // F — end
        case 0x7E: // ~ — parameterized
            switch p {
            case "1", "7": moveHome(terminalView: tv)
            case "4", "8": moveEnd(terminalView: tv)
            case "3":      deleteForward(terminalView: tv)
            default: break
            }
        default: break
        }
    }

    private func handleSS3(_ b: UInt8, terminalView tv: TerminalView) {
        switch b {
        case 0x41: historyPrev(terminalView: tv)
        case 0x42: historyNext(terminalView: tv)
        case 0x43: moveRight(terminalView: tv)
        case 0x44: moveLeft(terminalView: tv)
        case 0x48: moveHome(terminalView: tv)
        case 0x46: moveEnd(terminalView: tv)
        default: break
        }
    }

    // MARK: - Editing primitives

    private func insert(_ data: [UInt8], terminalView tv: TerminalView) {
        buf.insert(contentsOf: data, at: cursor)
        cursor += data.count
        // Redraw: print inserted bytes + the tail, then move cursor
        // back to its logical position.
        let tail = Array(buf[cursor...])
        echo(data + tail, tv)
        if !tail.isEmpty {
            echo("\u{1B}[\(tail.count)D", tv)
        }
    }

    private func backspace(terminalView tv: TerminalView) {
        guard cursor > 0 else { return }
        // Step back one UTF-8 code point.
        var i = cursor - 1
        while i > 0 && (buf[i] & 0xC0) == 0x80 { i -= 1 }
        let removed = cursor - i
        buf.removeSubrange(i..<cursor)
        cursor = i
        // Move back `removed` columns, reprint tail, clear EOL, move back.
        echo(String(repeating: "\u{08}", count: removed), tv)
        redrawTail(terminalView: tv)
    }

    private func deleteForward(terminalView tv: TerminalView) {
        guard cursor < buf.count else { return }
        var j = cursor + 1
        while j < buf.count && (buf[j] & 0xC0) == 0x80 { j += 1 }
        buf.removeSubrange(cursor..<j)
        redrawTail(terminalView: tv)
    }

    private func moveLeft(terminalView tv: TerminalView) {
        guard cursor > 0 else { return }
        var i = cursor - 1
        while i > 0 && (buf[i] & 0xC0) == 0x80 { i -= 1 }
        let moved = cursor - i
        cursor = i
        echo("\u{1B}[\(moved)D", tv)
    }

    private func moveRight(terminalView tv: TerminalView) {
        guard cursor < buf.count else { return }
        var j = cursor + 1
        while j < buf.count && (buf[j] & 0xC0) == 0x80 { j += 1 }
        let moved = j - cursor
        cursor = j
        echo("\u{1B}[\(moved)C", tv)
    }

    private func moveHome(terminalView tv: TerminalView) {
        if cursor > 0 {
            echo("\u{1B}[\(cursor)D", tv)
            cursor = 0
        }
    }

    private func moveEnd(terminalView tv: TerminalView) {
        if cursor < buf.count {
            let delta = buf.count - cursor
            echo("\u{1B}[\(delta)C", tv)
            cursor = buf.count
        }
    }

    private func clearLine(terminalView tv: TerminalView) {
        if cursor > 0 { echo("\u{1B}[\(cursor)D", tv) }
        echo("\u{1B}[K", tv)
        buf.removeAll(keepingCapacity: true)
        cursor = 0
    }

    private func clearToEnd(terminalView tv: TerminalView) {
        if cursor < buf.count {
            buf.removeSubrange(cursor..<buf.count)
            echo("\u{1B}[K", tv)
        }
    }

    private func killWord(terminalView tv: TerminalView) {
        guard cursor > 0 else { return }
        var i = cursor
        while i > 0 && buf[i - 1] == 0x20 { i -= 1 }
        while i > 0 && buf[i - 1] != 0x20 { i -= 1 }
        let removed = cursor - i
        buf.removeSubrange(i..<cursor)
        cursor = i
        echo("\u{1B}[\(removed)D", tv)
        redrawTail(terminalView: tv)
    }

    private func redrawTail(terminalView tv: TerminalView) {
        let tail = Array(buf[cursor...])
        echo(tail, tv)
        echo([0x1B, 0x5B, 0x4B], tv) // ESC [ K — clear to EOL
        if !tail.isEmpty {
            echo("\u{1B}[\(tail.count)D", tv)
        }
    }

    // MARK: - History

    private func historyPrev(terminalView tv: TerminalView) {
        guard !history.isEmpty, histIdx > 0 else { return }
        if histIdx == history.count {
            savedPartial = buf
        }
        histIdx -= 1
        replaceLine(with: Array(history[histIdx].utf8), terminalView: tv)
    }

    private func historyNext(terminalView tv: TerminalView) {
        guard histIdx < history.count else { return }
        histIdx += 1
        if histIdx == history.count {
            replaceLine(with: savedPartial, terminalView: tv)
        } else {
            replaceLine(with: Array(history[histIdx].utf8), terminalView: tv)
        }
    }

    private func replaceLine(with new: [UInt8], terminalView tv: TerminalView) {
        if cursor > 0 { echo("\u{1B}[\(cursor)D", tv) }
        echo("\u{1B}[K", tv)
        buf = new
        cursor = new.count
        echo(new, tv)
    }

    // MARK: - Tab completion

    /// Builtins defined by offlinai_shell.py — used for first-word
    /// completion. Keep this list in sync with BUILTINS in that file.
    private static let builtins: [String] = [
        // Shell essentials
        "cat", "cd", "clear", "cp", "date", "echo", "env", "exit",
        "export", "find", "grep", "head", "help", "history", "ll", "la",
        "ls", "man", "mkdir", "mv", "pwd", "quit", "rm", "rmdir",
        "tail", "touch", "tree", "uptime", "wc", "which",
        // Disk-usage family
        "du", "df", "ncdu", "stat",
        // System monitoring
        "top", "htop",
        // Source control (iOS-compat subset)
        "git",
        // Language runners
        "python", "python3",
        "cc", "gcc", "clang",
        "c++", "g++", "clang++",
        "gfortran", "f77", "f90", "f95",
        // LaTeX compilers
        "pdflatex", "latex", "tex", "pdftex", "xelatex",
        "latex-diagnose",
        // Package manager
        "pip", "pip3",
        "pip-install", "pip-uninstall", "pip-list",
        "pip-show", "pip-freeze", "pip-check",
    ]

    private func handleTab(terminalView tv: TerminalView) {
        // Find the word before cursor.
        let prefixBytes = Array(buf[0..<cursor])
        guard let prefixStr = String(bytes: prefixBytes, encoding: .utf8) else { return }

        // Word boundary: last whitespace before cursor.
        let wordStart = prefixStr.lastIndex(where: { $0 == " " || $0 == "\t" })
            .map { prefixStr.index(after: $0) } ?? prefixStr.startIndex
        let partial = String(prefixStr[wordStart...])

        // Is this the first word on the line? → command completion.
        // Otherwise → filesystem path completion.
        let isFirstWord = !prefixStr.contains(where: { $0 == " " || $0 == "\t" })
        // For file-extension-aware commands (pdflatex foo.tex, python
        // bar.py etc.) filter the path completions to the extensions
        // that command actually consumes — noise-reducing and matches
        // bash-completion behavior.
        let firstToken = prefixStr
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first.map(String.init) ?? ""
        let extFilter: Set<String>? = Self.extensionsForCommand(firstToken)
        let candidates: [String] = isFirstWord
            ? completeCommand(partial: partial)
            : completePath(partial: partial, extensions: extFilter)

        guard !candidates.isEmpty else { return }

        if candidates.count == 1 {
            // Unambiguous — complete the whole match, then add a
            // trailing space (for commands) or '/' (for dirs).
            let full = candidates[0]
            finishCompletion(partial: partial, full: full,
                             appendSpace: isFirstWord && !full.hasSuffix("/"),
                             terminalView: tv)
        } else {
            // Find longest common prefix — if it extends `partial`,
            // insert up to it. (Avoids noisy multi-match display; zsh
            // and bash both do this on single tab.)
            let common = longestCommonPrefix(candidates)
            if common.count > partial.count {
                finishCompletion(partial: partial, full: common,
                                 appendSpace: false, terminalView: tv)
            }
            // Otherwise already at branching point — do nothing;
            // user can press Ctrl-L to clear or keep typing.
        }
    }

    private func completeCommand(partial: String) -> [String] {
        LineBuffer.builtins.filter { $0.hasPrefix(partial) }.sorted()
    }

    /// Extensions that `command` consumes as its primary argument.
    /// Used by tab-completion to filter irrelevant files — e.g.
    /// `pdflatex <TAB>` should show `.tex` / `.ltx` files, not every
    /// `.py` and `.md` in the directory. nil → no filter (show all).
    private static func extensionsForCommand(_ command: String) -> Set<String>? {
        switch command {
        case "pdflatex", "latex", "tex", "pdftex", "xelatex", "lualatex":
            return ["tex", "ltx"]
        case "python", "python3":
            return ["py"]
        case "bibtex", "biber":
            return ["aux", "bib", "bcf"]
        case "dvipdf", "dvipdfm", "dvipdfmx":
            return ["dvi"]
        case "pdftotext", "pdfinfo":
            return ["pdf"]
        case "git":
            return nil  // git has its own subcommand dispatch
        default:
            return nil
        }
    }

    private func completePath(partial: String,
                              extensions: Set<String>? = nil) -> [String] {
        let fm = FileManager.default

        // Split partial into directory portion + filename prefix.
        var dirPath: String
        var namePrefix: String
        // Expand leading ~ to HOME.
        var expanded = partial
        if expanded == "~" || expanded.hasPrefix("~/") {
            let home = NSHomeDirectory()
            expanded = expanded == "~"
                ? home
                : home + expanded.dropFirst(1)
        }

        if let slashRange = expanded.range(of: "/", options: .backwards) {
            dirPath = String(expanded[..<slashRange.upperBound])
            namePrefix = String(expanded[slashRange.upperBound...])
        } else {
            dirPath = fm.currentDirectoryPath
            if !dirPath.hasSuffix("/") { dirPath += "/" }
            namePrefix = expanded
        }

        let listDir = dirPath.hasSuffix("/") ? String(dirPath.dropLast()) : dirPath
        guard let entries = try? fm.contentsOfDirectory(atPath: listDir) else {
            return []
        }

        // Skip dotfiles unless user typed a dot themselves.
        let includeHidden = namePrefix.hasPrefix(".")
        var filtered = entries
            .filter { $0.hasPrefix(namePrefix) }
            .filter { includeHidden || !$0.hasPrefix(".") }
            .sorted()
        // If caller restricts to certain extensions (e.g. `pdflatex
        // <TAB>` → .tex only), keep only matching files AND dirs
        // (dirs still useful for navigation).
        if let exts = extensions {
            filtered = filtered.filter { name in
                let fullPath = listDir + "/" + name
                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: fullPath,
                                           isDirectory: &isDir)
                if exists && isDir.boolValue { return true }
                return exts.contains(
                    (name as NSString).pathExtension.lowercased())
            }
        }

        // Rebuild full path with trailing / for directories. Preserve
        // the user's original dir-portion (with ~ etc.) so we don't
        // swap in the absolute path on them.
        let dirPrefix: String
        if let slashRange = partial.range(of: "/", options: .backwards) {
            dirPrefix = String(partial[..<slashRange.upperBound])
        } else {
            dirPrefix = ""
        }

        return filtered.map { name in
            var full = dirPrefix + name
            var isDir: ObjCBool = false
            let checkPath = listDir + "/" + name
            if fm.fileExists(atPath: checkPath, isDirectory: &isDir), isDir.boolValue {
                full += "/"
            }
            return full
        }
    }

    private func longestCommonPrefix(_ strs: [String]) -> String {
        guard let first = strs.first else { return "" }
        var prefix = first
        for s in strs.dropFirst() {
            while !s.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }

    private func finishCompletion(partial: String, full: String,
                                  appendSpace: Bool,
                                  terminalView tv: TerminalView) {
        guard full.count >= partial.count else { return }
        let rest = String(full.dropFirst(partial.count))
        var insertion = Array(rest.utf8)
        if appendSpace {
            insertion.append(0x20) // space
        }
        if !insertion.isEmpty {
            insert(insertion, terminalView: tv)
        }
    }

    // MARK: - Commit

    private func commitLine(terminalView tv: TerminalView,
                            pipeWrite: @escaping ([UInt8]) -> Void) {
        // Visual newline
        echo([0x0D, 0x0A], tv)
        // Send to Python (include trailing \n so repl() sees a line).
        var out = buf
        out.append(0x0A)
        pipeWrite(out)
        // Add to history if non-empty and different from last.
        if let s = String(bytes: buf, encoding: .utf8), !s.trimmingCharacters(in: .whitespaces).isEmpty {
            if history.last != s {
                history.append(s)
                if history.count > 500 { history.removeFirst() }
            }
        }
        buf.removeAll(keepingCapacity: true)
        cursor = 0
        histIdx = history.count
        savedPartial.removeAll()
    }
}
