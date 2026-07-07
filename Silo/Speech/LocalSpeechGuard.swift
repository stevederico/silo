import Foundation
import Speech

// DEPRECATED: Apple SFSpeech no longer used for transcription (switched to whisper.cpp).
// Kept for reference / possible future live fallback. Remove in future cleanup.

enum LocalSpeechError: LocalizedError {
    case notAuthorized
    case onDeviceUnavailable
    case recognizerUnavailable
    case localeUnsupported

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition permission is required. Enable it in Settings."
        case .onDeviceUnavailable:
            return "On-device speech recognition is not available for this language. Download the language in Settings → General → Keyboard → Dictation, then try again."
        case .recognizerUnavailable:
            return "Speech recognition is not available on this device."
        case .localeUnsupported:
            return "The current language is not supported for on-device recognition."
        }
    }
}

enum LocalSpeechGuard {
    /// Ensures speech auth + on-device recognizer for the given or current locale.
    static func ensureReady(locale: Locale = .current) async throws -> SFSpeechRecognizer {
        let status = await requestAuthorizationIfNeeded()
        guard status == .authorized else {
            throw LocalSpeechError.notAuthorized
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw LocalSpeechError.recognizerUnavailable
        }
        guard recognizer.isAvailable else {
            throw LocalSpeechError.recognizerUnavailable
        }
        #if !targetEnvironment(simulator)
        guard recognizer.supportsOnDeviceRecognition else {
            throw LocalSpeechError.onDeviceUnavailable
        }
        #endif

        return recognizer
    }

    static func requestAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Configures a request for strictly on-device recognition (no cloud).
    static func applyOnDeviceOnly(to request: SFSpeechRecognitionRequest) {
        #if targetEnvironment(simulator)
        // Simulator often lacks on-device speech assets; allow recognition for dev testing.
        if let recognizer = SFSpeechRecognizer(),
           recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        #else
        request.requiresOnDeviceRecognition = true
        #endif
        request.addsPunctuation = true
    }
}