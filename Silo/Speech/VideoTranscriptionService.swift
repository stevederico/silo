import Foundation
import Speech

@MainActor
final class VideoTranscriptionService: ObservableObject {
    @Published private(set) var isTranscribing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage = ""

    private var activeTask: SFSpeechRecognitionTask?

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isTranscribing = false
        statusMessage = "Cancelled"
    }

    /// Transcribes video or audio at `mediaURL` using on-device Apple Speech only.
    func transcribe(mediaURL: URL) async throws -> String {
        guard !isTranscribing else { return "" }
        isTranscribing = true
        progress = 0
        statusMessage = "Preparing audio…"
        defer {
            isTranscribing = false
            activeTask = nil
        }

        let didAccess = mediaURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { mediaURL.stopAccessingSecurityScopedResource() }
        }

        let recognizer = try await LocalSpeechGuard.ensureReady()
        let audioURL = try await AudioExtractor.exportAudio(from: mediaURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        statusMessage = "Splitting audio…"
        let chunks = try await AudioExtractor.preparedChunks(from: audioURL)
        var parts: [String] = []

        for (index, chunkURL) in chunks.enumerated() {
            statusMessage = "Transcribing part \(index + 1) of \(chunks.count)…"
            progress = Double(index) / Double(max(chunks.count, 1))
            let text = try await transcribeChunk(url: chunkURL, recognizer: recognizer)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(text)
            }
            if chunkURL != audioURL {
                try? FileManager.default.removeItem(at: chunkURL)
            }
        }

        progress = 1
        statusMessage = "Done"
        return parts.joined(separator: "\n\n")
    }

    private func transcribeChunk(url: URL, recognizer: SFSpeechRecognizer) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            LocalSpeechGuard.applyOnDeviceOnly(to: request)

            var resumed = false
            activeTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let error {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: error)
                    self?.activeTask = nil
                    return
                }
                guard let result, result.isFinal else { return }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result.bestTranscription.formattedString)
                self?.activeTask = nil
            }
        }
    }
}