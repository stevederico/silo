import Foundation

actor WhisperCppEngine {
    private var whisperContext: WhisperContext?
    private var currentModelPath: String?

    var isComplete: Bool = true

    func isModelLoaded() -> Bool {
        return whisperContext != nil
    }

    func initialize(modelPath: String, onProgress: (@Sendable (Float) -> Void)? = nil) async throws {
        if whisperContext != nil && currentModelPath == modelPath {
            return // already loaded
        }
        // whisper.cpp init is relatively fast; progress can be added later if needed
        let context = try WhisperContext(modelPath: modelPath)
        self.whisperContext = context
        self.currentModelPath = modelPath
        isComplete = true
    }

    func transcribe(audioSamples: [Float], language: String = "en") async throws -> [WhisperSegment] {
        guard let ctx = whisperContext else {
            throw WhisperError.couldNotInitializeContext(path: currentModelPath ?? "unknown")
        }

        isComplete = false
        defer { isComplete = true }

        return try await ctx.transcribe(samples: audioSamples, language: language)
    }

    func getModelInfo() async -> String {
        guard let ctx = whisperContext else { return "No model" }
        return await ctx.getModelInfo()
    }

    func deinitialize() async {
        whisperContext = nil
        currentModelPath = nil
        isComplete = true
    }
}