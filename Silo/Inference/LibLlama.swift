import Foundation
import llama

enum LlamaError: Error, LocalizedError {
    case couldNotInitializeContext(path: String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .couldNotInitializeContext(let path):
            let name = (path as NSString).lastPathComponent
            #if targetEnvironment(simulator)
            return "Could not load \(name). Large models (e.g. Gemma 4) often fail in the Simulator — use a physical iPhone, or download Ministral/LFM2.5 in Manage Models."
            #else
            return "Could not load \(name). The file may be corrupt or too large for available memory. Try another model in Manage Models."
            #endif
        case .decodeFailed:
            return "Model inference failed while decoding. Try New Chat, or send again."
        }
    }
}

private class ProgressCallbackContext {
    let handler: @Sendable (Float) -> Void
    init(_ handler: @escaping @Sendable (Float) -> Void) { self.handler = handler }
}

func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], _ logits: Bool) {
    batch.token   [Int(batch.n_tokens)] = id
    batch.pos     [Int(batch.n_tokens)] = pos
    batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
    for i in 0..<seq_ids.count {
        batch.seq_id[Int(batch.n_tokens)]![Int(i)] = seq_ids[i]
    }
    batch.logits  [Int(batch.n_tokens)] = logits ? 1 : 0

    batch.n_tokens += 1
}

