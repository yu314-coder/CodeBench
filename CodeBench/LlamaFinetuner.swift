import Foundation
import llama

/// On-device LoRA fine-tuning via QVAC's `llama_swift_run_lora_finetune`
/// C entry point (FinetuneBridge.mm). The bridge takes a model path
/// + dataset path + options and produces a LoRA adapter file. Training
/// runs on the iPad GPU via the Metal backward kernels in our patched
/// llama.framework.
///
/// Output: a small `.gguf` LoRA adapter (~1-50 MB) that loads on top
/// of the base model for inference. The base model isn't modified.

final class LlamaFinetuner {

    static let shared = LlamaFinetuner()

    enum FineTuneError: LocalizedError {
        case noModelLoaded
        case noModelPath
        case dataFileMissing(String)
        case invalidArgument
        case modelLoadFailed
        case contextCreateFailed
        case datasetBuildFailed
        case trainingInitFailed
        case saveFailed
        case unknown(Int32)

        init(code: llama_swift_finetune_error) {
            switch code {
            case LLAMA_SWIFT_FINETUNE_OK:                self = .unknown(0)
            case LLAMA_SWIFT_FINETUNE_ERROR_INVALID_ARGUMENT: self = .invalidArgument
            case LLAMA_SWIFT_FINETUNE_ERROR_MODEL_LOAD:       self = .modelLoadFailed
            case LLAMA_SWIFT_FINETUNE_ERROR_CONTEXT_CREATE:   self = .contextCreateFailed
            case LLAMA_SWIFT_FINETUNE_ERROR_DATASET:          self = .datasetBuildFailed
            case LLAMA_SWIFT_FINETUNE_ERROR_TRAINING_INIT:    self = .trainingInitFailed
            case LLAMA_SWIFT_FINETUNE_ERROR_SAVE:             self = .saveFailed
            default: self = .unknown(Int32(code.rawValue))
            }
        }

        var errorDescription: String? {
            switch self {
            case .noModelLoaded:      return "no model is loaded — load a GGUF first via the Models tab"
            case .noModelPath:        return "could not resolve current model's file path on disk"
            case .dataFileMissing(let p): return "training data file not found: \(p)"
            case .invalidArgument:    return "invalid argument passed to fine-tune (check epochs/lr/data path)"
            case .modelLoadFailed:    return "could not load model for training — file may be corrupt or incompatible"
            case .contextCreateFailed:return "training context allocation failed — likely out of memory"
            case .datasetBuildFailed: return "training dataset construction failed — corpus may be too short"
            case .trainingInitFailed: return "llama_opt_init failed — model architecture may not support training"
            case .saveFailed:         return "could not write LoRA adapter to disk"
            case .unknown(let c):     return "unknown error code \(c)"
            }
        }
    }

    struct Progress {
        let logLine: String
    }

    private let queue = DispatchQueue(label: "LlamaFinetuner", qos: .userInitiated)

