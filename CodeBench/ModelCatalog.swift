import Foundation

/// Catalog of in-app GGUF model slots. Each slot is one downloadable
/// model: enum case, display strings, the URL it ships from, and the
/// `filePrefix` used to detect an already-downloaded copy in
/// ~/Documents/Models/.
///
/// Order matters: rawValue is persisted as the user's last selection
/// in UserDefaults. Add new slots AT THE END so existing installs
/// keep their selection.
///
/// Quantization choice: Q4_K_M for everything 7B and below (best
/// quality/size for iPad-class RAM), Q3_K_S for 9B+ where Q4 would
/// push into jetsam pressure on 8GB devices.
enum ModelSlot: Int, CaseIterable {
    // ── Existing (do not reorder) ────────────────────────────────
    case qwen35_08b = 0
    case qwen35_2b  = 1
    case qwen35_4b  = 2
    case qwen35_9b  = 3
    case gemma4_e2b = 4
    case gemma4_e4b = 5
    case gemma4_26b = 6
    // ── New: well-tested popular open-source models ─────────────
    case llama32_1b    = 7
    case llama32_3b    = 8
    case phi35_mini    = 9
    case mistral7b_v03 = 10
    case qwen25coder_7b = 11
    case deepseek_r1_distill_qwen7b = 12
    case granite31_8b  = 13
    case smollm2_1_7b  = 14

    var title: String {
        switch self {
        case .qwen35_08b:                return "Qwen3.5-0.8B"
        case .qwen35_2b:                 return "Qwen3.5-2B"
        case .qwen35_4b:                 return "Qwen3.5-4B"
        case .qwen35_9b:                 return "Qwen3.5-9B"
        case .gemma4_e2b:                return "Gemma 4 E2B"
        case .gemma4_e4b:                return "Gemma 4 E4B"
        case .gemma4_26b:                return "Gemma 4 26B-A4B"
        case .llama32_1b:                return "Llama 3.2 1B"
        case .llama32_3b:                return "Llama 3.2 3B"
        case .phi35_mini:                return "Phi-3.5 Mini"
        case .mistral7b_v03:             return "Mistral 7B v0.3"
        case .qwen25coder_7b:            return "Qwen2.5-Coder 7B"
        case .deepseek_r1_distill_qwen7b: return "DeepSeek-R1 Distill 7B"
        case .granite31_8b:              return "Granite 3.1 8B"
        case .smollm2_1_7b:              return "SmolLM2 1.7B"
        }
    }

    var subtitle: String {
        switch self {
        case .qwen35_08b:                return "Ultra-light  ~0.5 GB"
        case .qwen35_2b:                 return "Fast & capable  ~1.4 GB"
        case .qwen35_4b:                 return "Balanced  ~2.2 GB  (Q3_K_M · 8 GB iPads)"
        case .qwen35_9b:                 return "Highest quality  ~4.6 GB  (Q3_K_S · 16 GB only)"
        case .gemma4_e2b:                return "Google · Efficient 2B  ~2.4 GB  (Q3_K_M · 8 GB iPads)"
        case .gemma4_e4b:                return "Google · Efficient 4B  ~3.7 GB  (Q3_K_S · 16 GB only)"
        case .gemma4_26b:                return "Google · MoE 26B (4B active)  ~16.2 GB"
        case .llama32_1b:                return "Meta · Lightweight  ~0.8 GB"
        case .llama32_3b:                return "Meta · General  ~2.0 GB"
        case .phi35_mini:                return "Microsoft · 3.8B  ~2.3 GB"
        case .mistral7b_v03:             return "Mistral · Reliable  ~4.4 GB"
        case .qwen25coder_7b:            return "Code-tuned  ~4.7 GB"
        case .deepseek_r1_distill_qwen7b: return "Reasoning · 7B  ~4.7 GB"
        case .granite31_8b:              return "IBM · Enterprise  ~4.9 GB"
        case .smollm2_1_7b:              return "HF · Tiny + smart  ~1.1 GB"
        }
    }

