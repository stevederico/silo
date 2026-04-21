import Foundation

actor LlamaCppEngine: InferenceEngine {
    private var llamaContext: LlamaContext?
    var isComplete: Bool = true

    init() {}

    func initialize(modelPath: String, contextSize: UInt32, onProgress: (@Sendable (Float) -> Void)? = nil) async throws {
        // print("LlamaCppEngine: Loading model from \(modelPath), context: \(contextSize)")
        // Run blocking C model load off the cooperative thread pool
        // to avoid starving the main actor and causing UI hangs
        let context = try await Task.detached(priority: .userInitiated) {
            try LlamaContext.create_context(path: modelPath, contextSize: contextSize, onProgress: onProgress)
        }.value
        llamaContext = context
        // print("LlamaCppEngine: Model loaded successfully")
    }

    func generateNext(messages: [(role: String, content: String)]) async throws {
        guard let context = llamaContext else {
            throw NSError(domain: "LlamaCppEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Engine not initialized"
            ])
        }

        let finalPrompt = await context.apply_chat_template(messages: messages)
        // print("Formatted prompt:\n\(finalPrompt)")
        await context.completion_init_with_cache(text: finalPrompt)
        isComplete = false
    }

    func streamToken() async throws -> String? {
        guard let context = llamaContext else {
            return nil
        }

        if await context.is_done {
            isComplete = true
            return nil
        }

        let token = await context.completion_loop()

        if await context.is_done {
            isComplete = true
        }

        return token
    }

    func stop() async {
        isComplete = true
        if let context = llamaContext {
            await context.clearGenerationState()
        }
    }

    func resume() async {
        isComplete = false
    }

    func clear() async {
        if let context = llamaContext {
            await context.clear()
        }
        isComplete = true
    }

    func modelInfo() -> String {
        return "GGUF Model (llama.cpp)"
    }

    func clearGenerationState() async {
        if let context = llamaContext {
            await context.clearGenerationState()
        }
    }

    var currentEntropy: Float {
        get async { await llamaContext?.currentEntropy ?? 0.0 }
    }

    var averageEntropy: Float {
        get async { await llamaContext?.averageEntropy ?? 0.0 }
    }

    func countTokens(for messages: [(role: String, content: String)]) async -> Int {
        guard let context = llamaContext else { return 0 }
        let prompt = await context.apply_chat_template(messages: messages)
        return await context.countTokens(text: prompt)
    }

    func deinitialize() async {
        llamaContext = nil
    }
}
