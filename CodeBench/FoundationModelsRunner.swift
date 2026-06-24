import Foundation
import FoundationModels   // Weak-linked; iOS 26+. All API calls are #available-gated.

/// Common interface for the editor AI's text engines, so the AI edit box can
/// route to either the bundled GGUF models (`LlamaRunner`) or Apple's
/// on-device model (`FoundationModelsRunner`) through one call.
///
/// The convenience overload lets existing call sites keep using
/// `generate(messages:maxTokens:onToken:completion:)` (no grammar /
/// stopSequences) when the value is typed as `any TextGenerator`.
protocol TextGenerator: AnyObject {
    func generate(messages: [ChatMessage],
                  maxTokens: Int,
                  grammar: String?,
                  stopSequences: [String],
                  onToken: @escaping (String) -> Void,
                  completion: @escaping (Result<String, Error>) -> Void)
}

extension TextGenerator {
    func generate(messages: [ChatMessage],
                  maxTokens: Int,
                  onToken: @escaping (String) -> Void,
                  completion: @escaping (Result<String, Error>) -> Void) {
        generate(messages: messages, maxTokens: maxTokens, grammar: nil,
                 stopSequences: [], onToken: onToken, completion: completion)
    }
}

/// Editor AI engine backed by Apple's on-device model — the same model family
/// behind Apple Intelligence / Siri — via the Foundation Models framework.
///
/// • Availability needs **iOS 26+ AND an Apple-Intelligence-capable device**
///   (`isAvailable()`); otherwise the editor falls back to the bundled GGUF
///   runner.
/// • The model is OS-provided, so on a device running **iOS 27 this
///   transparently uses the iOS 27 model** — this code just calls the stable
///   API. Builds on the iOS 26 SDK (Xcode 26.x), so it ships today.
/// • iOS-27-only extras (image input, server models, Core AI) are deliberately
///   NOT used here — those require the iOS 27 SDK.
final class FoundationModelsRunner: TextGenerator {

    enum FMError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Apple's on-device model isn't available here — it needs iOS 26 or "
            + "later and an Apple-Intelligence-capable device."
        }
    }

    /// True when the on-device model can actually run on this device/OS.
    static func isAvailable() -> Bool {
        if #available(iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        return false
    }

    /// Human-readable reason it's unavailable, or nil when available.
    static func unavailableReason() -> String? {
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason): return "\(reason)"
            @unknown default: return "unavailable"
            }
        }
        return "requires iOS 26 or later"
    }

    func generate(messages: [ChatMessage],
                  maxTokens: Int,
                  grammar: String?,
                  stopSequences: [String],
                  onToken: @escaping (String) -> Void,
                  completion: @escaping (Result<String, Error>) -> Void) {
        guard #available(iOS 26, *), Self.isAvailable() else {
            DispatchQueue.main.async { completion(.failure(FMError.unavailable)) }
            return
        }

        // System messages become the session's instructions; the rest are
        // flattened into a single prompt (the on-device model is one-shot here).
        let instructions = messages.filter { $0.role == .system }
            .map(\.content).joined(separator: "\n\n")
        let convo = messages.filter { $0.role != .system }
            .map { ($0.role == .user ? "User: " : "Assistant: ") + $0.content }
            .joined(separator: "\n\n")
        let prompt = convo.isEmpty ? " " : convo

        Task {
            do {
                let session = instructions.isEmpty
                    ? LanguageModelSession()
                    : LanguageModelSession(instructions: instructions)
                var prev = ""
                // streamResponse yields cumulative snapshots; emit the new
                // suffix as a token delta so the edit box streams like GGUF.
                for try await partial in session.streamResponse(to: prompt) {
                    let cur = partial.content
                    if cur.count > prev.count {
                        let delta = String(cur.dropFirst(prev.count))
                        DispatchQueue.main.async { onToken(delta) }
                        prev = cur
                    }
                }
                let final = prev
                DispatchQueue.main.async { completion(.success(final)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
