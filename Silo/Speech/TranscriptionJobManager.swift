import Foundation
import UIKit

@MainActor
final class TranscriptionJobManager: ObservableObject {
    @Published private(set) var activeJobId: UUID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage = ""
    @Published private(set) var isRunning = false
    @Published var completedJobNeedsAttention: UUID?
    /// Shown after the job ends until cleared or a new job starts.
    @Published private(set) var failureMessage: String?
    @Published private(set) var videoThumbnail: UIImage?

    weak var llamaState: LlamaState?

    /// Set this before starting jobs (path to ggml-small.en-q5_0.bin or similar)
    var whisperModelPath: String?

    func clearFailure() {
        failureMessage = nil
    }

    private let engine = TranscriptionEngine()
    private var runTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    var isTranscribing: Bool { isRunning }

    func cancel() {
        runTask?.cancel()
        Task { await engine.cancel() }
        if let jobId = activeJobId, var checkpoint = TranscriptionCheckpointStore.load(jobId: jobId) {
            checkpoint.state = .cancelled
            checkpoint.updatedAt = Date()
            try? TranscriptionCheckpointStore.save(checkpoint)
        }
        endBackgroundTask()
        isRunning = false
        statusMessage = "Cancelled"
        activeJobId = nil
        videoThumbnail = nil
    }

    /// Enqueues a durable transcription job (checkpointed, background-friendly).
    func startJob(mediaURL: URL, llamaState: LlamaState) async throws -> UUID {
        cancel()
        clearFailure()
        self.llamaState = llamaState
        llamaState.attachedTranscriptionJobId = nil
        llamaState.attachedVideoThumbnail = nil

        let jobId = UUID()
        let jobDir = try TranscriptionCheckpointStore.ensureJobDirectory(jobId)
        let ext = mediaURL.pathExtension.isEmpty ? "mov" : mediaURL.pathExtension
        let destMedia = jobDir.appendingPathComponent("source.\(ext)")

        let didAccess = mediaURL.startAccessingSecurityScopedResource()
        defer { if didAccess { mediaURL.stopAccessingSecurityScopedResource() } }

        if FileManager.default.fileExists(atPath: destMedia.path) {
            try FileManager.default.removeItem(at: destMedia)
        }
        try FileManager.default.copyItem(at: mediaURL, to: destMedia)

        videoThumbnail = nil
        let thumbnailJobId = jobId
        let thumbnailMediaURL = destMedia
        Task {
            await VideoThumbnailGenerator.generateAndSaveForJob(jobId: thumbnailJobId, mediaURL: thumbnailMediaURL)
            let image = VideoThumbnailGenerator.loadJobThumbnail(jobId: thumbnailJobId)
            await MainActor.run {
                guard self.activeJobId == thumbnailJobId || self.completedJobNeedsAttention == thumbnailJobId else { return }
                self.videoThumbnail = image
                self.llamaState?.attachedVideoThumbnail = image
            }
        }

        let checkpoint = TranscriptionCheckpoint(
            jobId: jobId,
            state: .queued,
            mediaFilename: destMedia.lastPathComponent,
            audioFilename: nil,
            completedChunkIndex: -1,
            totalChunks: 0,
            createdAt: Date(),
            updatedAt: Date(),
            conversationId: nil
        )
        try TranscriptionCheckpointStore.save(checkpoint)
        let transcriptPath = jobDir.appendingPathComponent("transcript.txt")
        try? FileManager.default.removeItem(at: transcriptPath)

        activeJobId = jobId
        isRunning = true
        progress = 0
        statusMessage = "Queued…"

        // Auto wire whisper model if available
        if let ls = self.llamaState {
            self.whisperModelPath = ls.defaultWhisperModelPath()
        }

        runTask = Task {
            await self.runJob(jobId: jobId, mediaURL: destMedia)
        }

        return jobId
    }

    private func runJob(jobId: UUID, mediaURL: URL) async {
        beginBackgroundTask()
        defer {
            endBackgroundTask()
            isRunning = false
        }

        await llamaState?.suspendModelForSpeech()
        statusMessage = "Model unloaded for transcription"

        guard var checkpoint = TranscriptionCheckpointStore.load(jobId: jobId) else {
            statusMessage = "Job missing"
            activeJobId = nil
            await llamaState?.resumeModelAfterSpeech()
            return
        }

        checkpoint.state = .running
        try? TranscriptionCheckpointStore.save(checkpoint)

        do {
            if let path = whisperModelPath {
                await engine.configure(whisperModelPath: path)
            } else {
                // TODO: set via jobManager.whisperModelPath = "/path/to/model.bin" before startJob
            }

            let startChunk = checkpoint.completedChunkIndex
            let result = try await engine.transcribe(
                mediaURL: mediaURL,
                jobId: jobId,
                startingChunkIndex: startChunk
            ) { [weak self] update in
                Task { @MainActor in
                    self?.progress = update.fraction
                    self?.statusMessage = update.message
                }
            }

            let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                throw NSError(
                    domain: "TranscriptionJob",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: """
                    No speech detected. Use a video with clear spoken audio and download a Whisper model in Manage Models.
                    """]
                )
            }

            checkpoint = TranscriptionCheckpointStore.load(jobId: jobId) ?? checkpoint
            checkpoint.state = .completed
            checkpoint.totalChunks = result.totalChunks
            checkpoint.updatedAt = Date()
            try TranscriptionCheckpointStore.save(checkpoint)

            progress = 1
            statusMessage = "Done"
            completedJobNeedsAttention = jobId
            activeJobId = nil

            await llamaState?.attachVideoTranscript(transcript, transcriptJobId: jobId)
            await llamaState?.resumeModelAfterSpeech()

            if llamaState?.transcriptCharacterCount == 0 {
                failureMessage = "Transcription finished but no transcript was saved. Try a video with clearer speech."
            }
        } catch is CancellationError {
            statusMessage = "Cancelled"
            activeJobId = nil
            await llamaState?.resumeModelAfterSpeech()
        } catch {
            let message = Self.describeFailure(error)
            if var checkpoint = TranscriptionCheckpointStore.load(jobId: jobId) {
                checkpoint.state = .failed
                checkpoint.errorMessage = message
                checkpoint.updatedAt = Date()
                try? TranscriptionCheckpointStore.save(checkpoint)
            }
            statusMessage = message
            failureMessage = message
            activeJobId = nil
            await llamaState?.resumeModelAfterSpeech()
        }
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SiloTranscription") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private static func describeFailure(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        let text = error.localizedDescription
        return text.isEmpty ? String(describing: error) : text
    }
}