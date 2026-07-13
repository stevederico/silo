import Foundation

/// Off–main-thread transcription with per-chunk checkpointing using whisper.cpp.
/// (Apple SFSpeech removed — switched to local whisper.cpp for reliability + timestamps)
actor TranscriptionEngine {
    private var isCancelled = false
    private let whisperEngine = WhisperCppEngine()
    private var whisperModelPath: String?

    func configure(whisperModelPath: String) {
        self.whisperModelPath = whisperModelPath
    }

    func cancel() {
        isCancelled = true
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

        guard let modelPath = whisperModelPath else {
            throw WhisperError.couldNotInitializeContext(path: "No whisper model configured. Call configure(whisperModelPath:) first.")
        }

        onProgress?(TranscriptionProgress(fraction: 0.05, message: String(localized: "Loading Whisper model…"), completedChunks: 0, totalChunks: 0))

        try await whisperEngine.initialize(modelPath: modelPath)

        onProgress?(TranscriptionProgress(fraction: 0.1, message: String(localized: "Preparing audio for Whisper…"), completedChunks: 0, totalChunks: 0))

        // For whisper we prefer direct 16kHz samples (no more M4A dependency for transcription)
        let audioURL: URL
        if let jobId,
           let checkpoint = TranscriptionCheckpointStore.load(jobId: jobId),
           let audioName = checkpoint.audioFilename {
            audioURL = TranscriptionCheckpointStore.jobDirectory(jobId).appendingPathComponent(audioName)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw AudioExtractorError.exportFailed("cached audio missing")
            }
        } else {
            // Export to a temp location (we'll load samples directly)
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
                message: String(localized: "Transcribing part \(index + 1) of \(total) with Whisper…"),
                completedChunks: index,
                totalChunks: total
            ))

            let samples = try await AudioExtractor.loadWhisperSamples(from: chunkURL)
            let segments = try await whisperEngine.transcribe(audioSamples: samples)

            let text = segments.map { seg in
                let startMin = Int(seg.start / 60)
                let startSec = Int(seg.start.truncatingRemainder(dividingBy: 60))
                return String(format: "[%02d:%02d] %@", startMin, startSec, seg.text)
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                // For now keep simple text output (timestamps available in segments for future)
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

        onProgress?(TranscriptionProgress(fraction: 1, message: "Done", completedChunks: total, totalChunks: total))

        // Clean up engine
        await whisperEngine.deinitialize()

        return Result(transcript: transcript, totalChunks: total)
    }
}