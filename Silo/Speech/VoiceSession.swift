import AVFoundation
import Foundation
import Speech

@MainActor
final class VoiceSession: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var partialTranscript = ""
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    func toggleListening() async -> String? {
        if isListening {
            return stopListening()
        }
        do {
            try await startListening()
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func startListening() async throws {
        errorMessage = nil
        partialTranscript = ""

        recognizer = try await LocalSpeechGuard.ensureReady()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        LocalSpeechGuard.applyOnDeviceOnly(to: request)
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        guard let recognizer else { throw LocalSpeechError.recognizerUnavailable }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.partialTranscript = result.bestTranscription.formattedString
                }
                if let error {
                    self?.errorMessage = error.localizedDescription
                    self?.stopListening()
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
    }

    func stopListening() -> String {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let final = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        partialTranscript = ""
        return final
    }
}