actor LlamaContext {
    private var model: OpaquePointer
    private var context: OpaquePointer
    private var vocab: OpaquePointer
    private var sampling: UnsafeMutablePointer<llama_sampler>
    private var batch: llama_batch
    private var tokens_list: [llama_token]
    var is_done: Bool = false

    /// This variable is used to store temporarily invalid cchars
    private var temporary_invalid_cchars: [CChar]

    var n_len: Int32
    var n_cur: Int32 = 0

    var n_decode: Int32 = 0

    // Entropy monitoring
    private var entropyWindow: [Float] = []
    private let entropyWindowSize = 10
    var currentEntropy: Float = 0.0
    var averageEntropy: Float = 0.0

    // Prefix cache reuse
    private var previousTokens: [llama_token] = []

    // Reference counting for llama_backend_init/free
    private static var backendRefCount = 0

    private static func retainBackend() {
        if backendRefCount == 0 {
            llama_backend_init()
        }
        backendRefCount += 1
    }

    private static func releaseBackend() {
        backendRefCount -= 1
        if backendRefCount == 0 {
            llama_backend_free()
        }
    }

    init(model: OpaquePointer, context: OpaquePointer) {
        self.model = model
        self.context = context
        self.tokens_list = []
        self.n_len = Int32(llama_n_ctx(context))
        self.batch = llama_batch_init(512, 0, 1)
        self.temporary_invalid_cchars = []
        let sparams = llama_sampler_chain_default_params()
        self.sampling = llama_sampler_chain_init(sparams)
        llama_sampler_chain_add(self.sampling, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(self.sampling, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(self.sampling, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(self.sampling, llama_sampler_init_penalties(64, 1.1, 0.0, 0.0))
        llama_sampler_chain_add(self.sampling, llama_sampler_init_dist(1234))
        vocab = llama_model_get_vocab(model)
    }

    deinit {
        llama_sampler_free(sampling)
        llama_batch_free(batch)
        llama_model_free(model)
        llama_free(context)
        LlamaContext.releaseBackend()
    }

    static func create_context(path: String, contextSize: UInt32 = 2048, onProgress: (@Sendable (Float) -> Void)? = nil) throws -> LlamaContext {
        retainBackend()
        var model_params = llama_model_default_params()

#if targetEnvironment(simulator)
        model_params.n_gpu_layers = 0
        print("Running on simulator, force use n_gpu_layers = 0")
#endif

        if let onProgress {
            let ctx = ProgressCallbackContext(onProgress)
            let rawPtr = Unmanaged.passRetained(ctx).toOpaque()
            model_params.progress_callback_user_data = rawPtr
            model_params.progress_callback = { progress, userData in
                if let userData {
                    let ctx = Unmanaged<ProgressCallbackContext>.fromOpaque(userData).takeUnretainedValue()
                    ctx.handler(progress)
                }
                return true
            }
        }

        let model = llama_model_load_from_file(path, model_params)

        // Release retained progress context
        if let userData = model_params.progress_callback_user_data {
            Unmanaged<ProgressCallbackContext>.fromOpaque(userData).release()
        }

        guard let model else {
            print("Could not load model at \(path)")
            releaseBackend()
            throw LlamaError.couldNotInitializeContext(path: path)
        }

        #if targetEnvironment(simulator)
        let n_threads = max(1, min(4, ProcessInfo.processInfo.processorCount - 2))
        #else
        let n_threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        #endif
        // print("Using \(n_threads) threads")

        var ctx_params = llama_context_default_params()
        #if targetEnvironment(simulator)
        let effectiveContext = min(contextSize, 1536)
        #else
        let effectiveContext = contextSize
        #endif
        ctx_params.n_ctx = effectiveContext
        ctx_params.n_threads       = Int32(n_threads)
        ctx_params.n_threads_batch = Int32(n_threads)
        // Note: KV cache quantization (type_k/type_v = Q8_0) requires flash_attn,
        // which crashes on Gemma 4's mixed SWA architecture. Left as defaults until
        // llama.cpp fixes flash attention for models with varying head dimensions.

        let context = llama_init_from_model(model, ctx_params)
        guard let context else {
            print("Could not load context!")
            llama_model_free(model)
            releaseBackend()
            throw LlamaError.couldNotInitializeContext(path: path)
        }

        return LlamaContext(model: model, context: context)
    }

    func model_info() -> String {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 256)
        result.initialize(repeating: Int8(0), count: 256)
        defer {
            result.deallocate()
        }

        // TODO: this is probably very stupid way to get the string from C

        let nChars = llama_model_desc(model, result, 256)
        let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nChars))

        var SwiftString = ""
        for char in bufferPointer {
            SwiftString.append(Character(UnicodeScalar(UInt8(char))))
        }

        return SwiftString
    }

    func get_n_tokens() -> Int32 {
        return batch.n_tokens;
    }

    func completion_init(text: String) throws {
        is_done = false
        temporary_invalid_cchars = []
        entropyWindow.removeAll()
        tokens_list = tokenize(text: text, add_bos: false, parse_special: true)

        llama_memory_clear(llama_get_memory(context), true)

        let chunkSize = 512
        for chunkStart in stride(from: 0, to: tokens_list.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, tokens_list.count)

            llama_batch_clear(&batch)

            for i in chunkStart..<chunkEnd {
                let isLastToken = (i == tokens_list.count - 1)
                llama_batch_add(&batch, tokens_list[i], Int32(i), [0], isLastToken)
            }

            if llama_decode(context, batch) != 0 {
                print("llama_decode() failed at chunk starting at position \(chunkStart)")
                is_done = true
                throw LlamaError.decodeFailed
            }
        }

        previousTokens = tokens_list
        n_cur = Int32(tokens_list.count)
    }

    private let sinkTokens: Int32 = 4

    /// Compact KV cache when context is nearly full.
    /// Keeps sink tokens (first N) and recent tokens, removes the middle.
    @discardableResult
    func applyContextWindow() -> Bool {
        let n_ctx = Int32(llama_n_ctx(context))
        let usedPositions = n_cur
        guard usedPositions > (n_ctx * 3 / 4) else { return false }

        let keepRecent = n_ctx / 2
        let removeFrom = sinkTokens
        let removeTo = usedPositions - keepRecent
        guard removeTo > removeFrom else { return false }

        let memory = llama_get_memory(context)

        // Remove middle section of KV cache
        llama_memory_seq_rm(memory, 0, removeFrom, removeTo)

        // Shift remaining tokens' positions down
        let shift = removeTo - removeFrom
        llama_memory_seq_add(memory, 0, removeTo, -1, -shift)

        n_cur -= shift

        // Update previousTokens to reflect compacted state
        if previousTokens.count > Int(sinkTokens) + Int(keepRecent) {
            let sinkPart = Array(previousTokens.prefix(Int(sinkTokens)))
            let recentCount = min(Int(keepRecent), previousTokens.count - Int(sinkTokens))
            let recentPart = Array(previousTokens.suffix(recentCount))
            previousTokens = sinkPart + recentPart
        }

        // print("Sliding window: removed \(shift) tokens, n_cur now \(n_cur)")
        return true
    }

    func completion_init_with_cache(text: String) throws {
        is_done = false
        let newTokens = tokenize(text: text, add_bos: false, parse_special: true)
        temporary_invalid_cchars = []
        entropyWindow.removeAll()

        // Apply sliding window if context is getting full
        let n_ctx = Int32(llama_n_ctx(context))
        let projectedUsage = Int32(newTokens.count) + 256
        if projectedUsage > n_ctx {
            applyContextWindow()
        }

        // Find common prefix length between previous and new tokens
        var commonLen = 0
        let maxCommon = min(previousTokens.count, newTokens.count)
        for i in 0..<maxCommon {
            if previousTokens[i] == newTokens[i] {
                commonLen += 1
            } else {
                break
            }
        }

        // print("Prefix cache: \(commonLen) tokens reused out of \(newTokens.count) total (\(previousTokens.count) previous)")

        // Remove KV cache entries after the common prefix
        if commonLen < previousTokens.count {
            let memory = llama_get_memory(context)
            llama_memory_seq_rm(memory, 0, Int32(commonLen), -1)
        }

        // Decode only new tokens after the common prefix (chunked)
        let newStart = commonLen
        if newStart < newTokens.count {
            let chunkSize = 512
            for chunkStart in stride(from: newStart, to: newTokens.count, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, newTokens.count)

                llama_batch_clear(&batch)

                for i in chunkStart..<chunkEnd {
                    let isLastToken = (i == newTokens.count - 1)
                    llama_batch_add(&batch, newTokens[i], Int32(i), [0], isLastToken)
                }

                if llama_decode(context, batch) != 0 {
                    print("llama_decode() failed during cached init at position \(chunkStart)")
                    is_done = true
                    throw LlamaError.decodeFailed
                }
            }
        } else if !newTokens.isEmpty {
            // All tokens cached — still need logits for last token
            llama_batch_clear(&batch)
            llama_batch_add(&batch, newTokens[newTokens.count - 1], Int32(newTokens.count - 1), [0], true)
            if llama_decode(context, batch) != 0 {
                print("llama_decode() failed during logit refresh")
                is_done = true
                throw LlamaError.decodeFailed
            }
        }

        tokens_list = newTokens
        previousTokens = newTokens
        n_cur = Int32(newTokens.count)
    }

    func completion_loop() throws -> String {
        var new_token_id: llama_token = 0

        // Compute entropy from logits before sampling
        let nVocab = llama_vocab_n_tokens(vocab)
        if let logits = llama_get_logits_ith(context, batch.n_tokens - 1) {
            var maxLogit: Float = -Float.infinity
            for i in 0..<Int(nVocab) {
                if logits[i] > maxLogit { maxLogit = logits[i] }
            }
            var sumExp: Float = 0
            for i in 0..<Int(nVocab) {
                sumExp += exp(logits[i] - maxLogit)
            }
            let logSumExp = log(sumExp) + maxLogit
            var entropy: Float = 0
            for i in 0..<Int(nVocab) {
                let p = exp(logits[i] - logSumExp)
                if p > 0 { entropy -= p * log2(p) }
            }
            entropyWindow.append(entropy)
            if entropyWindow.count > entropyWindowSize {
                entropyWindow.removeFirst()
            }
            currentEntropy = entropy
            averageEntropy = entropyWindow.reduce(0, +) / Float(entropyWindow.count)
        }

        new_token_id = llama_sampler_sample(sampling, context, batch.n_tokens - 1)

        if llama_vocab_is_eog(vocab, new_token_id) || n_cur == n_len {
            is_done = true
            let new_token_str = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            return new_token_str
        }

        let new_token_cchars = token_to_piece(token: new_token_id)
        temporary_invalid_cchars.append(contentsOf: new_token_cchars)
        let new_token_str: String
        if let string = String(validatingUTF8: temporary_invalid_cchars + [0]) {
            temporary_invalid_cchars.removeAll()
            new_token_str = string
        } else if (0 ..< temporary_invalid_cchars.count).contains(where: {$0 != 0 && String(validatingUTF8: Array(temporary_invalid_cchars.suffix($0)) + [0]) != nil}) {
            // in this case, at least the suffix of the temporary_invalid_cchars can be interpreted as UTF8 string
            let string = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            new_token_str = string
        } else {
            new_token_str = ""
        }
        // tokens_list.append(new_token_id)

        llama_batch_clear(&batch)
        llama_batch_add(&batch, new_token_id, n_cur, [0], true)

        n_decode += 1
        n_cur    += 1

        if llama_decode(context, batch) != 0 {
            print("failed to evaluate llama!")
            is_done = true
            throw LlamaError.decodeFailed
        }

        return new_token_str
    }

    func bench(pp: Int, tg: Int, pl: Int, nr: Int = 1) -> String {
        var pp_avg: Double = 0
        var tg_avg: Double = 0

        var pp_std: Double = 0
        var tg_std: Double = 0

        for _ in 0..<nr {
            // bench prompt processing

            llama_batch_clear(&batch)

            let n_tokens = pp

            for i in 0..<n_tokens {
                llama_batch_add(&batch, 0, Int32(i), [0], false)
            }
            batch.logits[Int(batch.n_tokens) - 1] = 1 // true

            llama_memory_clear(llama_get_memory(context), false)

            let t_pp_start = DispatchTime.now().uptimeNanoseconds / 1000;

            if llama_decode(context, batch) != 0 {
                print("llama_decode() failed during prompt")
            }
            llama_synchronize(context)

            let t_pp_end = DispatchTime.now().uptimeNanoseconds / 1000;

            // bench text generation

            llama_memory_clear(llama_get_memory(context), false)

            let t_tg_start = DispatchTime.now().uptimeNanoseconds / 1000;

            for i in 0..<tg {
                llama_batch_clear(&batch)

                for j in 0..<pl {
                    llama_batch_add(&batch, 0, Int32(i), [Int32(j)], true)
                }

                if llama_decode(context, batch) != 0 {
                    print("llama_decode() failed during text generation")
                }
                llama_synchronize(context)
            }

            let t_tg_end = DispatchTime.now().uptimeNanoseconds / 1000;

            llama_memory_clear(llama_get_memory(context), false)

            let t_pp = Double(t_pp_end - t_pp_start) / 1000000.0
            let t_tg = Double(t_tg_end - t_tg_start) / 1000000.0

            let speed_pp = Double(pp)    / t_pp
            let speed_tg = Double(pl*tg) / t_tg

            pp_avg += speed_pp
            tg_avg += speed_tg

            pp_std += speed_pp * speed_pp
            tg_std += speed_tg * speed_tg

            print("pp \(speed_pp) t/s, tg \(speed_tg) t/s")
        }

        pp_avg /= Double(nr)
        tg_avg /= Double(nr)

        if nr > 1 {
            pp_std = sqrt(pp_std / Double(nr - 1) - pp_avg * pp_avg * Double(nr) / Double(nr - 1))
            tg_std = sqrt(tg_std / Double(nr - 1) - tg_avg * tg_avg * Double(nr) / Double(nr - 1))
        } else {
            pp_std = 0
            tg_std = 0
        }

        let model_desc     = model_info();
        let model_size     = String(format: "%.2f GiB", Double(llama_model_size(model)) / 1024.0 / 1024.0 / 1024.0);
        let model_n_params = String(format: "%.2f B", Double(llama_model_n_params(model)) / 1e9);
        let backend        = "Metal";
        let pp_avg_str     = String(format: "%.2f", pp_avg);
        let tg_avg_str     = String(format: "%.2f", tg_avg);
        let pp_std_str     = String(format: "%.2f", pp_std);
        let tg_std_str     = String(format: "%.2f", tg_std);

        var result = ""

        result += String("| model | size | params | backend | test | t/s |\n")
        result += String("| --- | --- | --- | --- | --- | --- |\n")
        result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | pp \(pp) | \(pp_avg_str) ± \(pp_std_str) |\n")
        result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | tg \(tg) | \(tg_avg_str) ± \(tg_std_str) |\n")

        return result;
    }

    func apply_chat_template(messages: [(role: String, content: String)], enableThinking: Bool = false) -> String {
        let modelDesc = model_info().lowercased()

        // SmolLM3 has a complex template that llama_chat_apply_template can't parse
        if modelDesc.contains("smollm3") || modelDesc.contains("smol") {
            return apply_smollm3_template(messages: messages, enableThinking: enableThinking)
        }

        // LFM2.5 Thinking model
        if modelDesc.contains("lfm") && modelDesc.contains("think") {
            return apply_chatml_template(messages: messages, thinkingPrefix: true)
        }

        // Ministral / Mistral models
        if modelDesc.contains("ministral") || modelDesc.contains("mistral") {
            return apply_ministral_template(messages: messages)
        }

        // Gemma models
        if modelDesc.contains("gemma") {
            return apply_gemma_template(messages: messages)
        }

        // Default: use llama.cpp's built-in template matching
        var chat: [llama_chat_message] = []
        var cStrings: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []

        for msg in messages {
            let roleStr = strdup(msg.role)!
            let contentStr = strdup(msg.content)!
            cStrings.append((roleStr, contentStr))
            chat.append(llama_chat_message(role: roleStr, content: contentStr))
        }

        defer {
            for (r, c) in cStrings {
                free(r)
                free(c)
            }
        }

        let needed = llama_chat_apply_template(llama_model_chat_template(model, nil), &chat, chat.count, true, nil, 0)

        if needed > 0 {
            let bufSize = Int(needed) + 1
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bufSize)
            buf.initialize(repeating: 0, count: bufSize)
            defer { buf.deallocate() }

            let result = llama_chat_apply_template(llama_model_chat_template(model, nil), &chat, chat.count, true, buf, Int32(bufSize))
            if result > 0 {
                return String(cString: buf)
            }
        }

        // Final fallback: basic ChatML
        return apply_chatml_template(messages: messages, thinkingPrefix: false)
    }

    private func apply_smollm3_template(messages: [(role: String, content: String)], enableThinking: Bool) -> String {
        var result = ""
        let reasoningMode = enableThinking ? "/think" : "/no_think"

        // Build system block with metadata
        result += "<|im_start|>system\n"
        result += "## Metadata\n\n"
        result += "Knowledge Cutoff Date: June 2025\n"

        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMMM yyyy"
        result += "Today Date: \(formatter.string(from: Date()))\n"
        result += "Reasoning Mode: \(reasoningMode)\n\n"

        result += "## Custom Instructions\n\n"

        // Extract system message content if present
        var messageStart = 0
        if let first = messages.first, first.role == "system" {
            result += first.content + "\n\n"
            messageStart = 1
        } else if enableThinking {
            result += "You are a helpful AI assistant named SmolLM, trained by Hugging Face. Your role as an assistant involves thoroughly exploring questions through a systematic thinking process before providing the final precise and accurate solutions. This requires engaging in a comprehensive cycle of analysis, summarizing, exploration, reassessment, reflection, backtracking, and iteration to develop well-considered thinking process. Please structure your response into two main sections: Thought and Solution using the specified format: <think> Thought section </think> Solution section. In the Thought section, detail your reasoning process in steps. Each step should include detailed considerations such as analysing questions, summarizing relevant findings, brainstorming new ideas, verifying the accuracy of the current steps, refining any errors, and revisiting previous steps. In the Solution section, based on various attempts, explorations, and reflections from the Thought section, systematically present the final solution that you deem correct. The Solution section should be logical, accurate, and concise and detail necessary steps needed to reach the conclusion.\n\n"
        } else {
            result += "You are a helpful AI assistant named SmolLM, trained by Hugging Face.\n\n"
        }
        result += "<|im_end|>\n"

        // Append user/assistant messages
        for i in messageStart..<messages.count {
            let msg = messages[i]
            if msg.role == "user" {
                result += "<|im_start|>user\n\(msg.content)<|im_end|>\n"
            } else if msg.role == "assistant" {
                if enableThinking {
                    result += "<|im_start|>assistant\n\(msg.content)<|im_end|>\n"
                } else {
                    result += "<|im_start|>assistant\n<think>\n\n</think>\n\(msg.content)<|im_end|>\n"
                }
            }
        }

        // Generation prompt
        if enableThinking {
            result += "<|im_start|>assistant\n"
        } else {
            result += "<|im_start|>assistant\n<think>\n\n</think>\n"
        }

        return result
    }

    private func apply_ministral_template(messages: [(role: String, content: String)]) -> String {
        var result = ""

        // BOS token
        result += "<s>"

        // System prompt
        var messageStart = 0
        if let first = messages.first, first.role == "system" {
            result += "[SYSTEM_PROMPT]" + first.content + "[/SYSTEM_PROMPT]"
            messageStart = 1
        }

        // User/assistant messages
        for i in messageStart..<messages.count {
            let msg = messages[i]
            if msg.role == "user" {
                result += "[INST]\(msg.content)[/INST]"
            } else if msg.role == "assistant" {
                result += "\(msg.content)</s>"
            }
        }

        return result
    }

    private func apply_gemma_template(messages: [(role: String, content: String)]) -> String {
        var result = ""

        for msg in messages {
            let role = msg.role == "assistant" ? "model" : msg.role
            result += "<|turn>\(role)\n\(msg.content)<turn|>\n"
        }

        result += "<|turn>model\n"
        return result
    }

    private func apply_chatml_template(messages: [(role: String, content: String)], thinkingPrefix: Bool) -> String {
        var result = ""
        for msg in messages {
            result += "<|im_start|>\(msg.role)\n\(msg.content)<|im_end|>\n"
        }
        result += "<|im_start|>assistant\n"
        if thinkingPrefix {
            result += "<think>\n"
        }
        return result
    }

    func countTokens(text: String) -> Int {
        let tokens = tokenize(text: text, add_bos: false, parse_special: true)
        return tokens.count
    }

    func clear() {
        tokens_list.removeAll()
        temporary_invalid_cchars.removeAll()
        previousTokens.removeAll()
        entropyWindow.removeAll()
        llama_memory_clear(llama_get_memory(context), true)
    }

    func clearGenerationState() {
        tokens_list.removeAll()
        temporary_invalid_cchars.removeAll()
        entropyWindow.removeAll()
        previousTokens.removeAll()
        n_cur = 0
        is_done = true
        // Clear KV between turns — re-tokenized assistant text won't match cached tokens.
        llama_memory_clear(llama_get_memory(context), true)
    }

    private func tokenize(text: String, add_bos: Bool, parse_special: Bool = false) -> [llama_token] {
        let utf8Count = text.utf8.count
        let n_tokens = utf8Count + (add_bos ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
        let tokenCount = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(n_tokens), add_bos, parse_special)

        var swiftTokens: [llama_token] = []
        for i in 0..<tokenCount {
            swiftTokens.append(tokens[Int(i)])
        }

        tokens.deallocate()

        return swiftTokens
    }

    /// - note: The result does not contain null-terminator
    private func token_to_piece(token: llama_token) -> [CChar] {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer {
            result.deallocate()
        }
        let nTokens = llama_token_to_piece(vocab, token, result, 8, 0, false)

        if nTokens < 0 {
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
            newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
            defer {
                newResult.deallocate()
            }
            let nNewTokens = llama_token_to_piece(vocab, token, newResult, -nTokens, 0, false)
            let bufferPointer = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }
}
