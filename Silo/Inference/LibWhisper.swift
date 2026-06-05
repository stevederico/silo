import Foundation
import whisper

enum WhisperError: Error, LocalizedError {
    case couldNotInitializeContext(path: String)
    case transcriptionFailed
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .couldNotInitializeContext(let path):
            let name = (path as NSString).lastPathComponent
            return "Could not load Whisper model \(name). Ensure it's a valid ggml model and try again."
        case .transcriptionFailed:
            return "Whisper transcription failed."
        case .invalidAudio:
            return "Audio data is invalid or too short for transcription."
        }
    }
}

actor WhisperContext {
    private var context: OpaquePointer?

    init(modelPath: String) throws {
        var params = whisper_context_default_params()

        // use_gpu enables Metal backend (for ggml compute) on Apple devices.
        // CoreML encoder acceleration (if model converted) is also tied to GPU path in recent builds.
        // We enable it for speed. The residency set feature (causing rset_init crashes in some
        // environments like Simulator or with dual llama+whisper) is disabled app-wide via
        // GGML_METAL_NO_RESIDENCY=1 in SiloApp.swift .
        params.use_gpu = true

        // To force CPU-only (slower, but avoids all Metal issues):
        // params.use_gpu = false

        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperError.couldNotInitializeContext(path: modelPath)
        }
        self.context = ctx
    }

    deinit {
        if let ctx = context {
            whisper_free(ctx)
        }
    }

    func transcribe(
        samples: [Float],
        language: String = "en",
        translate: Bool = false,
        onProgress: (@Sendable (Int32) -> Void)? = nil
    ) async throws -> [WhisperSegment] {
        guard let ctx = context else {
            throw WhisperError.transcriptionFailed
        }

        guard !samples.isEmpty else {
            throw WhisperError.invalidAudio
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = true
        params.translate = translate
        params.language = (language as NSString).utf8String
        params.n_threads = 4  // Tune for iOS

        let ret = samples.withUnsafeBufferPointer { ptr in
            whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
        }

        guard ret == 0 else {
            throw WhisperError.transcriptionFailed
        }

        let nSegments = whisper_full_n_segments(ctx)
        var segments: [WhisperSegment] = []
        segments.reserveCapacity(Int(nSegments))

        for i in 0..<nSegments {
            let text = String(cString: whisper_full_get_segment_text(ctx, i))
            let t0 = whisper_full_get_segment_t0(ctx, i)  // in 10ms units
            let t1 = whisper_full_get_segment_t1(ctx, i)

            let start = Double(t0) / 100.0
            let end = Double(t1) / 100.0

            segments.append(WhisperSegment(start: start, end: end, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return segments
    }

    func getModelInfo() -> String {
        guard let ctx = context else { return "No model loaded" }
        let n = whisper_model_n_vocab(ctx)
        return "Whisper context loaded (vocab: \(n))"
    }
}

struct WhisperSegment: Sendable {
    let start: Double   // seconds
    let end: Double     // seconds
    let text: String
}