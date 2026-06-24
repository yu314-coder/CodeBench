import Foundation
import llama

final class LlamaRunner: TextGenerator {
    fileprivate final class LlamaLogCapture {
        private var lines: [String] = []
        private let lock = NSLock()
        private let maxLines = 24
        private var lastLevel: ggml_log_level = GGML_LOG_LEVEL_INFO
        var captureAll = false

        func clear() {
            lock.lock()
            lines.removeAll()
            lock.unlock()
        }

        func append(level: ggml_log_level, text: String) {
            let effectiveLevel: ggml_log_level
            if level == GGML_LOG_LEVEL_CONT {
                effectiveLevel = lastLevel
            } else {
                effectiveLevel = level
                lastLevel = level
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let lower = trimmed.lowercased()
            let important = captureAll || effectiveLevel.rawValue >= GGML_LOG_LEVEL_WARN.rawValue || lower.contains("error") || lower.contains("failed") || lower.contains("unsupported") || lower.contains("not supported") || lower.contains("arch")
            guard important else { return }

            lock.lock()
            lines.append(trimmed)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            lock.unlock()
            print("[llama] \(trimmed)")
        }

        func recentLogText() -> String {
            lock.lock()
            let joined = lines.suffix(maxLines).joined(separator: "\n")
            lock.unlock()
            return joined
        }
    }

    private static var logCaptureInstalled = false
    private static let logCapture = LlamaLogCapture()

    private static func installLogCaptureIfNeeded() {
        guard !logCaptureInstalled else { return }
        let logger = Unmanaged.passUnretained(logCapture).toOpaque()
        llama_log_set(offlinai_llama_log_callback, logger)
        logCaptureInstalled = true
    }

    enum LlamaError: LocalizedError {
        case busy
        case notLoaded
        case modelLoadFailed
        /// Same as .modelLoadFailed, but carries the captured tail of
        /// llama.cpp's stderr so callers can surface the actual
        /// reason (unsupported arch, GGUF version mismatch, missing
        /// weights, Metal-shader compile error, etc.) instead of the
        /// useless "Failed to load model." Used by the GPU-offload
        /// retry path: we report the FINAL error along with the
        /// log of the LAST attempt so the user sees exactly why CPU
        /// fallback also failed (when it does).
        case modelLoadFailedDetail(String)
        /// Architecture pre-check rejected the model BEFORE handing
        /// it to llama.cpp. Some GGUFs map to llama-architectures
        /// that the bundled libllama can technically parse but will
        /// NULL-deref or hang during inference on iOS Metal — best
        /// caught early by sniffing the GGUF header.
        case unsupportedArchitecture(String)
        case contextInitFailed
        case tokenizationFailed
        case promptTooLong
        case noRoomForGeneration
        case decodeFailed
        case generationFailed
        case invalidTemplate

        var errorDescription: String? {
            switch self {
            case .busy:
                return "Model is busy."
            case .notLoaded:
                return "Model not loaded."
            case .modelLoadFailed:
                return "Failed to load model."
            case .modelLoadFailedDetail(let detail):
                return "Failed to load model: \(detail)"
            case .unsupportedArchitecture(let arch):
                return "Unsupported architecture '\(arch)' on iOS Metal — try a different model."
            case .contextInitFailed:
                return "Failed to initialize context."
            case .tokenizationFailed:
                return "Failed to tokenize prompt."
            case .promptTooLong:
                return "Prompt exceeds context length."
            case .noRoomForGeneration:
                return "No room left in context for generation."
            case .decodeFailed:
                return "Failed to decode tokens."
            case .generationFailed:
                return "Token generation failed."
            case .invalidTemplate:
                return "Chat template is invalid."
            }
        }
    }

    struct Config {
        var contextSize: Int32 = 4096
        var batchSize: Int32 = 256
        var ubatchSize: Int32 = 0    // 0 = use llama default (typically = batchSize)
        var seqMax: UInt32 = 0       // 0 = use llama default; 1 forces single-sequence mode
        var threads: Int32
        var threadsBatch: Int32
        var gpuLayers: Int32 = 99
        var useMmap: Bool = true
        var useMlock: Bool = false
        var offloadKQV: Bool = true
        var opOffload: Bool = true
        var kvUnified: Bool = false
        var flashAttn: Bool = true     // default: let llama auto-enable; training disables
        var typeK: ggml_type = GGML_TYPE_F16
        var typeV: ggml_type = GGML_TYPE_F16
        var temperature: Float = 0.7
        var topP: Float = 0.9
        var topK: Int32 = 50
        var seed: UInt32 = 0
        var repeatLastN: Int32 = 64
        var repeatPenalty: Float = 1.10
        var frequencyPenalty: Float = 0.0
        var presencePenalty: Float = 0.0

        init(contextSize: Int32 = 4096, batchSize: Int32 = 256, threads: Int32? = nil, gpuLayers: Int32 = 99, offloadKQV: Bool = true, opOffload: Bool = true, kvUnified: Bool = false, typeK: ggml_type = GGML_TYPE_F16, typeV: ggml_type = GGML_TYPE_F16, temperature: Float = 0.7, topP: Float = 0.9, topK: Int32 = 50, seed: UInt32 = 0, repeatLastN: Int32 = 64, repeatPenalty: Float = 1.10, frequencyPenalty: Float = 0.0, presencePenalty: Float = 0.0) {
            let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let threadCount = threads ?? Int32(max(1, coreCount - 1))
            self.contextSize = contextSize
            self.batchSize = min(batchSize, contextSize)
            self.threads = threadCount
            self.threadsBatch = threadCount
            self.gpuLayers = gpuLayers
            self.offloadKQV = offloadKQV
            self.opOffload = opOffload
            self.kvUnified = kvUnified
            self.typeK = typeK
            self.typeV = typeV
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.seed = seed
            self.repeatLastN = repeatLastN
            self.repeatPenalty = repeatPenalty
            self.frequencyPenalty = frequencyPenalty
            self.presencePenalty = presencePenalty
        }
    }

    private static var backendInitialized = false
    private let queue = DispatchQueue(label: "ai.codebench.llama", qos: .userInitiated)

    private var model: OpaquePointer?
    private var context: OpaquePointer?

    /// Exposed for `LlamaFinetuner` so the on-device fine-tune path
    /// can reuse the same loaded weights + context. Strictly internal —
    /// don't share these pointers across threads without taking the
    /// runner's serial queue.
    var loadedModelPointer: OpaquePointer? { model }
    var loadedContextPointer: OpaquePointer? { context }

    /// Saved-while-training so we can restore inference mode.
    private var savedInferencePath: URL?
    private var savedInferenceConfig: Config?

    /// Currently-attached LoRA adapters and their scales. Tracked here
    /// because llama.cpp's `llama_set_adapters_lora` is a SET operation
    /// (replaces the full list), so to add or remove a single adapter
    /// we have to re-submit the whole list. Indexed by the adapter's
    /// OpaquePointer (which is what callers hold onto for detach).
    private var activeLoraAdapters: [OpaquePointer: Float] = [:]

    /// Re-submit the current adapter set to llama_set_adapters_lora.
    /// Must run on `queue`.
    private func _reapplyActiveAdapters(ctx: OpaquePointer) -> Int32 {
        if activeLoraAdapters.isEmpty {
            // Clear all adapters from the context.
            return llama_set_adapters_lora(ctx, nil, 0, nil)
        }
        let pairs = Array(activeLoraAdapters)
        var ptrs: [OpaquePointer?] = pairs.map { $0.key }
        var scales: [Float] = pairs.map { $0.value }
        return ptrs.withUnsafeMutableBufferPointer { pbuf in
            scales.withUnsafeMutableBufferPointer { sbuf in
                llama_set_adapters_lora(ctx, pbuf.baseAddress, pairs.count, sbuf.baseAddress)
            }
        }
    }

    /// Attach a LoRA adapter to the currently-loaded inference
    /// context. The adapter file is a `.gguf` produced by our LoRA
    /// finetune pipeline. Multiple adapters can be active at once
    /// with different scales (e.g. blend two personalities).
    ///
    /// Returns the adapter pointer so the caller can later detach
    /// it via `detachLoraAdapter`. nil = load/apply failed.
    @discardableResult
    func applyLoraAdapter(path: String, scale: Float = 1.0) -> OpaquePointer? {
        return queue.sync { () -> OpaquePointer? in
            guard let model = self.model, let ctx = self.context else {
                NSLog("[llama] applyLoraAdapter: no model loaded")
                return nil
            }
            let adapter: OpaquePointer? = path.withCString { cstr in
                llama_adapter_lora_init(model, cstr)
            }
            guard let adapter else {
                NSLog("[llama] applyLoraAdapter: init failed for \(path)")
                return nil
            }
            // Add to the active set and submit the new list to the ctx.
            self.activeLoraAdapters[adapter] = scale
            let rc = self._reapplyActiveAdapters(ctx: ctx)
            if rc != 0 {
                NSLog("[llama] applyLoraAdapter: set failed rc=\(rc)")
                self.activeLoraAdapters.removeValue(forKey: adapter)
                llama_adapter_lora_free(adapter)
                return nil
            }
            print("[llama] LoRA adapter applied — \(path) (scale=\(scale))")
            return adapter
        }
    }

    /// Detach a previously-attached LoRA adapter.
    func detachLoraAdapter(_ adapter: OpaquePointer) {
        queue.sync {
            activeLoraAdapters.removeValue(forKey: adapter)
            if let ctx = self.context {
                // Replace the context's adapter list with whatever is
                // still active. If nothing remains, this clears it.
                _ = self._reapplyActiveAdapters(ctx: ctx)
            }
            llama_adapter_lora_free(adapter)
        }
    }

    /// Free the current model + context. Used by LlamaFinetuner
    /// before invoking QVAC's bridge (which loads its own model
    /// internally and would OOM if ours stayed alive too).
    /// Pair with `restoreInferenceMode` to bring back inference.
    func unloadModel() {
        queue.sync { [weak self] in
            guard let self else { return }
            // Record what we need to bring back. We can't recover
            // the inference path/config from the freed model, so
            // pull from UserDefaults.
            if let mruPath = UserDefaults.standard.string(forKey: "model.mru.path") {
                self.savedInferencePath = URL(fileURLWithPath: mruPath)
                self.savedInferenceConfig = Config()
            }
            if let ctx = self.context { llama_free(ctx); self.context = nil }
            if let mdl = self.model   { llama_model_free(mdl); self.model = nil }
        }
    }

    /// Reload the currently-loaded model in training-mode: weights
    /// in writable memory (use_mmap=false), F32 KV cache. The
    /// llama.cpp backward-pass builder asserts on view-ops over
    /// F16 KV cache and on mmap'd read-only params; both must
    /// flip together. Returns nil on failure.
    ///
    /// Memory cost: temporarily peaks at ~2× model size during the
    /// swap (old model still alive while new one allocates).
    func reloadForTraining(modelURL: URL, config: Config,
                           completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            // Save what we need to restore inference mode later.
            self.savedInferencePath = modelURL
            self.savedInferenceConfig = config

            // Free current state (model + context).
            if let ctx = self.context { llama_free(ctx); self.context = nil }
            if let mdl = self.model   { llama_model_free(mdl); self.model = nil }

            // Training config: writable params + F32 KV cache + GPU.
            // Now that the bundled llama.framework includes QVAC's
            // Metal backward kernels (OUT_PROD, RMS_NORM_BACK,
            // SILU_BACK, SOFT_MAX_BACK), training runs on the GPU.
            // ROPE_BACK is handled by the existing kernel_rope with
            // is_backward flag. OPT_STEP_ADAM still falls back to
            // CPU for the optimizer step but per-batch math is GPU.
            var trainCfg = config
            trainCfg.useMmap = false
            trainCfg.typeK = GGML_TYPE_F32
            trainCfg.typeV = GGML_TYPE_F32
            trainCfg.kvUnified = false
            trainCfg.offloadKQV = false
            // Flash attention emits fused non-standard view nodes
            // that `ggml_build_backward_expand` can't differentiate
            // (its rule: a view tensor must be one of
            // CPY/VIEW/RESHAPE/PERMUTE/TRANSPOSE — flash-attn
            // produces tensors of op FLASH_ATTN_EXT with view_src
            // set, violating that). Force-disable for training.
            trainCfg.flashAttn = false
            // gpuLayers kept at the inference default — Metal backward
            // kernels are present in this build.

            print("[llama] Reloading for TRAINING — use_mmap=false, "
                  + "KV cache=F32, flash_attn=disabled, Metal backward "
                  + "kernels active")
            guard let m = self.attemptLoad(url: modelURL, config: trainCfg) else {
                DispatchQueue.main.async {
                    completion(.failure(LlamaError.modelLoadFailedDetail(
                        "training-mode model reload failed — out of memory?")))
                }
                return
            }
            self.finishLoadOrFreeAndFail(model: m, config: trainCfg, completion: completion)
        }
    }

