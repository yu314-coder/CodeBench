import Foundation

enum ModelSlot: Int, CaseIterable {
    case qwen35_08b = 0
    case qwen35_2b  = 1
    case qwen35_4b  = 2
    case qwen35_9b  = 3
    case gemma4_e2b  = 4
    case gemma4_e4b  = 5
    case gemma4_26b  = 6

    var title: String {
        switch self {
        case .qwen35_08b:  return "Qwen3.5-0.8B"
        case .qwen35_2b:   return "Qwen3.5-2B"
        case .qwen35_4b:   return "Qwen3.5-4B"
        case .qwen35_9b:   return "Qwen3.5-9B"
        case .gemma4_e2b:  return "Gemma 4 E2B"
        case .gemma4_e4b:  return "Gemma 4 E4B"
        case .gemma4_26b:  return "Gemma 4 26B-A4B"
        }
    }

    var subtitle: String {
        switch self {
        case .qwen35_08b:  return "Ultra-light  ~0.5 GB"
        case .qwen35_2b:   return "Fast & capable  ~1.4 GB"
        case .qwen35_4b:   return "Balanced  ~2.5 GB"
        case .qwen35_9b:   return "Highest quality  ~4.6 GB  (Q3_K_S)"
        case .gemma4_e2b:  return "Google · Efficient 2B  ~1.6 GB"
        case .gemma4_e4b:  return "Google · Efficient 4B  ~2.9 GB"
        case .gemma4_26b:  return "Google · MoE 26B (4B active)  ~16.9 GB"
        }
    }

    var storageKey: String {
        switch self {
        case .qwen35_08b:  return "model.qwen3_5_0_8b.gguf"
        case .qwen35_2b:   return "model.qwen3_5_2b.gguf"
        case .qwen35_4b:   return "model.qwen3_5_4b.gguf"
        case .qwen35_9b:   return "model.qwen3_5_9b.gguf"
        case .gemma4_e2b:  return "model.gemma4_e2b.gguf"
        case .gemma4_e4b:  return "model.gemma4_e4b.gguf"
        case .gemma4_26b:  return "model.gemma4_26b_a4b.gguf"
        }
    }

    var filePrefix: String {
        switch self {
        case .qwen35_08b:  return "qwen3_5_0_8b"
        case .qwen35_2b:   return "qwen3_5_2b"
        case .qwen35_4b:   return "qwen3_5_4b"
        case .qwen35_9b:   return "qwen3_5_9b"
        case .gemma4_e2b:  return "gemma4_e2b"
        case .gemma4_e4b:  return "gemma4_e4b"
        case .gemma4_26b:  return "gemma4_26b_a4b"
        }
    }

    var downloadURL: URL {
        switch self {
        case .qwen35_08b:
            return URL(string: "https://huggingface.co/lmstudio-community/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf")!
        case .qwen35_2b:
            return URL(string: "https://huggingface.co/lmstudio-community/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!
        case .qwen35_4b:
            return URL(string: "https://huggingface.co/lmstudio-community/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")!
        case .qwen35_9b:
            return URL(string: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q3_K_S.gguf")!
        case .gemma4_e2b:
            return URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf")!
        case .gemma4_e4b:
            return URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf")!
        case .gemma4_26b:
            return URL(string: "https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf")!
        }
    }

    /// Recommended for most iPads (fits in 8GB RAM)
    static var recommended: [ModelSlot] {
        [.qwen35_2b, .gemma4_e2b, .qwen35_4b, .gemma4_e4b]
    }

    /// For iPads with 16GB+ RAM
    static var large: [ModelSlot] {
        [.qwen35_9b, .gemma4_26b]
    }
}
