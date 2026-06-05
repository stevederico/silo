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

        var transcript: String
        if let jobId, let saved = TranscriptionCheckpointStore.readTranscript(jobId: jobId) {
            transcript = saved
        } else {
            transcript = inlineParts.joined(separator: "\n\n")
        }

        // On-device URL recognition often returns empty without error — retry with en-US.
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let fallback = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
           fallback.isAvailable,
           fallback.locale.identifier != recognizer.locale.identifier {
            onProgress?(TranscriptionProgress(
                fraction: 0.9,
                message: "Retrying with English (US)…",
                completedChunks: total,
                totalChunks: total
            ))
            var retryParts: [String] = []
            for chunkURL in chunks {
                try Task.checkCancellation()
                let text = try await transcribeChunk(url: chunkURL, recognizer: fallback)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    retryParts.append(text)
                }
            }
            transcript = retryParts.joined(separator: "\n\n")
        }

        onProgress?(TranscriptionProgress(fraction: 1, message: "Done", completedChunks: total, totalChunks: total))
        return Result(transcript: transcript, totalChunks: total)
    }

    private func transcribeChunk(url: URL, recognizer: SFSpeechRecognizer) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            LocalSpeechGuard.applyOnDeviceOnly(to: request)

            var resumed = false
            var bestText = ""

            func finish(_ text: String) {
                guard !resumed else { return }
                resumed = true
                activeTask = nil
                continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            activeTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let error {
                    guard !resumed else { return }
                    if !bestText.isEmpty {
                        finish(bestText)
                    } else {
                        resumed = true
                        self?.activeTask = nil
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    bestText = text
                }
                if result.isFinal {
                    finish(bestText)
                }
            }

            // On-device file recognition may never mark isFinal — use last partial after a wait.
            Task {
                for _ in 0..<600 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if resumed || isCancelled { return }
                    if activeTask?.isFinishing == true || activeTask?.state == .completed {
                        break
                    }
                }
                if !resumed {
                    finish(bestText)
                }
            }
        }
    }
}