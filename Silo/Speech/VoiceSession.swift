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
    private var finalizedTranscript = ""

    func startListening() async throws {
        errorMessage = nil
        partialTranscript = ""
        finalizedTranscript = ""

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
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialTranscript = text
                    if result.isFinal {
                        self.finalizedTranscript = text
                    }
                }
                if let error {
                    self.errorMessage = error.localizedDescription
                    Task { _ = await self.stopListening() }
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
    }

    func stopListening() async -> String {
        guard isListening else { return "" }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()

        // Final result often arrives shortly after finish().
        try? await Task.sleep(for: .milliseconds(400))

        recognitionRequest = nil
        recognitionTask = nil
        isListening = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let candidate = finalizedTranscript.isEmpty ? partialTranscript : finalizedTranscript
        let final = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        partialTranscript = ""
        finalizedTranscript = ""
        return final
    }
}