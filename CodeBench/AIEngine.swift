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
    /// Set when the current generation has been cancelled via Ctrl-C.
    /// Cleared on the next `poll()` that accepts a new request.
    private var didRequestCancel = false

    private var signalDir: String { NSTemporaryDirectory().appending("latex_signals/") }

    override private init() { super.init() }

    @MainActor
    func start() {
        guard signalTimer == nil else { return }
        try? FileManager.default.createDirectory(atPath: signalDir, withIntermediateDirectories: true)
        signalTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.poll()
            self?.pollLoadModel()
            self?.pollCancel()
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

    /// Crash-detection flag. Set true just before `autoLoadLastModel`
    /// dispatches the load; cleared 5 seconds after launch if the app
    /// is still alive. If we see it set to true on a fresh launch, it
    /// means the previous run crashed during/after auto-load — most
    /// commonly because the stored GGUF used an architecture the
    /// bundled llama.cpp NULL-derefs on iOS Metal (Qwen3.5's "qwen35"
    /// → LLM_ARCH_QWEN3NEXT SSM kernels, for example). Skipping
    /// auto-load for one run lets the user pick a different model via
    /// `ai /load <path>` without the app crash-looping at launch.
    private static let autoLoadInFlightKey = "ai.autoload.inflight"

    /// Kick off a background load of whichever model was active last
    /// time the app ran. Called from `start()` — blocks nothing, just
    /// schedules the load so by the time the user types `ai` the
    /// model is (likely) already warm. Gated by a crash-watchdog flag
    /// so a crash during load doesn't leave the app unlaunchable.
    private func autoLoadLastModel() {
        // Aggressive fix for launch-crash-loop: disable auto-load
        // unconditionally, and pro-actively scrub both UserDefaults keys
        // so the system is in a known-clean state. The watchdog-based
        // version below still exists (kept for reference) but is
        // unreachable — the `return` on the next line short-circuits it.
        // When we're confident the crashes aren't from auto-load, remove
        // this block.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.lastModelDefaultsKey)
        defaults.set(false, forKey: Self.autoLoadInFlightKey)
        NSLog("[AIEngine] auto-load DISABLED — call `ai /load <path>` manually to load a model")
        return
        #if false
        // Step 1: if the previous launch set the in-flight flag and
        // never cleared it, that run crashed during auto-load. Skip
        // the load this time, forget the stored path (so the user
        // isn't stuck in the same loop), and tell the user why.
        if defaults.bool(forKey: Self.autoLoadInFlightKey) {
            let badPath = defaults.string(forKey: Self.lastModelDefaultsKey) ?? "<unknown>"
            defaults.removeObject(forKey: Self.lastModelDefaultsKey)
            defaults.set(false, forKey: Self.autoLoadInFlightKey)
            NSLog("[AIEngine] previous launch crashed during auto-load of %@ — skipping auto-load this run; use `ai /load <path>` to pick a different model", badPath)
            return
        }

        guard let path = defaults.string(forKey: Self.lastModelDefaultsKey),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return
        }

        // Step 2: arm the watchdog before dispatching the load.
        defaults.set(true, forKey: Self.autoLoadInFlightKey)

        // Step 3: 5s after launch, if we're still alive, disarm —
        // whichever thread the LlamaRunner is on would have faulted
        // long before this if the model was going to crash on load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            UserDefaults.standard.set(false, forKey: Self.autoLoadInFlightKey)
        }

        // Step 4: schedule the load itself. Defer 300ms so LlamaRunner
        // init + first UI render complete first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
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
        #endif
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

    /// Handle `ai_cancel.txt` — Python writes this when the user hits
    /// Ctrl-C during generation, telling the Swift LlamaRunner to stop
    /// producing tokens. Runner.cancelGeneration flips an internal
    /// flag that the generation loop checks between tokens; the
    /// existing completion handler then fires with a cancelled result
    /// and the normal `ai_done.txt` write path runs, so Python's
    /// _stream_response unblocks cleanly.
    private func pollCancel() {
        let cancelPath = signalDir + "ai_cancel.txt"
        guard FileManager.default.fileExists(atPath: cancelPath) else { return }
        try? FileManager.default.removeItem(atPath: cancelPath)
        guard inFlight else { return }
        didRequestCancel = true
        runner?.cancelGeneration()
        NSLog("[AIEngine] generation cancelled by user (Ctrl-C)")
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
                    if self.didRequestCancel {
                        // Status -130 mirrors UNIX's "killed by SIGINT"
                        // convention (128 + 2). Python side treats any
                        // status == -130 as a user-initiated cancel and
                        // prints a friendly "^C — interrupted" line
                        // instead of a generic error.
                        self.writeDone(status: -130, message: "cancelled by user")
                        self.didRequestCancel = false
                        return
                    }
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
