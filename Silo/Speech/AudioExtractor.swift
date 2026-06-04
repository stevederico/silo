import AVFoundation
import Foundation

enum AudioExtractorError: LocalizedError {
    case noAudioTrack
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "This file has no audio track to transcribe."
        case .exportFailed(let reason):
            return "Could not extract audio: \(reason)"
        }
    }
}

enum AudioExtractor {
    private static let chunkDurationSeconds: Double = 55

    /// Exports the media's audio track to a temporary M4A file.
    static func exportAudio(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard !asset.tracks(withMediaType: .audio).isEmpty else {
            throw AudioExtractorError.noAudioTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-audio-\(UUID().uuidString).m4a")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExtractorError.exportFailed("export session unavailable")
        }
        export.outputURL = outputURL
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))

        await export.export()

        switch export.status {
        case .completed:
            return outputURL
        case .failed, .cancelled:
            throw AudioExtractorError.exportFailed(export.error?.localizedDescription ?? "unknown error")
        default:
            throw AudioExtractorError.exportFailed("export did not complete")
        }
    }

    /// Returns one or more audio file URLs suitable for Apple Speech (chunked when long).
    static func preparedChunks(from audioURL: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            return [audioURL]
        }
        if totalSeconds <= chunkDurationSeconds + 5 {
            return [audioURL]
        }

        var chunks: [URL] = []
        var start: Double = 0
        while start < totalSeconds {
            let end = min(start + chunkDurationSeconds, totalSeconds)
            let chunkURL = try await exportSegment(asset: asset, startSeconds: start, endSeconds: end)
            chunks.append(chunkURL)
            start = end
        }
        return chunks
    }

    private static func exportSegment(asset: AVURLAsset, startSeconds: Double, endSeconds: Double) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-chunk-\(UUID().uuidString).m4a")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExtractorError.exportFailed("chunk export unavailable")
        }
        let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let end = CMTime(seconds: endSeconds, preferredTimescale: 600)
        export.outputURL = outputURL
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(start: start, end: end)

        await export.export()

        guard export.status == .completed else {
            throw AudioExtractorError.exportFailed(export.error?.localizedDescription ?? "chunk failed")
        }
        return outputURL
    }
}