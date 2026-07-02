import Foundation
import FoundationModels   // iOS 26+. The Cloud-Pro (iOS 27) paths are #if canImport(CoreAI)-gated.

/// Common interface for the editor AI's text engines, so the AI edit box can
/// route to either the bundled GGUF models (`LlamaRunner`) or Apple's
/// Foundation Models (`FoundationModelsRunner`) through one call.
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

/// Editor AI engine backed by Apple's Foundation Models (the AFM 3 family
/// behind Apple Intelligence / Siri). Two selectable tiers:
///
/// • **`.onDevice`** — `SystemLanguageModel` (AFM 3 Core / Core Advanced; the OS
///   picks which by device). iOS 26+, free, offline, private. The on-device path
///   compiles on the iOS 26 SDK (Xcode 26.5) and ships in the App Store build.
/// • **`.cloudPro`** — `PrivateCloudComputeLanguageModel` (AFM 3 Cloud Pro;
///   larger, reasoning, metered quota), via Private Cloud Compute. This needs
///   the **iOS 27 SDK** — its code is `#if canImport(CoreAI)`-gated (CoreAI ships
///   only in the iOS 27 SDK), so a Xcode 26.5 build simply excludes it and the
///   tier reports unavailable there.
final class FoundationModelsRunner: TextGenerator {

    /// Which Apple model this runner targets. Set by the model picker before use.
    enum Tier: String { case onDevice, cloudPro }

    var tier: Tier = .onDevice

    enum FMError: LocalizedError {
        case unavailable(Tier)
        case generation(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(.onDevice):
                return "Apple's on-device model isn't available — it needs iOS 26+ "
                     + "and an Apple-Intelligence-capable device."
            case .unavailable(.cloudPro):
                return "Apple Cloud Pro isn't available — it needs iOS 27 with Apple "
                     + "Intelligence, a network connection, and remaining daily quota."
            case .generation(let m):
                return m
            }
        }
    }

    /// Turn an opaque FoundationModels error — which often surfaces only as
    /// "LanguageModelError error -1" via `localizedDescription` — into an
    /// actionable message. The error enums are `CustomDebugStringConvertible`,
    /// so `String(describing:)` reveals the real case + context.
    @available(iOS 26, *)
    private static func describe(_ error: Error) -> String {
        if let g = error as? LanguageModelSession.GenerationError {
            switch g {
            case .exceededContextWindowSize:
                return "Apple model: prompt too long for this model's context window — "
                     + "shorten the file/selection or remove attachments."
            case .assetsUnavailable:
                return "Apple model isn't downloaded yet — open Settings ▸ Apple "
                     + "Intelligence & Siri, enable it, let the model finish downloading, then retry."
            case .guardrailViolation:
                return "Apple model blocked this request (safety guardrails)."
            case .unsupportedLanguageOrLocale:
                return "Apple model: this device language/region isn't supported."
            case .decodingFailure:
                return "Apple model returned malformed output."
            case .rateLimited:
                return "Apple model is rate-limited — wait a moment and retry."
            case .concurrentRequests:
                return "Apple model is busy with another request — retry."
            case .unsupportedGuide:
                return "Apple model: unsupported generation guide."
            case .refusal:
                return "Apple model refused this request."
            @unknown default:
                return "Apple model error: \(g)"
            }
        }
        // Any other FoundationModels error — its debugDescription is far more
        // useful than the "-1" localizedDescription.
        return "Apple model error: \(String(describing: error))"
    }

    /// True when the given tier can actually run on this device/OS/SDK.
    static func isAvailable(_ tier: Tier = .onDevice) -> Bool {
        switch tier {
        case .onDevice:
            if #available(iOS 26, *), case .available = SystemLanguageModel.default.availability { return true }
            return false
        case .cloudPro:
            #if canImport(CoreAI)
            if #available(iOS 27, *), case .available = PrivateCloudComputeLanguageModel().availability { return true }
            #endif
            return false
        }
    }

    /// Human-readable reason the tier is unavailable, or nil when available.
    static func unavailableReason(_ tier: Tier = .onDevice) -> String? {
        switch tier {
        case .onDevice:
            if #available(iOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return nil
                case .unavailable(let r): return "\(r)"
                @unknown default: return "unavailable"
                }
            }
            return "requires iOS 26 or later"
        case .cloudPro:
            #if canImport(CoreAI)
            if #available(iOS 27, *) {
                switch PrivateCloudComputeLanguageModel().availability {
                case .available: return nil
                case .unavailable(let r): return "\(r)"
                @unknown default: return "unavailable"
                }
            }
            return "requires iOS 27 or later"
            #else
            return "requires building with the iOS 27 SDK"
            #endif
        }
    }

    /// Cloud Pro is metered; surface a short warning when near/over the daily
    /// quota (nil otherwise, and always nil for on-device / pre-iOS-27 builds).
    static func cloudProQuotaWarning() -> String? {
        #if canImport(CoreAI)
        if #available(iOS 27, *) {
            let q = PrivateCloudComputeLanguageModel().quotaUsage
            if q.isLimitReached { return "Cloud Pro daily limit reached" }
            if case .belowLimit(let b) = q.status, b.isApproachingLimit {
                return "Cloud Pro near daily limit"
            }
        }
        #endif
        return nil
    }

    func generate(messages: [ChatMessage],
                  maxTokens: Int,
                  grammar: String?,
                  stopSequences: [String],
                  onToken: @escaping (String) -> Void,
                  completion: @escaping (Result<String, Error>) -> Void) {
        let selectedTier = tier
        guard Self.isAvailable(selectedTier) else {
            DispatchQueue.main.async { completion(.failure(FMError.unavailable(selectedTier))) }
            return
        }

        // System messages become the session's instructions; the rest are
        // flattened into a single prompt.
        let instructions = messages.filter { $0.role == .system }
            .map(\.content).joined(separator: "\n\n")
        let convo = messages.filter { $0.role != .system }
            .map { ($0.role == .user ? "User: " : "Assistant: ") + $0.content }
            .joined(separator: "\n\n")
        let prompt = convo.isEmpty ? " " : convo

        Task {
            guard #available(iOS 26, *),
                  let session = Self.makeSession(tier: selectedTier, instructions: instructions) else {
                DispatchQueue.main.async { completion(.failure(FMError.unavailable(selectedTier))) }
                return
            }
            do {
                var prev = ""
                // streamResponse yields cumulative snapshots; emit the new suffix
                // as a token delta so the edit box streams like the GGUF path.
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
                let msg = Self.describe(error)
                DispatchQueue.main.async { completion(.failure(FMError.generation(msg))) }
            }
        }
    }

    /// Build a session for the tier. On-device uses `SystemLanguageModel`
    /// (iOS 26+); Cloud Pro uses `PrivateCloudComputeLanguageModel` (iOS 27 SDK,
    /// `#if canImport(CoreAI)`). Returns nil if the tier can't be constructed here.
    @available(iOS 26, *)
    private static func makeSession(tier: Tier, instructions: String) -> LanguageModelSession? {
        switch tier {
        case .onDevice:
            return instructions.isEmpty
                ? LanguageModelSession()
                : LanguageModelSession(instructions: instructions)
        case .cloudPro:
            #if canImport(CoreAI)
            if #available(iOS 27, *) {
                return LanguageModelSession(model: PrivateCloudComputeLanguageModel()) { instructions }
            }
            #endif
            return nil
        }
    }
}
