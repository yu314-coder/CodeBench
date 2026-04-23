import Foundation
import Darwin  // POSIX open/write/close for atomic appends to the token stream

/// Bridge that lets the Python shell's `ai` builtin talk to the
/// Swift-side `LlamaRunner`. Protocol is the same signal-file pattern
/// `offlinai_latex` uses: Python drops a request JSON in
/// `$TMPDIR/latex_signals/`, a timer here picks it up, runs the LLM,
/// streams tokens to a response file Python tails, and writes a
/// done-marker when finished.
///
/// Signal files:
///   ai_request.json      — Python writes, Swift reads + removes
///   ai_response.stream   — Swift appends tokens, Python tails
///   ai_done.txt          — Swift writes "<status>\n<msg>\n" on completion
///
/// Request JSON shape (all fields optional except `messages`):
///   { "messages": [{"role":"system"|"user"|"assistant", "content":"..."}, ...],
///     "max_tokens": 2048,
///     "stop": ["\n```\n"] }
///
/// `AIEngine.shared.runner` must be wired up by GameViewController once
/// its `LlamaRunner()` instance is created. If a request arrives before
/// a model is loaded, we write a friendly error to ai_done.txt and the
/// Python CLI surfaces it.
@objc final class AIEngine: NSObject {

    static let shared = AIEngine()

    /// Held weakly — AIEngine doesn't own the runner. Set by
    /// GameViewController once the LlamaRunner is created.
    weak var runner: LlamaRunner?

    private var signalTimer: Timer?
    private var inFlight = false

    private var signalDir: String { NSTemporaryDirectory().appending("latex_signals/") }

    override private init() { super.init() }

    @MainActor
    func start() {
        guard signalTimer == nil else { return }
        try? FileManager.default.createDirectory(atPath: signalDir, withIntermediateDirectories: true)
        signalTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard !inFlight else { return }
        let reqPath = signalDir + "ai_request.json"
        guard FileManager.default.fileExists(atPath: reqPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: reqPath)) else { return }
        try? FileManager.default.removeItem(atPath: reqPath)

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMessages = obj["messages"] as? [[String: Any]] else {
            writeDone(status: -1, message: "ai: malformed request.json")
            return
        }
        let maxTokens = (obj["max_tokens"] as? Int) ?? 2048
        let stop = (obj["stop"] as? [String]) ?? []

        // Truncate the stream file so Python's tail starts fresh.
        let streamPath = signalDir + "ai_response.stream"
        FileManager.default.createFile(atPath: streamPath, contents: nil)

        guard let runner = runner else {
            writeDone(status: -2, message: "ai: no model loaded. Load one from the Models tab first.")
            return
        }

        let messages: [ChatMessage] = rawMessages.compactMap { m in
            guard let roleStr = m["role"] as? String,
                  let content = m["content"] as? String else { return nil }
            let role: ChatMessage.Role = {
                switch roleStr {
                case "system": return .system
                case "assistant": return .assistant
                default: return .user
                }
            }()
            return ChatMessage(role: role, content: content)
        }
        guard !messages.isEmpty else {
            writeDone(status: -1, message: "ai: empty messages[]")
            return
        }

        inFlight = true
        runner.generate(
            messages: messages,
            maxTokens: maxTokens,
            grammar: nil,
            stopSequences: stop,
            onToken: { [weak self] token in
                self?.appendTokenToStream(token)
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight = false
                    switch result {
                    case .success:
                        self.writeDone(status: 0, message: "ok")
                    case .failure(let err):
                        self.writeDone(status: -3, message: "ai: \(err.localizedDescription)")
                    }
                }
            })
    }

    private func appendTokenToStream(_ token: String) {
        let path = signalDir + "ai_response.stream"
        let fd = path.withCString { cpath in
            Darwin.open(cpath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        guard fd >= 0 else { return }
        token.withCString { cstr in
            _ = Darwin.write(fd, cstr, strlen(cstr))
        }
        Darwin.close(fd)
    }

    private func writeDone(status: Int, message: String) {
        let path = signalDir + "ai_done.txt"
        let text = "\(status)\n\(message)\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
