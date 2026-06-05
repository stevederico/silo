import AVFoundation
import Foundation

@MainActor
final class VoiceSession: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var partialTranscript = ""
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var audioSamples: [Float] = []
    private var isStopping = false

    // For whisper live (set before start)
    var whisperModelPath: String?
    private let whisperEngine = WhisperCppEngine()

    func startListening() async throws {
        errorMessage = nil
        partialTranscript = ""
        audioSamples = []
        isStopping = false

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Prefer 16kHz for whisper compatibility
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) ?? format

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: desiredFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Convert to float samples
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            self.audioSamples.append(contentsOf: samples)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true

        // Simple partial: every 2s transcribe what we have so far (for demo)
        Task {
            while self.isListening && !self.isStopping {
                try? await Task.sleep(for: .seconds(2))
                if self.isListening && !self.audioSamples.isEmpty, let path = self.whisperModelPath {
                    do {
                        try await self.whisperEngine.initialize(modelPath: path)
                        let segments = try await self.whisperEngine.transcribe(audioSamples: self.audioSamples)
                        let text = segments.map(\.text).joined(separator: " ")
                        await MainActor.run {
                            if !text.isEmpty {
                                self.partialTranscript = text
                            }
                        }
                    } catch {
                        // ignore partial errors
                    }
                }
            }
        }
    }

    func stopListening() async -> String {
        guard isListening else { return "" }
        isStopping = true
        defer { isStopping = false }

        let snapshot = partialTranscript

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // Final transcription with whisper if model set
        var finalText = snapshot
        if let path = whisperModelPath, !audioSamples.isEmpty {
            do {
                try await whisperEngine.initialize(modelPath: path)
                let segments = try await whisperEngine.transcribe(audioSamples: audioSamples)
                finalText = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if finalText.isEmpty {
                    finalText = snapshot
                }
            } catch {
                finalText = snapshot
            }
        }

        isListening = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        partialTranscript = ""
        audioSamples = []
        return finalText
    }
}