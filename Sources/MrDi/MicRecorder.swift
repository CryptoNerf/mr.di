import AVFoundation
import Speech

/// Диктовка с микрофона с живой расшифровкой.
///
/// Слово распознаётся **сразу двумя** распознавателями — английским и русским —
/// на одном и том же звуке. Спрашивать у пользователя язык заранее нельзя:
/// он для того и говорит, что слова не знает. Победитель выбирается по уверенности
/// распознавания, а направление перевода дальше выводится из алфавита результата.
///
/// Слова показываются прямо во время речи: незнакомое слово обычно произносят
/// неуверенно, и увидеть, что именно расслышал распознаватель, важнее, чем ждать
/// финального результата.
@MainActor
final class MicRecorder {
    static let shared = MicRecorder()

    private final class Channel {
        let locale: String
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        var text = ""
        var confidence = 0.0
        var isFinished = false

        init(locale: String, request: SFSpeechAudioBufferRecognitionRequest) {
            self.locale = locale
            self.request = request
        }
    }

    private static let locales = ["en-US", "ru-RU"]

    private let engine = AVAudioEngine()
    private var channels: [Channel] = []
    private var finalContinuation: ResumeOnceString?

    private(set) var isRecording = false
    var onPartial: ((String) -> Void)?

    private init() {}

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func start() throws {
        guard !isRecording else { return }
        guard Transcriber.isAuthorized else { throw TranscribeError.notAuthorized }

        channels = Self.locales.compactMap { locale -> Channel? in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
                  recognizer.isAvailable
            else { return nil }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request.addsPunctuation = true

            let channel = Channel(locale: locale, request: request)
            channel.task = recognizer.recognitionTask(with: request) { [weak self, weak channel] result, error in
                Task { @MainActor in
                    guard let self, let channel else { return }
                    self.handle(result: result, error: error, channel: channel)
                }
            }
            return channel
        }
        guard !channels.isEmpty else { throw TranscribeError.unavailable }

        let requests = channels.map(\.request)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            for request in requests { request.append(buffer) }
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Останавливает запись и отдаёт лучшую из двух расшифровок.
    func stop() async -> String {
        guard isRecording else { return "" }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        channels.forEach { $0.request.endAudio() }

        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let box = ResumeOnceString(continuation)
            finalContinuation = box
            // распознавание могло не успеть отдать финальный результат —
            // тогда берём лучшее из накопленного, оно почти всегда то же самое
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                box.finish(self?.bestText() ?? "")
            }
        }

        cleanup()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        channels.forEach { $0.request.endAudio() }
        finalContinuation?.finish("")
        cleanup()
    }

    // MARK: - Разбор результатов

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, channel: Channel) {
        if let result {
            channel.text = result.bestTranscription.formattedString
            channel.confidence = Self.averageConfidence(result.bestTranscription)
            if result.isFinal { channel.isFinished = true }
            if isRecording { onPartial?(bestPartial()) }
        }
        if error != nil { channel.isFinished = true }

        if !isRecording, channels.allSatisfy(\.isFinished) {
            finalContinuation?.finish(bestText())
        }
    }

    /// Во время речи уверенность ещё не заполнена, поэтому показываем просто
    /// самую содержательную из двух версий.
    private func bestPartial() -> String {
        channels.map(\.text).max { $0.count < $1.count } ?? ""
    }

    /// Победитель по уверенности; при близких значениях — тот, кто расслышал больше.
    private func bestText() -> String {
        let candidates = channels.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !candidates.isEmpty else { return "" }

        let best = candidates.max { lhs, rhs in
            if abs(lhs.confidence - rhs.confidence) > 0.02 {
                return lhs.confidence < rhs.confidence
            }
            return lhs.text.count < rhs.text.count
        }
        return best?.text ?? ""
    }

    private static func averageConfidence(_ transcription: SFTranscription) -> Double {
        let segments = transcription.segments
        guard !segments.isEmpty else { return 0 }
        return segments.reduce(0.0) { $0 + Double($1.confidence) } / Double(segments.count)
    }

    private func cleanup() {
        channels.forEach { $0.task?.cancel() }
        channels.removeAll()
        finalContinuation = nil
        onPartial = nil
    }
}

/// Финальный результат и таймаут могут прийти оба — возобновляем строго один раз.
final class ResumeOnceString: @unchecked Sendable {
    private var continuation: CheckedContinuation<String, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<String, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: String) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}
