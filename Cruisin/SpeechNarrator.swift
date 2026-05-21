import AVFoundation
import Foundation

@MainActor
protocol VoiceNarrating: AnyObject {
    func speak(_ text: String)
    func stop()
}

@MainActor
final class SpeechNarrator: NSObject, VoiceNarrating {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .word)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.46
        utterance.pitchMultiplier = 0.98
        utterance.volume = 0.92
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
