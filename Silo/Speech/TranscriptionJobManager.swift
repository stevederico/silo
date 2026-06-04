import Foundation
import UIKit

@MainActor
final class TranscriptionJobManager: ObservableObject {
    @Published private(set) var activeJobId: UUID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage = ""
    @Published private(set) var isRunning = false
    @Published var completedJobNeedsAttention: UUID?

    weak var llamaState: LlamaState?

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
    }

    /// Enqueues a durable transcription job (checkpointed, background-friendly).
    func startJob(mediaURL: URL, llamaState: LlamaState) async throws -> UUID {
        cancel()
        self.llamaState = llamaState

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
                    userInfo: [NSLocalizedDescriptionKey: "No speech detected in this file."]
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
        } catch is CancellationError {
            statusMessage = "Cancelled"
            activeJobId = nil
            await llamaState?.resumeModelAfterSpeech()
        } catch {
            if var checkpoint = TranscriptionCheckpointStore.load(jobId: jobId) {
                checkpoint.state = .failed
                checkpoint.errorMessage = error.localizedDescription
                checkpoint.updatedAt = Date()
                try? TranscriptionCheckpointStore.save(checkpoint)
            }
            statusMessage = error.localizedDescription
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
}