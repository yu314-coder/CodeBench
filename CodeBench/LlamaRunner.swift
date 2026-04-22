import Foundation
import llama

final class LlamaRunner {
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
        var threads: Int32
        var threadsBatch: Int32
        var gpuLayers: Int32 = 99
        var useMmap: Bool = true
        var useMlock: Bool = false
        var offloadKQV: Bool = true
        var opOffload: Bool = true
        var kvUnified: Bool = false
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
    private let queue = DispatchQueue(label: "ai.offlinai.llama", qos: .userInitiated)

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var config = Config()
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
            Self.logCapture.clear()
            Self.logCapture.captureAll = true

            if !Self.backendInitialized {
                llama_backend_init()
                Self.backendInitialized = true
            }

            var modelParams = llama_model_default_params()
            modelParams.n_gpu_layers = config.gpuLayers
            modelParams.use_mmap = config.useMmap
            modelParams.use_mlock = config.useMlock

            let path = url.path
            print("[llama] Loading model from: \(path)")
            let modelPointer = path.withCString { cPath in
                llama_model_load_from_file(cPath, modelParams)
            }

            guard let modelPointer else {
                let log = Self.logCapture.recentLogText()
                print("[llama] Model load FAILED. Logs:\n\(log)")
                Self.logCapture.captureAll = false
                DispatchQueue.main.async { completion(.failure(LlamaError.modelLoadFailed)) }
                return
            }

            print("[llama] Model loaded OK, creating context (ctx=\(config.contextSize), batch=\(config.batchSize), gpu=\(config.gpuLayers), kv_unified=\(config.kvUnified), offloadKQV=\(config.offloadKQV), opOffload=\(config.opOffload))")

            var ctxParams = llama_context_default_params()
            ctxParams.n_ctx = UInt32(config.contextSize)
            ctxParams.n_batch = UInt32(config.batchSize)
            ctxParams.n_threads = config.threads
            ctxParams.n_threads_batch = config.threadsBatch
            ctxParams.offload_kqv = config.offloadKQV
            ctxParams.op_offload = config.opOffload
            ctxParams.kv_unified = config.kvUnified
            ctxParams.type_k = config.typeK
            ctxParams.type_v = config.typeV

            let contextPointer = llama_init_from_model(modelPointer, ctxParams)
            guard let contextPointer else {
                let log = Self.logCapture.recentLogText()
                print("[llama] Context init FAILED. Logs:\n\(log)")
                Self.logCapture.captureAll = false
                llama_model_free(modelPointer)
                DispatchQueue.main.async { completion(.failure(LlamaError.contextInitFailed)) }
                return
            }
            Self.logCapture.captureAll = false

            self.model = modelPointer
            self.context = contextPointer
            self.vocab = llama_model_get_vocab(modelPointer)
            self.config = config

            DispatchQueue.main.async { completion(.success(())) }
        }
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
                return nil
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
                    return nil
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
