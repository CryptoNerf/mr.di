import AVFoundation

/// Произношение слова системным синтезатором: офлайн, без загрузок и без ключей.
enum Speaker {
    private static let synthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.42          // чуть медленнее обычного: слово незнакомое
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
    }
}