    /// Identifier used in UserDefaults for the "model loaded"
    /// snapshot — distinct from `filePrefix` because we may want to
    /// renumber the on-disk filename in the future without breaking
    /// existing UserDefaults entries.
    var storageKey: String {
        switch self {
        case .qwen35_08b:                return "model.qwen3_5_0_8b.gguf"
        case .qwen35_2b:                 return "model.qwen3_5_2b.gguf"
        case .qwen35_4b:                 return "model.qwen3_5_4b.gguf"
        case .qwen35_9b:                 return "model.qwen3_5_9b.gguf"
        case .gemma4_e2b:                return "model.gemma4_e2b.gguf"
        case .gemma4_e4b:                return "model.gemma4_e4b.gguf"
        case .gemma4_26b:                return "model.gemma4_26b_a4b.gguf"
        case .llama32_1b:                return "model.llama32_1b.gguf"
        case .llama32_3b:                return "model.llama32_3b.gguf"
        case .phi35_mini:                return "model.phi35_mini.gguf"
        case .mistral7b_v03:             return "model.mistral7b_v03.gguf"
        case .qwen25coder_7b:            return "model.qwen25coder_7b.gguf"
        case .deepseek_r1_distill_qwen7b: return "model.deepseek_r1_distill_qwen7b.gguf"
        case .granite31_8b:              return "model.granite31_8b.gguf"
        case .smollm2_1_7b:              return "model.smollm2_1_7b.gguf"
        }
    }

    /// Filename prefix used to detect already-downloaded copies in
    /// ~/Documents/Models/. The downloader saves files as
    /// `<filePrefix>-<quant>.gguf`, and ModelsManagerViewController
    /// scans for files starting with this string.
    var filePrefix: String {
        switch self {
        case .qwen35_08b:                return "qwen3_5_0_8b"
        case .qwen35_2b:                 return "qwen3_5_2b"
        case .qwen35_4b:                 return "qwen3_5_4b"
        case .qwen35_9b:                 return "qwen3_5_9b"
        case .gemma4_e2b:                return "gemma4_e2b"
        case .gemma4_e4b:                return "gemma4_e4b"
        case .gemma4_26b:                return "gemma4_26b_a4b"
        case .llama32_1b:                return "llama32_1b"
        case .llama32_3b:                return "llama32_3b"
        case .phi35_mini:                return "phi35_mini"
        case .mistral7b_v03:             return "mistral7b_v03"
        case .qwen25coder_7b:            return "qwen25coder_7b"
        case .deepseek_r1_distill_qwen7b: return "deepseek_r1_distill_qwen7b"
        case .granite31_8b:              return "granite31_8b"
        case .smollm2_1_7b:              return "smollm2_1_7b"
        }
    }

