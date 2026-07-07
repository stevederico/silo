import Foundation

enum TranscriptionJobState: String, Codable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

struct TranscriptionCheckpoint: Codable {
    let jobId: UUID
    var state: TranscriptionJobState
    var mediaFilename: String
    var audioFilename: String?
    var completedChunkIndex: Int
    var totalChunks: Int
    var createdAt: Date
    var updatedAt: Date
    var errorMessage: String?
    var conversationId: UUID?

    var transcriptFilename: String { "transcript.txt" }
    var partialTranscriptURL: URL { TranscriptionCheckpointStore.jobDirectory(jobId).appendingPathComponent(transcriptFilename) }
}

struct TranscriptionProgress: Sendable {
    let fraction: Double
    let message: String
    let completedChunks: Int
    let totalChunks: Int
}

enum TranscriptionCheckpointStore {
    static func jobsRoot() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("transcription-jobs", isDirectory: true)
    }

    static func jobDirectory(_ jobId: UUID) -> URL {
        jobsRoot().appendingPathComponent(jobId.uuidString, isDirectory: true)
    }

    static func ensureJobDirectory(_ jobId: UUID) throws -> URL {
        let dir = jobDirectory(jobId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func checkpointURL(_ jobId: UUID) -> URL {
        jobDirectory(jobId).appendingPathComponent("checkpoint.json")
    }

    static func save(_ checkpoint: TranscriptionCheckpoint) throws {
        let url = checkpointURL(checkpoint.jobId)
        _ = try ensureJobDirectory(checkpoint.jobId)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: url, options: .atomic)
    }

    static func load(jobId: UUID) -> TranscriptionCheckpoint? {
        let url = checkpointURL(jobId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptionCheckpoint.self, from: data)
    }

    static func appendTranscript(jobId: UUID, text: String) throws {
        let fileURL = jobDirectory(jobId).appendingPathComponent("transcript.txt")
        let chunk = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n\n".utf8))
            try handle.write(contentsOf: Data(chunk.utf8))
            try handle.close()
        } else {
            try chunk.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func readTranscript(jobId: UUID) -> String? {
        let fileURL = jobDirectory(jobId).appendingPathComponent("transcript.txt")
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }
}