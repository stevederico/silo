import AVFoundation
import Foundation

@MainActor
final class SpeechSynthesizerService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var sentenceBuffer = ""
    private var spokenDisplayLength = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        sentenceBuffer = ""
        spokenDisplayLength = 0
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Feed filtered display tokens; speaks full sentences when enabled.
    func feed(displayText: String, enabled: Bool) {
        guard enabled else { return }
        guard displayText.count > spokenDisplayLength else { return }
        let delta = String(displayText.dropFirst(spokenDisplayLength))
        spokenDisplayLength = displayText.count
        sentenceBuffer += delta
        tryFlushSentences()
    }

    func finish(enabled: Bool) {
        guard enabled else {
            stop()
            return
        }
        let remaining = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        sentenceBuffer = ""
        if !remaining.isEmpty {
            speak(remaining)
        }
    }

    private func tryFlushSentences() {
        while let range = sentenceBuffer.range(of: #"[\.\!\?][\s\n]+"#, options: .regularExpression) {
            let sentence = String(sentenceBuffer[sentenceBuffer.startIndex..<range.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sentenceBuffer.removeSubrange(sentenceBuffer.startIndex..<range.upperBound)
            if sentence.count > 2 {
                speak(sentence)
            }
        }
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        let language = Locale.preferredLanguages.first ?? Locale.current.identifier
        utterance.voice = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        isSpeaking = true
        synthesizer.speak(utterance)
    }
}

extension SpeechSynthesizerService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synthesizer.isSpeaking {
                self.isSpeaking = false
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}