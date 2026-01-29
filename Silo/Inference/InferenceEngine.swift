import Foundation

protocol InferenceEngine: Actor {
    var isComplete: Bool { get }

    func initialize(modelPath: String) async throws
    func generateNext(prompt: String, systemPrompt: String) async throws
    func streamToken() async throws -> String?
    func stop() async
    func resume() async
    func clear() async
    func modelInfo() -> String
    func deinitialize() async
}
