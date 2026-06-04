import Foundation
import Speech

/// Off–main-thread transcription with per-chunk checkpointing.
actor TranscriptionEngine {
    private var activeTask: SFSpeechRecognitionTask?
    private var isCancelled = false

    func cancel() {
        isCancelled = true
        activeTask?.cancel()
        activeTask = nil
    }

    struct Result: Sendable {
        let transcript: String
        let totalChunks: Int
    }

    func transcribe(
        mediaURL: URL,
        jobId: UUID?,
        startingChunkIndex: Int,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Result {
        isCancelled = false

        let didAccess = mediaURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { mediaURL.stopAccessingSecurityScopedResource() }
        }

        let recognizer = try await LocalSpeechGuard.ensureReady()

        onProgress?(TranscriptionProgress(fraction: 0.05, message: "Preparing audio…", completedChunks: 0, totalChunks: 0))

        let audioURL: URL
        if let jobId,
           let checkpoint = TranscriptionCheckpointStore.load(jobId: jobId),
           let audioName = checkpoint.audioFilename {
            audioURL = TranscriptionCheckpointStore.jobDirectory(jobId).appendingPathComponent(audioName)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw AudioExtractorError.exportFailed("cached audio missing")
            }
        } else {
            audioURL = try await AudioExtractor.exportAudio(from: mediaURL)
            if let jobId {
                let dest = TranscriptionCheckpointStore.jobDirectory(jobId).appendingPathComponent("audio.m4a")
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: audioURL, to: dest)
                if var checkpoint = TranscriptionCheckpointStore.load(jobId: jobId) {
                    checkpoint.audioFilename = "audio.m4a"
                    try TranscriptionCheckpointStore.save(checkpoint)
                }
            }
        }

        let chunks = try await AudioExtractor.preparedChunks(from: audioURL)
        let total = chunks.count
        var inlineParts: [String] = []

        for (index, chunkURL) in chunks.enumerated() {
            try Task.checkCancellation()
            if isCancelled { throw CancellationError() }
            if index <= startingChunkIndex { continue }

            onProgress?(TranscriptionProgress(
                fraction: Double(index) / Double(max(total, 1)),
                message: "Transcribing part \(index + 1) of \(total)…",
                completedChunks: index,
                totalChunks: total
            ))

            let text = try await transcribeChunk(url: chunkURL, recognizer: recognizer)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let jobId {
                    try TranscriptionCheckpointStore.appendTranscript(jobId: jobId, text: text)
                    if var checkpoint = TranscriptionCheckpointStore.load(jobId: jobId) {
                        checkpoint.completedChunkIndex = index
                        checkpoint.totalChunks = total
                        checkpoint.updatedAt = Date()
                        checkpoint.state = .running
                        try TranscriptionCheckpointStore.save(checkpoint)
                    }
                } else {
                    inlineParts.append(text)
                }
            }

            if chunkURL != audioURL {
                try? FileManager.default.removeItem(at: chunkURL)
            }
        }

        if jobId == nil, audioURL.path.contains(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let transcript: String
        if let jobId, let saved = TranscriptionCheckpointStore.readTranscript(jobId: jobId) {
            transcript = saved
        } else {
            transcript = inlineParts.joined(separator: "\n\n")
        }

        onProgress?(TranscriptionProgress(fraction: 1, message: "Done", completedChunks: total, totalChunks: total))
        return Result(transcript: transcript, totalChunks: total)
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
                    Task { await self?.clearTask() }
                    return
                }
                guard let result, result.isFinal else { return }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result.bestTranscription.formattedString)
                Task { await self?.clearTask() }
            }
        }
    }

    private func clearTask() {
        activeTask = nil
    }
}