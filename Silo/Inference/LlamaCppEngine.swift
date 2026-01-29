import Foundation

actor LlamaCppEngine: InferenceEngine {
    private var llamaContext: LlamaContext?
    var isComplete: Bool = true

    init() {}

    func initialize(modelPath: String) async throws {
        print("LlamaCppEngine: Loading model from \(modelPath)")
        llamaContext = try LlamaContext.create_context(path: modelPath)
        print("LlamaCppEngine: Model loaded successfully")
    }

    func generateNext(prompt: String, systemPrompt: String) async throws {
        guard let context = llamaContext else {
            throw NSError(domain: "LlamaCppEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Engine not initialized"
            ])
        }

        let finalPrompt = systemPrompt + prompt
        await context.completion_init(text: finalPrompt)
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
            await context.clear()
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

    func deinitialize() async {
        llamaContext = nil
    }
}
