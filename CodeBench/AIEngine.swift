import Foundation
import Darwin  // POSIX open/write/close for atomic appends to the token stream
import llama   // GGML_TYPE_F16 and other ggml constants

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
            self?.pollLoadModel()
        }
        autoLoadLastModel()
    }

    /// Handle `ai_load_model.json` — writes the chosen GGUF path,
    /// tells `LlamaRunner` to load it, and publishes the active
    /// model name/path to `current_model.txt` (which the CLI's
    /// `/model` command reads) once loaded.
    ///
    /// Request JSON: {"path": "/abs/path/to.gguf"}
    /// Response file: `ai_model_done.txt` — "<status>\n<message>\n"
    private func pollLoadModel() {
        let reqPath = signalDir + "ai_load_model.json"
        guard FileManager.default.fileExists(atPath: reqPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: reqPath)) else { return }
        try? FileManager.default.removeItem(atPath: reqPath)

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["path"] as? String, !path.isEmpty else {
            writeModelDone(status: -1, message: "ai-load: malformed request.json")
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            writeModelDone(status: -1, message: "ai-load: no such file: \(path)")
            return
        }
        guard let runner = runner else {
            writeModelDone(status: -2, message: "ai-load: no LlamaRunner available")
            return
        }

        let url = URL(fileURLWithPath: path)
        // Sensible defaults — same shape as GameViewController's
        // loadModel(for slot:) but neutral for "whatever model the
        // user pulled from CLI". Users who want non-default sampling
        // can override with future /config <key>=<value> commands.
        let config = LlamaRunner.Config(
            contextSize: 4096,
            batchSize: 512,
            gpuLayers: 999,
            offloadKQV: true,
            opOffload: true,
            kvUnified: false,
            typeK: GGML_TYPE_F16,
            typeV: GGML_TYPE_F16,
            temperature: 0.7,
            topP: 0.9,
            topK: 50,
            repeatLastN: 64,
            repeatPenalty: 1.10,
            frequencyPenalty: 0.0,
            presencePenalty: 0.0)

        runner.loadModel(at: url, config: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.publishCurrentModel(path: path)
                    // Remember this model so the next app launch can
                    // auto-reload it without the user re-running
                    // `ai run <name>`. UserDefaults is written
                    // immediately — no need to wait for the next
                    // background-save cycle.
                    UserDefaults.standard.set(path, forKey: Self.lastModelDefaultsKey)
                    self.writeModelDone(status: 0, message: "loaded: \(url.lastPathComponent)")
                case .failure(let err):
                    self.writeModelDone(status: -3, message: "ai-load: \(err.localizedDescription)")
                }
            }
        }
    }

    /// UserDefaults key for the last successfully-loaded GGUF path.
    /// Read on AIEngine.start() for auto-reload, written on every
    /// successful loadModel completion.
    private static let lastModelDefaultsKey = "ai.last.model.path"

    /// Kick off a background load of whichever model was active last
    /// time the app ran. Called from `start()` — blocks nothing, just
    /// schedules the load so by the time the user types `ai` the
    /// model is (likely) already warm.
    private func autoLoadLastModel() {
        guard let path = UserDefaults.standard.string(forKey: Self.lastModelDefaultsKey),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return
        }
        // Defer slightly so LlamaRunner's own initialisation finishes
        // and any UI boot is through its first render cycle. 300ms is
        // plenty for either; the load itself takes 3-10s depending on
        // model size, and we want that to be background-ish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            // Synthesise an ai_load_model.json request — same path
            // the Python CLI uses, so the same pollLoadModel() handler
            // picks it up. That way all load attempts go through one
            // code path with consistent logging and state publishing.
            let sig = NSTemporaryDirectory().appending("latex_signals/")
            try? FileManager.default.createDirectory(
                atPath: sig, withIntermediateDirectories: true)
            let payload = ["path": path]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                let tmp = sig + "ai_load_model.json.tmp"
                try? data.write(to: URL(fileURLWithPath: tmp))
                try? FileManager.default.moveItem(atPath: tmp,
                    toPath: sig + "ai_load_model.json")
                NSLog("[AIEngine] auto-loading last model: %@", path)
            }
            _ = self  // silence unused-self warning
        }
    }

    private func publishCurrentModel(path: String) {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let text = "\(name)\n\(path)\n\(size)\n"
        try? text.write(toFile: signalDir + "current_model.txt",
                        atomically: true, encoding: .utf8)
    }

    private func writeModelDone(status: Int, message: String) {
        let text = "\(status)\n\(message)\n"
        try? text.write(toFile: signalDir + "ai_model_done.txt",
                        atomically: true, encoding: .utf8)
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