    /// HuggingFace download URL. Kept as Q4_K_M for everything ≤7B
    /// (best quality/size ratio for iPad-class RAM); larger sizes
    /// move to Q3_K_S to stay under jetsam.
    ///
    /// Bartowski's repos are preferred where available — they ship
    /// well-tested quants with stable filenames.
    var downloadURL: URL {
        switch self {
        case .qwen35_08b:
            return URL(string: "https://huggingface.co/lmstudio-community/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf")!
        case .qwen35_2b:
            return URL(string: "https://huggingface.co/lmstudio-community/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!
        case .qwen35_4b:
            // Q3_K_M (2.2 GB) instead of Q4_K_M (2.8 GB) so 8 GB iPads
            // (~4 GB jetsam) keep ≥1.5 GB headroom for KV cache and
            // tensor scratch. Q4 was technically loadable but inference
            // pushed past jetsam at ~3K tokens.
            return URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q3_K_M.gguf")!
        case .qwen35_9b:
            return URL(string: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q3_K_S.gguf")!
        case .gemma4_e2b:
            // Same logic as Qwen 4B — Q3_K_M is the sweet spot for
            // 8 GB iPads (2.4 GB on disk, ~3 GB resident with KV).
            return URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q3_K_M.gguf")!
        case .gemma4_e4b:
            // E4B can't fit 8 GB at any reasonable quant — even Q2
            // is 3.6 GB on disk, ~5 GB resident. Q3_K_S is the
            // smallest quant that still produces coherent output;
            // labeled "16 GB only" in the subtitle so users on 8 GB
            // iPads pick E2B instead.
            return URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q3_K_S.gguf")!
        case .gemma4_26b:
            return URL(string: "https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf")!
        case .llama32_1b:
            return URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!
        case .llama32_3b:
            return URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!
        case .phi35_mini:
            return URL(string: "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf")!
        case .mistral7b_v03:
            return URL(string: "https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf")!
        case .qwen25coder_7b:
            return URL(string: "https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf")!
        case .deepseek_r1_distill_qwen7b:
            return URL(string: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf")!
        case .granite31_8b:
            return URL(string: "https://huggingface.co/bartowski/granite-3.1-8b-instruct-GGUF/resolve/main/granite-3.1-8b-instruct-Q4_K_M.gguf")!
        case .smollm2_1_7b:
            return URL(string: "https://huggingface.co/bartowski/SmolLM2-1.7B-Instruct-GGUF/resolve/main/SmolLM2-1.7B-Instruct-Q4_K_M.gguf")!
        }
    }

    /// Human-readable approximate disk-and-RAM cost, parsed by the
    /// onboarding UI to decide which models to suggest as "small
    /// enough to start with."
    var approximateBytes: Int64 {
        switch self {
        case .qwen35_08b:                return  500_000_000
        case .qwen35_2b:                 return 1_400_000_000
        case .qwen35_4b:                 return 2_190_000_000   // Q3_K_M
        case .qwen35_9b:                 return 4_600_000_000   // Q3_K_S
        case .gemma4_e2b:                return 2_420_000_000   // Q3_K_M
        case .gemma4_e4b:                return 3_680_000_000   // Q3_K_S
        case .gemma4_26b:                return 16_950_000_000
        case .llama32_1b:                return   800_000_000
        case .llama32_3b:                return 2_000_000_000
        case .phi35_mini:                return 2_300_000_000
        case .mistral7b_v03:             return 4_400_000_000
        case .qwen25coder_7b:            return 4_700_000_000
        case .deepseek_r1_distill_qwen7b: return 4_700_000_000
        case .granite31_8b:              return 4_900_000_000
        case .smollm2_1_7b:              return 1_100_000_000
        }
    }

    /// Family tag for grouping in the model picker — lets the UI
    /// stack "Llama" / "Gemma" / "Qwen" rows together with section
    /// headers. Pure presentation; nothing else uses it.
    var family: Family {
        switch self {
        case .qwen35_08b, .qwen35_2b, .qwen35_4b, .qwen35_9b:
            return .qwen
        case .qwen25coder_7b:
            return .qwen
        case .gemma4_e2b, .gemma4_e4b, .gemma4_26b:
            return .gemma
        case .llama32_1b, .llama32_3b:
            return .llama
        case .phi35_mini:
            return .phi
        case .mistral7b_v03:
            return .mistral
        case .deepseek_r1_distill_qwen7b:
            return .deepseek
        case .granite31_8b:
            return .granite
        case .smollm2_1_7b:
            return .smol
        }
    }

    enum Family: String, CaseIterable {
        case qwen, gemma, llama, phi, mistral, deepseek, granite, smol

        var displayName: String {
            switch self {
            case .qwen:     return "Qwen / Alibaba"
            case .gemma:    return "Gemma / Google"
            case .llama:    return "Llama / Meta"
            case .phi:      return "Phi / Microsoft"
            case .mistral:  return "Mistral"
            case .deepseek: return "DeepSeek"
            case .granite:  return "Granite / IBM"
            case .smol:     return "SmolLM / HuggingFace"
            }
        }
    }

    /// Coding-tuned subset, for editor/AI-edit "code completion" use
    /// where reasoning latency matters less than syntactic fluency
    /// in code. Surfaced as a separate group in the model picker.
    var isCodingFocused: Bool {
        switch self {
        case .qwen25coder_7b, .deepseek_r1_distill_qwen7b:
            return true
        default:
            return false
        }
    }

    // MARK: - Curated lists

    /// Fits comfortably on 8 GB iPads (jetsam ceiling ~3.5–4 GB).
    /// Model weights ≤ 2.5 GB so there's room left for the KV cache,
    /// tensor scratch, and the rest of the app. Quants chosen
    /// specifically to land in this window: Q3_K_M for the 4B-class
    /// models (Qwen 3.5 4B, Gemma 4 E2B), Q4_K_M for 0.5–3 B.
    /// Default suggestions in the onboarding UI.
    static var recommended: [ModelSlot] {
        [.qwen35_2b, .qwen35_4b, .gemma4_e2b,
         .llama32_3b, .phi35_mini, .smollm2_1_7b]
    }

    /// 7B–8B class — model weights 2.5–5 GB. Borderline on 8 GB
    /// iPads (works for short contexts, jetsams during long sessions);
    /// fine on 16 GB iPad Pro M4. Recommended only if the user has
    /// confirmed they're on a high-RAM device.
    static var midweight: [ModelSlot] {
        [.mistral7b_v03,
         .qwen25coder_7b, .deepseek_r1_distill_qwen7b, .granite31_8b]
    }

    /// 9B+ class plus the 4B-Gemma E4B variant — model weights ≥3.5 GB.
    /// Will not fit 8 GB iPads under sustained inference. Marked
    /// "16 GB only" in the subtitle so the picker UI can warn or
    /// hide them on lower-RAM devices.
    static var large: [ModelSlot] {
        [.qwen35_9b, .gemma4_e4b, .gemma4_26b]
    }
}
