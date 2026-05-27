//
//  AIRemoteProvider.swift
//  CodeBench
//
//  Lets the AI subsystem dispatch generation to a remote endpoint
//  (OpenAI-compatible, Anthropic, Ollama) instead of the bundled
//  LlamaRunner. The bundled GGUF path stays the default — remote is
//  opt-in via Settings.
//
//  Stream-decoding parsers handle:
//    • OpenAI / Ollama OpenAI-compat — SSE lines `data: {...}` with
//      `choices[].delta.content` chunks
//    • Anthropic Messages API        — SSE `event: content_block_delta`
//      with `delta.text` chunks
//
//  All HTTP calls use `URLSession.shared` and a streaming
//  `URLSession.AsyncBytes` body so the response surfaces token-by-token
//  with the same UX as the local model.
//
//  Keys are read from `Keychain` (account name = "ai.<provider>.key").
//  Keys never touch disk and never appear in UserDefaults / logs.
//

import Foundation
import Security

// MARK: - Provider config

/// Where the AI subsystem currently sources its generations from.
enum AIProviderKind: String, Codable, CaseIterable {
    case bundledGGUF    = "bundled"
    case openAI         = "openai"
    case anthropic      = "anthropic"
    case openAICompat   = "compat"   // any /v1/chat/completions endpoint (Ollama, vLLM, llama.cpp server, …)
}

/// Snapshot of remote-AI configuration. Persisted to UserDefaults
/// (everything except the API key, which lives in Keychain).
struct AIRemoteConfig: Codable {
    var kind: AIProviderKind = .bundledGGUF
    var baseURL: String = ""        // e.g. "https://api.openai.com/v1" or "http://192.168.1.10:11434/v1"
    var modelName: String = ""      // e.g. "gpt-4o-mini", "claude-3-5-sonnet-20241022", "llama3.1:8b"
    var temperature: Double = 0.2
    var maxTokens: Int = 2048

    static let defaultsKey = "AIRemoteConfig.v1"

    static func load() -> AIRemoteConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let cfg = try? JSONDecoder().decode(AIRemoteConfig.self, from: data) else {
            return AIRemoteConfig()
        }
        return cfg
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AIRemoteConfig.defaultsKey)
        }
    }
}

// MARK: - Keychain helper

/// Tiny wrapper around the Security framework — only stores / fetches
/// the per-provider API key. No 3rd-party deps; no leakage to disk
/// (Keychain access-class defaults to whenUnlockedThisDeviceOnly).
enum AIKeychain {

    private static let service = "ai.codebench"

    static func setKey(_ key: String, for provider: AIProviderKind) {
        let account = "ai." + provider.rawValue + ".key"
        // Delete existing first (Keychain SecItemUpdate semantics get
        // gnarly across iOS major versions; delete + add is safest).
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        guard !key.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = key.data(using: .utf8) ?? Data()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func key(for provider: AIProviderKind) -> String? {
        let account = "ai." + provider.rawValue + ".key"
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }
}

// MARK: - Provider

/// Lightweight provider that streams tokens from a remote HTTP endpoint.
/// Used by `AIEngine.poll()` when `AIRemoteConfig.load().kind != .bundledGGUF`.
final class AIRemoteProvider {

    /// Currently-running task — set so `cancel()` can abort mid-stream.
    private var currentTask: URLSessionDataTask?
    private let session: URLSession
    /// Continuous-output buffer for SSE parsing across chunks.
    private var sseBuffer = ""

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600  // long generations
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    /// Cancel the in-flight request (called by Ctrl-C path).
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Stream a generation from the configured remote endpoint.
    /// `onToken` fires for every token chunk delivered by the server.
    /// `completion` fires once when the stream ends (or errors).
    ///
    /// Returns immediately; runs the HTTP request on the URLSession's
    /// own queue and dispatches token / completion callbacks on that
    /// queue (AIEngine bridges those onto the main queue itself).
    func generate(messages: [ChatMessage],
                  config: AIRemoteConfig,
                  stopSequences: [String],
                  onToken: @escaping (String) -> Void,
                  completion: @escaping (Result<Void, Error>) -> Void) {

        let req: URLRequest
        do {
            req = try buildRequest(messages: messages, config: config,
                                   stopSequences: stopSequences)
        } catch {
            completion(.failure(error)); return
        }

        sseBuffer = ""
        let task = session.dataTask(with: req) { _, _, err in
            // Final callback — non-streamed completion. The streaming
            // tokens come through the delegate path via a custom
            // SSE-line collector below. For simplicity we use a
            // *non-delegate* dataTask here and parse the full body on
            // completion — server-sent events arrive line-by-line in
            // the data callback anyway when we use a delegate-based
            // session. Let me switch to the delegate-streaming form.
            if let err = err {
                if (err as NSError).code == NSURLErrorCancelled {
                    completion(.failure(NSError(domain: "AIRemoteProvider",
                                                code: -130,
                                                userInfo: [NSLocalizedDescriptionKey: "cancelled by user"])))
                } else {
                    completion(.failure(err))
                }
                return
            }
            completion(.success(()))
        }
        currentTask = task

        // SSE streaming: switch to a delegate-based session so we get
        // per-chunk callbacks. Below we re-issue with a delegate.
        startStreaming(req: req, config: config,
                       onToken: onToken, completion: completion)
        task.cancel()  // we don't actually use the simple-mode task; the delegate path does the work
    }

    // MARK: Streaming HTTP