    /// Restore the model to inference mode after a training session
    /// completes. Reloads with the original (mmap'd, F16 cache)
    /// settings the user originally used.
    func restoreInferenceMode(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let url = self.savedInferencePath,
                  let cfg = self.savedInferenceConfig else {
                DispatchQueue.main.async {
                    completion(.failure(LlamaError.modelLoadFailedDetail(
                        "no saved inference config — was training even started?")))
                }
                return
            }
            if let ctx = self.context { llama_free(ctx); self.context = nil }
            if let mdl = self.model   { llama_model_free(mdl); self.model = nil }
            print("[llama] Restoring inference mode from saved config")
            guard let m = self.attemptLoad(url: url, config: cfg) else {
                DispatchQueue.main.async {
                    completion(.failure(LlamaError.modelLoadFailedDetail(
                        "inference-mode reload failed — model file may be gone")))
                }
                return
            }
            self.finishLoadOrFreeAndFail(model: m, config: cfg, completion: completion)
        }
    }
    private var vocab: OpaquePointer?
    private var config = Config()

    /// Live-update the sampling temperature. The sampler chain is rebuilt from
    /// `config.temperature` at the start of each generation, so this takes
    /// effect on the next `generate(...)` without reloading the model.
    func setTemperature(_ t: Float) {
        config.temperature = max(0, t)
    }

    /// The context window (n_ctx) the currently-loaded model was created with.
    /// Exposed so callers (e.g. the editor's AI chat) can budget their prompt
    /// and never trip `promptTooLong` on a short message.
    var loadedContextSize: Int32 { config.contextSize }
    private var isBusy = false
    private var cancelled = false

    // MARK: - Generation Stats

    struct GenerationStats {
        var promptTokenCount: Int = 0
        var generatedTokenCount: Int = 0
        var startTime: Date?

        var tokensPerSecond: Double {
            guard let start = startTime, generatedTokenCount > 0 else { return 0 }
            let elapsed = Date().timeIntervalSince(start)
            return elapsed > 0 ? Double(generatedTokenCount) / elapsed : 0
        }

        var elapsedTime: TimeInterval {
            guard let start = startTime else { return 0 }
            return Date().timeIntervalSince(start)
        }

        mutating func reset() {
            promptTokenCount = 0
            generatedTokenCount = 0
            startTime = nil
        }
    }

    private(set) var currentStats = GenerationStats()

    func cancelGeneration() {
        cancelled = true
    }

    deinit {
        unload()
    }

    var lastLogExcerpt: String {
        Self.logCapture.recentLogText()
    }

    func loadModel(at url: URL, config: Config, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }

            if self.isBusy {
                DispatchQueue.main.async { completion(.failure(LlamaError.busy)) }
                return
            }
            self.isBusy = true

            defer { self.isBusy = false }
            self.unloadLocked()
            Self.installLogCaptureIfNeeded()

            // Pre-flight: sniff the GGUF header so we can pick the
            // right context-init params for hybrid SSM architectures
            // BEFORE handing them to llama.cpp.
            //
            // Qwen 3.5 / Qwen3-Next (arch tag = "qwen35" / "qwen3next")
            // ship a Gated DeltaNet recurrent state cache that's sized
            // by `n_seq_max * recurrent_layers * d_state * d_inner` of
            // contiguous Metal memory. With the llama.cpp default
            // n_seq_max (typically 4-8) the cache exceeds 500 MB —
            // larger than iOS's typical contiguous Metal allocation
            // ceiling under sandbox + jetsam. posix_memalign fails →
            // SIGKILL.
            //
            // The fix is NOT to refuse the model (the user wants it)
            // and NOT to force CPU (much slower). It's to set
            // n_seq_max=1, smaller batch/ubatch, and disable the
            // unified KV pool. The recurrent cache then shrinks
            // linearly to ~80-130 MB which posix_memalign satisfies
            // even on 8 GB devices.
            //
            // Source: github.com/ggml-org/llama.cpp issue #3069 and
            // discussion #22064 — same workaround used for Qwen3-Next
            // 80B on memory-constrained Macs. CPU fallback below
            // remains as a safety net if even tight Metal fails.
            var effectiveConfig = config
            if let arch = Self.sniffGGUFArchitecture(at: url) {
                print("[llama] Pre-check: GGUF arch=\(arch)")
                if Self.ssmHybridArchitectures.contains(arch) {
                    print("[llama] Arch '\(arch)' is hybrid SSM — applying tight Metal config")
                    // n_seq_max=1 shrinks the recurrent state cache
                    // linearly. Default is 4-8 sequences which gives
                    // a 500+ MB allocation iOS can't satisfy.
                    effectiveConfig.seqMax = 1
                    // ALSO reduce contextSize from 4096 → 2048 for
                    // SSM models. The recurrent state ring-buffer
                    // scales with ctx, and iOS's Metal heap can't
                    // fit the full 4K version even with n_seq_max=1.
                    // 2048 still covers any reasonable code-edit
                    // task and keeps the Metal alloc inside iOS's
                    // contiguous-buffer ceiling.
                    effectiveConfig.contextSize = min(effectiveConfig.contextSize, 2048)
                    // Aggressive batch+ubatch reduction. Default batch
                    // is 512; that's the cliff that triggered the
                    // 515 MB graph_reserve allocation in the user's
                    // log. 128/32 is ~16× smaller than 512/512.
                    effectiveConfig.batchSize = min(effectiveConfig.batchSize, 128)
                    effectiveConfig.ubatchSize = 32
                    // Force kv_unified off — the unified pool inflates
                    // recurrent-state allocation for hybrid models.
                    effectiveConfig.kvUnified = false
                    // Off-load KQV is fine on regular models but
                    // doubles SSM allocation pressure. Keep KQV on
                    // CPU; the recurrent kernels themselves stay on
                    // Metal where they belong.
                    effectiveConfig.offloadKQV = false
                }
                if Self.fullyIncompatibleArchitectures.contains(arch) {
                    print("[llama] Refusing arch '\(arch)' — fully incompatible on iOS")
                    DispatchQueue.main.async {
                        completion(.failure(LlamaError.unsupportedArchitecture(arch)))
                    }
                    return
                }
            }

            // First attempt: with whatever GPU offload the caller asked
            // for (or CPU-only if the arch pre-check forced it down).
            if let model = self.attemptLoad(url: url, config: effectiveConfig) {
                self.finishLoadOrFreeAndFail(model: model, config: effectiveConfig,
                                              completion: completion)
                return
            }

            // GPU-offload load failed. Capture the log of THAT attempt
            // before retrying — if the CPU retry also fails we want
            // the GPU log too, since CPU rarely fails.
            let gpuLog = Self.logCapture.recentLogText()
            print("[llama] GPU load failed. Tail of llama.cpp log:\n\(gpuLog)")

            // CPU fallback — only worth trying if the first attempt
            // had GPU offload enabled (and the arch pre-check didn't
            // already force CPU above). Some models (older arch
            // GGUFs, formats Metal lacks shaders for) work fine on
            // CPU. Retry once with gpuLayers=0; the rest of the
            // config is preserved.
            if effectiveConfig.gpuLayers > 0 {
                print("[llama] Retrying with CPU only (gpuLayers=0)…")
                var cpuConfig = effectiveConfig
                cpuConfig.gpuLayers = 0
                cpuConfig.offloadKQV = false
                cpuConfig.opOffload = false
                if let model = self.attemptLoad(url: url, config: cpuConfig) {
                    print("[llama] CPU fallback succeeded — Metal incompatible for this GGUF")
                    self.finishLoadOrFreeAndFail(model: model, config: cpuConfig,
                                                  completion: completion)
                    return
                }
            }

            // Both attempts failed (or only CPU was tried). Surface
            // the captured log to the caller via .modelLoadFailedDetail
            // so the AIEngine layer can write a meaningful message
            // into ai_model_done.txt and the Python side prints it.
            let cpuLog = Self.logCapture.recentLogText()
            // Pick whichever log is longer / more informative.
            let detail = (cpuLog.count > gpuLog.count ? cpuLog : gpuLog)
                .split(separator: "\n").suffix(20).joined(separator: "\n")
            DispatchQueue.main.async {
                completion(.failure(LlamaError.modelLoadFailedDetail(
                    detail.isEmpty ? "<no log captured>" : detail)))
            }
        }
    }

    /// Single load attempt: configure params, call into libllama,
    /// return the model pointer or nil. Side-effect: clears + arms
    /// the log capture before each call so the caller sees only
    /// THIS attempt's log when reading recentLogText().
    private func attemptLoad(url: URL, config: Config) -> OpaquePointer? {
        Self.logCapture.clear()
        Self.logCapture.captureAll = true
        defer { Self.logCapture.captureAll = false }

        if !Self.backendInitialized {
            llama_backend_init()
            Self.backendInitialized = true
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = config.gpuLayers
        modelParams.use_mmap = config.useMmap
        modelParams.use_mlock = config.useMlock

        let path = url.path
        print("[llama] Load attempt: gpu=\(config.gpuLayers) mmap=\(config.useMmap) path=\(path)")
        return path.withCString { cPath in
            llama_model_load_from_file(cPath, modelParams)
        }
    }

    /// Common path after a successful model load — try to init the
    /// context, free the model and fail if context init fails.
    /// Returns success via the completion callback.
    private func finishLoadOrFreeAndFail(model: OpaquePointer, config: Config,
                                          completion: @escaping (Result<Void, Error>) -> Void) {
        print("[llama] Model loaded OK, creating context (ctx=\(config.contextSize), batch=\(config.batchSize), gpu=\(config.gpuLayers), kv_unified=\(config.kvUnified), offloadKQV=\(config.offloadKQV), opOffload=\(config.opOffload))")

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(config.contextSize)
        ctxParams.n_batch = UInt32(config.batchSize)
        // Hybrid SSM models (Qwen3-Next / qwen35) allocate the
        // recurrent-state cache as `n_seq_max * recurrent_layers *
        // d_state * d_inner` of contiguous Metal memory. The default
        // n_seq_max can be 4-8 depending on the build, which inflates
        // the cache to 500 MB+ — exactly the allocation that
        // posix_memalign on iOS Metal can't satisfy. Setting
        // n_seq_max=1 shrinks it linearly and lets the model load.
        // Same applies to ubatch — keep it small for SSM models.
        if config.seqMax > 0 {
            ctxParams.n_seq_max = config.seqMax
        }
        if config.ubatchSize > 0 {
            ctxParams.n_ubatch = UInt32(config.ubatchSize)
        }
        ctxParams.n_threads = config.threads
        ctxParams.n_threads_batch = config.threadsBatch
        ctxParams.offload_kqv = config.offloadKQV
        ctxParams.op_offload = config.opOffload
        ctxParams.kv_unified = config.kvUnified
        // Flash attention: explicit AUTO (lets llama enable when
        // supported) for inference; explicitly DISABLED for training
        // because the fused FLASH_ATTN_EXT op emits view nodes that
        // ggml_build_backward_expand can't differentiate.
        ctxParams.flash_attn_type = config.flashAttn
            ? LLAMA_FLASH_ATTN_TYPE_AUTO
            : LLAMA_FLASH_ATTN_TYPE_DISABLED
        ctxParams.type_k = config.typeK
        ctxParams.type_v = config.typeV

        Self.logCapture.clear()
        Self.logCapture.captureAll = true
        let contextPointer = llama_init_from_model(model, ctxParams)
        Self.logCapture.captureAll = false

        guard let contextPointer else {
            let log = Self.logCapture.recentLogText()
            print("[llama] Context init FAILED. Logs:\n\(log)")
            llama_model_free(model)
            let detail = log.split(separator: "\n").suffix(20).joined(separator: "\n")
            DispatchQueue.main.async {
                completion(.failure(LlamaError.modelLoadFailedDetail(
                    "context init failed — \(detail)")))
            }
            return
        }

        self.model = model
        self.context = contextPointer
        self.vocab = llama_model_get_vocab(model)
        self.config = config

        DispatchQueue.main.async { completion(.success(())) }
    }

    /// Architectures with hybrid SSM/recurrent state kernels. They
    /// allocate the recurrent-state cache as a single contiguous
    /// Metal buffer sized by `n_seq_max * recurrent_layers * d_state
    /// * d_inner`. With llama.cpp's default n_seq_max (4-8) this
    /// exceeds 500 MB — beyond what iOS's sandboxed contiguous
    /// allocation can satisfy under jetsam pressure.
    ///
    /// Pre-check downshifts these to a tight context-init config
    /// (n_seq_max=1, smaller batch, kv_unified=false) so the cache
    /// fits in iOS's heap. Metal stays enabled — the throughput is
    /// dramatically faster than CPU for these models.
    ///
    /// Different ggml-converter versions emit different arch strings
    /// for the same architecture; list every variant we've seen.
    /// Source: llama.cpp issue #3069, discussion #22064.
    private static let ssmHybridArchitectures: Set<String> = [
        "qwen3next",
        "qwen35",
        "qwen3.5",
        "qwen3-next",
    ]

    /// Architectures even CPU mode can't load (no kernel exists in
    /// the bundled libllama at all). Empty for now — every model
    /// llama.cpp parses can run on CPU; only Metal-specific issues
    /// land in the metalIncompatibleArchitectures set above.
    private static let fullyIncompatibleArchitectures: Set<String> = []

    /// Read the GGUF magic + version + architecture string from the
    /// file header without invoking llama.cpp. Returns nil if the
    /// file isn't a recognizable GGUF or the architecture key
    /// couldn't be parsed.
    ///
    /// GGUF v3 layout (relevant prefix):
    ///   bytes 0..3   — "GGUF" magic
    ///   bytes 4..7   — uint32 version (3)
    ///   bytes 8..15  — uint64 tensor_count
    ///   bytes 16..23 — uint64 metadata_kv_count
    ///   then a sequence of (key:string, type:uint32, value) entries.
    /// The first metadata entry is conventionally
    /// `general.architecture` whose value is a string. We scan the
    /// first ~4KB of the header looking for the literal sequence
    /// `general.architecture` followed by a string-type marker
    /// (uint32 = 8) and a length-prefixed UTF-8 string.
    private static func sniffGGUFArchitecture(at url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 8192) else { return nil }
        // Magic check — "GGUF" little-endian.
        guard head.count >= 8,
              head[0] == 0x47, head[1] == 0x47,
              head[2] == 0x55, head[3] == 0x46 else {
            return nil
        }

        // Walk the buffer as raw bytes (avoid Data-slice quirks where
        // `withUnsafeBytes` reads from preserved-offset indices and
        // returns garbage). Convert to [UInt8] up front so every load
        // is a normal 0-based array index.
        let bytes = [UInt8](head)
        let key = Array("general.architecture".utf8)
        guard let keyOffset = Self.indexOf(needle: key, in: bytes) else {
            print("[llama] sniffGGUFArch: 'general.architecture' key not found in first \(bytes.count) bytes")
            return nil
        }
        // After the key in GGUF v3 layout: 4 bytes type (=8 for string),
        // then 8 bytes string length (uint64 LE), then UTF-8 bytes.
        let valStart = keyOffset + key.count
        guard valStart + 12 <= bytes.count else { return nil }
        let typeVal = UInt32(bytes[valStart])
                    | (UInt32(bytes[valStart + 1]) << 8)
                    | (UInt32(bytes[valStart + 2]) << 16)
                    | (UInt32(bytes[valStart + 3]) << 24)
        guard typeVal == 8 else {
            print("[llama] sniffGGUFArch: arch value type is \(typeVal), expected 8 (string)")
            return nil
        }
        var strLen: UInt64 = 0
        for i in 0..<8 {
            strLen |= UInt64(bytes[valStart + 4 + i]) << (8 * i)
        }
        guard strLen > 0, strLen < 64,
              valStart + 12 + Int(strLen) <= bytes.count else {
            print("[llama] sniffGGUFArch: arch string length out of range: \(strLen)")
            return nil
        }
        let arch = String(bytes: bytes[valStart + 12..<valStart + 12 + Int(strLen)],
                          encoding: .utf8)
        print("[llama] sniffGGUFArch: \(arch ?? "<decode failed>")")
        return arch
    }

    /// First-occurrence byte search — replacement for Data.range(of:)
    /// that's predictable on Data slices. Returns nil if `needle`
    /// isn't found in `haystack`.
    private static func indexOf(needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let last = haystack.count - needle.count
        for i in 0...last {
            var match = true
            for j in 0..<needle.count {
                if haystack[i + j] != needle[j] { match = false; break }
            }
            if match { return i }
        }
        return nil
    }

    func unload() {
        queue.sync { unloadLocked() }
    }

    private func unloadLocked() {
        if let ctx = context {
            llama_free(ctx)
        }
        if let model = model {
            llama_model_free(model)
        }
        context = nil
        model = nil
        vocab = nil
    }

    func generate(messages: [ChatMessage], maxTokens: Int, grammar: String? = nil, stopSequences: [String] = [], onToken: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }

            if self.isBusy {
                DispatchQueue.main.async { completion(.failure(LlamaError.busy)) }
                return
            }
            self.isBusy = true
            self.cancelled = false
            self.currentStats.reset()

            defer { self.isBusy = false }

            guard let ctx = self.context, let vocab = self.vocab, let model = self.model else {
                DispatchQueue.main.async { completion(.failure(LlamaError.notLoaded)) }
                return
            }

            llama_memory_clear(llama_get_memory(ctx), false)

            guard let prompt = self.applyTemplate(messages: messages, model: model) else {
                DispatchQueue.main.async { completion(.failure(LlamaError.invalidTemplate)) }
                return
            }

            let tokenization = self.tokenize(prompt: prompt, vocab: vocab)
            guard let promptTokens = tokenization.tokens else {
                DispatchQueue.main.async { completion(.failure(tokenization.error ?? LlamaError.tokenizationFailed)) }
                return
            }

            self.currentStats.promptTokenCount = promptTokens.count

            if promptTokens.count >= Int(self.config.contextSize) {
                DispatchQueue.main.async { completion(.failure(LlamaError.promptTooLong)) }
                return
            }

            var output = ""
            let normalizedStops = stopSequences.filter { !$0.isEmpty }

            let nBatch = Int(self.config.batchSize)
            let totalTokens = promptTokens.count
            let availableTokens = max(0, Int(self.config.contextSize) - totalTokens - 1)
            let maxGenTokens = min(maxTokens, availableTokens)
            if maxGenTokens <= 0 {
                DispatchQueue.main.async { completion(.failure(LlamaError.noRoomForGeneration)) }
                return
            }
            var nPast = 0
            var lastLogitsIndex = 0

            guard let sampler = self.buildSampler(grammar: grammar, vocab: vocab) else {
                DispatchQueue.main.async { completion(.failure(LlamaError.generationFailed)) }
                return
            }
            defer { llama_sampler_free(sampler) }

            var batch = llama_batch_init(Int32(nBatch), 0, 1)
            defer { llama_batch_free(batch) }

            while nPast < totalTokens {
                let chunkCount = min(nBatch, totalTokens - nPast)
                batch.n_tokens = Int32(chunkCount)

                for i in 0..<chunkCount {
                    batch.token[i] = promptTokens[nPast + i]
                    batch.pos[i] = Int32(nPast + i)
                    batch.n_seq_id[i] = 1
                    batch.seq_id[i]![0] = 0
                    batch.logits[i] = 0
                }
                batch.logits[chunkCount - 1] = 1
                lastLogitsIndex = chunkCount - 1

                let decodeStatus = llama_decode(ctx, batch)
                if decodeStatus != 0 {
                    print("[llama] Prompt decode failed at pos \(nPast) with status \(decodeStatus)")
                    DispatchQueue.main.async { completion(.failure(LlamaError.decodeFailed)) }
                    return
                }

                nPast += chunkCount
            }

            self.currentStats.startTime = Date()

            // Reusable single-token batch for generation loop
            var genBatch = llama_batch_init(1, 0, 1)
            defer { llama_batch_free(genBatch) }

            var generated = 0
            while generated < maxGenTokens {
                if self.cancelled { break }
                let nextToken = llama_sampler_sample(sampler, ctx, Int32(lastLogitsIndex))
                if nextToken == llama_vocab_eos(vocab) {
                    break
                }

                var stopTriggered = false
                if let piece = self.tokenToPiece(token: nextToken, vocab: vocab) {
                    output.append(piece)
                    self.currentStats.generatedTokenCount += 1
                    DispatchQueue.main.async { onToken(piece) }
                    if !normalizedStops.isEmpty && self.outputHasStopSuffix(output, stops: normalizedStops) {
                        stopTriggered = true
                    }
                }

                if stopTriggered {
                    break
                }

                genBatch.n_tokens = 1
                genBatch.token[0] = nextToken
                genBatch.pos[0] = Int32(nPast)
                genBatch.n_seq_id[0] = 1
                genBatch.seq_id[0]![0] = 0
                genBatch.logits[0] = 1

                let decodeStatus = llama_decode(ctx, genBatch)
                if decodeStatus != 0 {
                    print("[llama] Token decode failed at pos \(nPast), generated \(generated) tokens, status \(decodeStatus)")
                    // For recurrent/hybrid models, decode can fail if state is corrupted — return what we have
                    if !output.isEmpty {
                        DispatchQueue.main.async { completion(.success(output)) }
                    } else {
                        DispatchQueue.main.async { completion(.failure(LlamaError.decodeFailed)) }
                    }
                    return
                }

                nPast += 1
                lastLogitsIndex = 0
                generated += 1
            }

            DispatchQueue.main.async { completion(.success(output)) }
        }
    }

    private func outputHasStopSuffix(_ output: String, stops: [String]) -> Bool {
        for stop in stops {
            if output.hasSuffix(stop) {
                return true
            }
        }
        return false
    }

    private func tokenize(prompt: String, vocab: OpaquePointer) -> (tokens: [llama_token]?, error: Error?) {
        let utf8Count = prompt.utf8.count
        let initialCount = max(utf8Count + 16, 256)

        var tokens = [llama_token](repeating: 0, count: initialCount)
        let tokenCount = prompt.withCString { cString in
            llama_tokenize(vocab, cString, Int32(utf8Count), &tokens, Int32(tokens.count), true, true)
        }

        if tokenCount == Int32.min {
            return (nil, LlamaError.tokenizationFailed)
        }

        if tokenCount < 0 {
            let needed = Int(-tokenCount)
            tokens = [llama_token](repeating: 0, count: needed)
            let retryCount = prompt.withCString { cString in
                llama_tokenize(vocab, cString, Int32(utf8Count), &tokens, Int32(tokens.count), true, true)
            }
            if retryCount < 0 {
                return (nil, LlamaError.tokenizationFailed)
            }
            return (Array(tokens.prefix(Int(retryCount))), nil)
        }

        return (Array(tokens.prefix(Int(tokenCount))), nil)
    }

    private func applyTemplate(messages: [ChatMessage], model: OpaquePointer) -> String? {
        let templatePointer = llama_model_chat_template(model, nil)

        var cMessages: [llama_chat_message] = []
        cMessages.reserveCapacity(messages.count)

        var allocated: [UnsafeMutablePointer<CChar>] = []
        allocated.reserveCapacity(messages.count * 2)

        for message in messages {
            let rolePtr = message.role.rawValue.withCString { strdup($0) }
            let contentPtr = message.content.withCString { strdup($0) }
            if let rolePtr, let contentPtr {
                allocated.append(rolePtr)
                allocated.append(contentPtr)
                cMessages.append(llama_chat_message(role: rolePtr, content: contentPtr))
            }
        }

        defer {
            for ptr in allocated {
                free(ptr)
            }
        }

        if cMessages.isEmpty {
            return nil
        }

        if let templatePointer {
            var bufferSize = max(256, messages.reduce(0) { $0 + $1.content.utf8.count * 2 })
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let required = cMessages.withUnsafeBufferPointer { chatPtr in
                buffer.withUnsafeMutableBufferPointer { bufPtr in
                    llama_chat_apply_template(templatePointer, chatPtr.baseAddress, chatPtr.count, true, bufPtr.baseAddress, Int32(bufPtr.count))
                }
            }
            if required < 0 {
                // The model HAS a template but llama.cpp can't parse it
                // (jinja2 features the bundled libllama doesn't support,
                // mismatched roles, missing tools/functions support,
                // etc.). Was: return nil → caller raises
                // .invalidTemplate → user sees "chat template invalid"
                // every turn forever, even though the model could
                // happily chat with a generic User/Assistant format.
                // Now: fall through to fallbackPrompt — output quality
                // is slightly degraded vs the model's native template
                // but it actually WORKS.
                print("[llama] template apply failed (rc=\(required)); using fallback prompt")
                return fallbackPrompt(messages: messages)
            }
            var usedLength = Int(required)
            if required > Int32(buffer.count) {
                bufferSize = Int(required)
                buffer = [CChar](repeating: 0, count: bufferSize)
                let retry = cMessages.withUnsafeBufferPointer { chatPtr in
                    buffer.withUnsafeMutableBufferPointer { bufPtr in
                        llama_chat_apply_template(templatePointer, chatPtr.baseAddress, chatPtr.count, true, bufPtr.baseAddress, Int32(bufPtr.count))
                    }
                }
                if retry < 0 {
                    print("[llama] template re-apply failed (rc=\(retry)); using fallback prompt")
                    return fallbackPrompt(messages: messages)
                }
                usedLength = Int(retry)
            }
            let bytes = buffer.prefix(max(0, usedLength)).map { UInt8(bitPattern: $0) }
            return String(bytes: bytes, encoding: .utf8)
        }

        return fallbackPrompt(messages: messages)
    }

    private func fallbackPrompt(messages: [ChatMessage]) -> String {
        var prompt = ""
        for message in messages {
            switch message.role {
            case .system:
                prompt += "System: \(message.content)\n"
            case .user:
                prompt += "User: \(message.content)\n"
            case .assistant:
                prompt += "Assistant: \(message.content)\n"
            }
        }
        prompt += "Assistant:"
        return prompt
    }

    private func sampleGreedy(logits: UnsafeMutablePointer<Float>, vocabSize: Int) -> llama_token {
        var maxLogit = -Float.greatestFiniteMagnitude
        var maxToken: llama_token = 0
        for i in 0..<vocabSize {
            let value = logits[i]
            if value > maxLogit {
                maxLogit = value
                maxToken = llama_token(i)
            }
        }
        return maxToken
    }

    private func buildSampler(grammar: String?, vocab: OpaquePointer) -> UnsafeMutablePointer<llama_sampler>? {
        let params = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(params) else {
            return nil
        }

        if let grammar, !grammar.isEmpty {
            let grammarSampler = grammar.withCString { grammarStr in
                let pattern = "(\\{)"
                return pattern.withCString { patternStr in
                    var patterns: [UnsafePointer<CChar>?] = [patternStr]
                    return patterns.withUnsafeMutableBufferPointer { buf in
                        llama_sampler_init_grammar_lazy_patterns(vocab, grammarStr, "root",
                                                                 buf.baseAddress, buf.count,
                                                                 nil, 0)
                    }
                }
            }
            guard let grammarSampler else {
                llama_sampler_free(chain)
                return nil
            }
            llama_sampler_chain_add(chain, grammarSampler)
        }

        if config.temperature > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(config.topK))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(config.topP, 1))
            if config.repeatPenalty > 1.0 || config.frequencyPenalty > 0.0 || config.presencePenalty > 0.0 {
                llama_sampler_chain_add(chain, llama_sampler_init_penalties(config.repeatLastN, config.repeatPenalty, config.frequencyPenalty, config.presencePenalty))
            }
            llama_sampler_chain_add(chain, llama_sampler_init_temp(config.temperature))
        }

        if config.temperature <= 0 {
            if config.repeatPenalty > 1.0 || config.frequencyPenalty > 0.0 || config.presencePenalty > 0.0 {
                llama_sampler_chain_add(chain, llama_sampler_init_penalties(config.repeatLastN, config.repeatPenalty, config.frequencyPenalty, config.presencePenalty))
            }
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            let seed = config.seed == 0 ? UInt32.random(in: 1...UInt32.max - 1) : config.seed
            llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))
        }

        return chain
    }

    private func tokenToPiece(token: llama_token, vocab: OpaquePointer) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length <= 0 {
            return nil
        }
        let count = Int(length)
        if count > buffer.count {
            buffer = [CChar](repeating: 0, count: count)
            let retryLength = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            if retryLength <= 0 {
                return nil
            }
            return decodePiece(buffer: buffer, length: Int(retryLength))
        }
        return decodePiece(buffer: buffer, length: count)
    }

    private func decodePiece(buffer: [CChar], length: Int) -> String {
        let slice = buffer.prefix(length)
        let bytes = slice.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

@_cdecl("offlinai_llama_log_callback")
private func offlinai_llama_log_callback(level: ggml_log_level, text: UnsafePointer<CChar>?, user_data: UnsafeMutableRawPointer?) {
    guard let text, let user_data else { return }
    let message = String(cString: text)
    let logger = Unmanaged<LlamaRunner.LlamaLogCapture>.fromOpaque(user_data).takeUnretainedValue()
    logger.append(level: level, text: message)
}
