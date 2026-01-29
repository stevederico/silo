import Foundation

protocol InferenceEngine: Actor {
    var isComplete: Bool { get }

    func initialize(modelPath: String, contextSize: UInt32, onProgress: (@Sendable (Float) -> Void)?) async throws
    func generateNext(messages: [(role: String, content: String)]) async throws
    func streamToken() async throws -> String?
    func stop() async
    func resume() async
    func clear() async
    func modelInfo() -> String
    func deinitialize() async
    func countTokens(for messages: [(role: String, content: String)]) async -> Int
}