    private func startStreaming(req: URLRequest,
                                config: AIRemoteConfig,
                                onToken: @escaping (String) -> Void,
                                completion: @escaping (Result<Void, Error>) -> Void) {
        let delegate = StreamDelegate(provider: self, config: config,
                                      onToken: onToken, completion: completion)
        let delSession = URLSession(configuration: session.configuration,
                                    delegate: delegate, delegateQueue: nil)
        let task = delSession.dataTask(with: req)
        currentTask = task
        task.resume()
    }

    // MARK: Request building

    private func buildRequest(messages: [ChatMessage],
                              config: AIRemoteConfig,
                              stopSequences: [String]) throws -> URLRequest {
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: .whitespaces)) else {
            throw NSError(domain: "AIRemoteProvider", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "ai: invalid base URL"])
        }
        let endpoint: URL
        switch config.kind {
        case .anthropic:
            endpoint = url.appendingPathComponent("messages")
        case .openAI, .openAICompat:
            endpoint = url.appendingPathComponent("chat/completions")
        case .bundledGGUF:
            // Shouldn't reach here — AIEngine routes to LlamaRunner first.
            throw NSError(domain: "AIRemoteProvider", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "ai: remote requested with bundled provider"])
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // Authorization header per provider
        switch config.kind {
        case .openAI, .openAICompat:
            if let k = AIKeychain.key(for: config.kind), !k.isEmpty {
                req.setValue("Bearer " + k, forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            if let k = AIKeychain.key(for: config.kind), !k.isEmpty {
                req.setValue(k, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        case .bundledGGUF:
            break
        }

        // Body — provider-specific JSON shape
        let body: [String: Any]
        switch config.kind {
        case .openAI, .openAICompat:
            body = [
                "model": config.modelName,
                "messages": messages.map { ["role": $0.role.wireString, "content": $0.content] },
                "stream": true,
                "max_tokens": config.maxTokens,
                "temperature": config.temperature,
                "stop": stopSequences,
            ]
        case .anthropic:
            // Anthropic uses a separate `system` field, not a system message in the array.
            var systemPrompt = ""
            var nonSystem: [[String: String]] = []
            for m in messages {
                if m.role == .system { systemPrompt += (systemPrompt.isEmpty ? "" : "\n\n") + m.content }
                else { nonSystem.append(["role": m.role.wireString, "content": m.content]) }
            }
            var b: [String: Any] = [
                "model": config.modelName,
                "messages": nonSystem,
                "stream": true,
                "max_tokens": config.maxTokens,
                "temperature": config.temperature,
            ]
            if !systemPrompt.isEmpty { b["system"] = systemPrompt }
            if !stopSequences.isEmpty { b["stop_sequences"] = stopSequences }
            body = b
        case .bundledGGUF:
            body = [:]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: SSE parsing

    /// Push a chunk of SSE bytes into the buffer and emit any
    /// complete `data: ...` payloads through `onChunk`. Returns true
    /// if a [DONE] terminator was seen.
    fileprivate func feedSSE(_ chunk: String,
                             config: AIRemoteConfig,
                             onToken: (String) -> Void) -> Bool {
        sseBuffer += chunk
        var sawDone = false
        // SSE messages are separated by blank lines; within a message
        // we look for "data: <json>" lines.
        while let nlRange = sseBuffer.range(of: "\n") {
            let line = String(sseBuffer[..<nlRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sseBuffer.removeSubrange(sseBuffer.startIndex...nlRange.lowerBound)
            if line.isEmpty { continue }
            if line.hasPrefix("event:") { continue }   // we just look at data:
            if !line.hasPrefix("data:") { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { sawDone = true; continue }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            // Provider-specific shape
            switch config.kind {
            case .openAI, .openAICompat:
                if let choices = obj["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let delta = first["delta"] as? [String: Any],
                   let content = delta["content"] as? String, !content.isEmpty {
                    onToken(content)
                }
            case .anthropic:
                if (obj["type"] as? String) == "content_block_delta",
                   let delta = obj["delta"] as? [String: Any],
                   let text = delta["text"] as? String, !text.isEmpty {
                    onToken(text)
                }
                if (obj["type"] as? String) == "message_stop" { sawDone = true }
            case .bundledGGUF:
                break
            }
        }
        return sawDone
    }
}

// MARK: - Streaming delegate

private final class StreamDelegate: NSObject, URLSessionDataDelegate {
    weak var provider: AIRemoteProvider?
    let config: AIRemoteConfig
    let onToken: (String) -> Void
    let completion: (Result<Void, Error>) -> Void
    private var finalized = false

    init(provider: AIRemoteProvider, config: AIRemoteConfig,
         onToken: @escaping (String) -> Void,
         completion: @escaping (Result<Void, Error>) -> Void) {
        self.provider = provider
        self.config = config
        self.onToken = onToken
        self.completion = completion
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard let provider = provider,
              let chunk = String(data: data, encoding: .utf8) else { return }
        let done = provider.feedSSE(chunk, config: config, onToken: onToken)
        if done { finalize(.success(())) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let err = error {
            if (err as NSError).code == NSURLErrorCancelled {
                finalize(.failure(NSError(domain: "AIRemoteProvider", code: -130,
                                          userInfo: [NSLocalizedDescriptionKey: "cancelled by user"])))
            } else {
                finalize(.failure(err))
            }
        } else {
            finalize(.success(()))
        }
        session.invalidateAndCancel()
    }

    private func finalize(_ r: Result<Void, Error>) {
        if finalized { return }
        finalized = true
        completion(r)
    }
}

// MARK: - ChatMessage.role wire mapping

private extension ChatMessage.Role {
    var wireString: String {
        switch self {
        case .system:    return "system"
        case .user:      return "user"
        case .assistant: return "assistant"
        }
    }
}