    /// Run a LoRA fine-tune. The model is loaded fresh by the bridge
    /// (we don't reuse the inference context), trained, and the
    /// resulting adapter saved to `outPath`. The base model file is
    /// not modified.
    ///
    /// CALLER RESPONSIBILITY: free the LlamaRunner's current model
    /// before calling this — otherwise we'll temporarily have two
    /// model loads in RAM. Restore the inference model after the
    /// completion fires.
    func finetune(modelPath: String,
                  dataPath: String,
                  outAdapterPath: String,
                  epochs: Int,
                  learningRate: Float,
                  loraRank: Int = 8,
                  onProgress: @escaping (Progress) -> Void,
                  completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            guard FileManager.default.fileExists(atPath: dataPath) else {
                DispatchQueue.main.async {
                    completion(.failure(FineTuneError.dataFileMissing(dataPath)))
                }
                return
            }

            // Auto-adapt context length + pad short corpora.
            // The bridge requires tokens.count > n_ctx + 1 to build
            // at least one training sample. Default 2048 ctx fails
            // for typical first-test corpora (~hundreds of tokens),
            // so:
            //   • Estimate token count from byte count (~3 bytes/tok
            //     for English).
            //   • Pick the largest power-of-2 n_ctx that fits 4
            //     training samples worth of tokens, floored at 256.
            //   • If the corpus would still be too small, write a
            //     repeated copy to a temp file and pass that path
            //     to the bridge.
            let (effectiveDataPath, nCtx) = Self.prepareDataset(originalPath: dataPath)

            var opts = llama_swift_finetune_options(
                n_ctx: nCtx,
                n_threads: Int32(max(2, ProcessInfo.processInfo.processorCount - 1)),
                n_batch: min(256, nCtx),
                n_ubatch: min(256, nCtx),
                epochs: Int32(epochs),
                lora_rank: Int32(loraRank),
                lora_alpha: Float(loraRank * 2),         // standard 2× heuristic
                learning_rate: learningRate,
                val_split: 0.1,                          // 10% validation
                target_modules: 0,                       // 0 = use default (attn Q/K/V/O)
                seed: 42,
                flash_attn: false,                       // must be off for training
                n_gpu_layers: 99                         // full GPU
            )
            // Use the (possibly padded) effective path for the bridge.
            let dataPath = effectiveDataPath
            NSLog("[finetune] n_ctx=\(nCtx), data=\(dataPath)")

            // Wrap the logger as a C function pointer. We use a
            // global handler indirection because @convention(c)
            // closures can't capture state.
            LlamaFinetuner.activeProgressCallback = onProgress
            let logger: llama_swift_finetune_log_callback = { msg, _ in
                guard let msg = msg else { return }
                let s = String(cString: msg)
                LlamaFinetuner.activeProgressCallback?(Progress(logLine: s))
                NSLog("[finetune-bridge] %@", s)
            }

            let result = modelPath.withCString { modelCStr in
                dataPath.withCString { dataCStr in
                    outAdapterPath.withCString { outCStr in
                        withUnsafePointer(to: &opts) { optsPtr in
                            llama_swift_run_lora_finetune(
                                modelCStr, dataCStr, outCStr,
                                optsPtr, logger, nil)
                        }
                    }
                }
            }

            LlamaFinetuner.activeProgressCallback = nil

            DispatchQueue.main.async {
                if result == LLAMA_SWIFT_FINETUNE_OK {
                    completion(.success(URL(fileURLWithPath: outAdapterPath)))
                } else {
                    completion(.failure(FineTuneError(code: result)))
                }
            }
        }
    }

    /// Static slot the C-function-pointer logger writes to. Set by
    /// `finetune` before invocation; cleared after.
    fileprivate static var activeProgressCallback: ((Progress) -> Void)?

    /// Pre-process the dataset: pick a sensible n_ctx + pad-by-repeat
    /// when needed so the bridge's "tokens > n_ctx + 1" check passes.
    /// Returns (path-to-use, n_ctx).
    private static func prepareDataset(originalPath: String) -> (String, Int32) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: originalPath)
        let byteCount = (attrs?[.size] as? Int) ?? 0
        // Token estimate: ~3 bytes/token for English text.
        let estTokens = max(64, byteCount / 3)

        // Find largest power-of-2 ctx where we get >= 4 samples.
        // ctx must satisfy: estTokens * pad_factor >= 4 * ctx + 1
        var nCtx: Int32 = 2048
        for candidate: Int32 in [2048, 1024, 512, 256, 128, 64].reversed() {
            if estTokens >= 4 * Int(candidate) + 1 {
                nCtx = candidate
                break
            }
        }
        // If even at ctx=64 we'd have too few samples, force pad.
        let needBytes = (Int(nCtx) + 1) * 3 * 6   // 6× cushion above minimum
        if byteCount >= needBytes {
            return (originalPath, nCtx)
        }

        // Build a padded copy in TMPDIR.
        guard let raw = try? String(contentsOfFile: originalPath, encoding: .utf8),
              !raw.isEmpty else {
            return (originalPath, nCtx)
        }
        let reps = max(1, (needBytes + raw.utf8.count - 1) / raw.utf8.count)
        let padded = String(repeating: raw + "\n", count: reps)
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codebench_finetune_padded.txt")
        try? padded.write(to: tmpURL, atomically: true, encoding: .utf8)
        NSLog("[finetune] padded corpus \(reps)× (\(byteCount) → \(padded.utf8.count) bytes) at \(tmpURL.path)")
        return (tmpURL.path, nCtx)
    }

    func requestStop() {
        // The bridge doesn't currently expose a stop hook. Future
        // work: wire a cancellation flag through the C API.
    }
}
