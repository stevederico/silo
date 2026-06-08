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
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
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
        export.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))

        do {
            try await export.export(to: outputURL, as: .m4a)
        } catch {
            throw AudioExtractorError.exportFailed(error.localizedDescription)
        }

        let seconds = try await secondsOfAudio(at: outputURL)
        guard seconds >= 0.3 else {
            throw AudioExtractorError.exportFailed("audio track is too short or silent")
        }
        return outputURL
    }

    /// Returns one or more audio file URLs (chunked when long). Used for both legacy and whisper sample loading.
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
        export.timeRange = CMTimeRange(start: start, end: end)

        do {
            try await export.export(to: outputURL, as: .m4a)
        } catch {
            throw AudioExtractorError.exportFailed(error.localizedDescription)
        }
        return outputURL
    }

    private static func secondsOfAudio(at url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }

    // MARK: - whisper.cpp support (16kHz mono float32 PCM)

    /// Loads the audio as 16 kHz mono Float32 samples ready for whisper.cpp.
    /// Handles video files, M4A, etc. Resamples if necessary.
    static func loadWhisperSamples(from sourceURL: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw AudioExtractorError.noAudioTrack
        }

        // Target format for whisper.cpp: 16kHz, mono, float32
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        guard let reader = try? AVAssetReader(asset: asset),
              let track = audioTracks.first else {
            throw AudioExtractorError.exportFailed("Failed to create AVAssetReader for Whisper samples")
        }

        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: outputSettings)
        reader.add(output)

        guard reader.startReading() else {
            throw AudioExtractorError.exportFailed("AVAssetReader failed to start")
        }

        var samples: [Float] = []

        while let buffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

            if let data = dataPointer {
                let floatCount = length / MemoryLayout<Float>.size
                let floatBuffer = UnsafeBufferPointer(start: UnsafeRawPointer(data).assumingMemoryBound(to: Float.self), count: floatCount)
                samples.append(contentsOf: Array(floatBuffer))
            }
        }

        if samples.isEmpty {
            throw AudioExtractorError.exportFailed("No audio samples extracted")
        }

        return samples
    }

    /// Loads samples for a time range (for chunked long audio).
    static func loadWhisperSamples(from sourceURL: URL, startSeconds: Double, endSeconds: Double) async throws -> [Float] {
        // For simplicity in first pass, load full and slice (can optimize later with timeRange on reader)
        let full = try await loadWhisperSamples(from: sourceURL)
        let sampleRate: Double = 16000
        let startIndex = max(0, Int(startSeconds * sampleRate))
        let endIndex = min(full.count, Int(endSeconds * sampleRate))
        return Array(full[startIndex..<endIndex])
    }
}