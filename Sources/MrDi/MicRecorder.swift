import AppKit
import AVFoundation
import Speech

/// Диктовка с микрофона с живой расшифровкой.
///
/// Слово распознаётся **сразу двумя** распознавателями — английским и русским —
/// на одном и том же звуке. Спрашивать у пользователя язык заранее нельзя:
/// он для того и говорит, что слова не знает.
///
/// Победитель выбирается не по уверенности распознавания: на устройстве она почти
/// всегда приходит нулевой и ничего не различает. Решает то, получилось ли **настоящее
/// слово** своего языка — это проверяется системным словарём орфографии. Чужой язык
/// на незнакомой речи выдаёт бессмыслицу («собака» → «so back a»), и она отсеивается.
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
    private var finalContinuation: ResumeOnceVoid?

    struct Hypothesis {
        let text: String
        let locale: String
    }

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

    /// Останавливает запись и отдаёт расшифровки, лучшая первой.
    /// Второй вариант нужен живым: ни одна эвристика не угадывает язык всегда,
    /// и у пользователя должна остаться возможность переключиться одной клавишей.
    func stop() async -> [Hypothesis] {
        guard isRecording else { return [] }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        channels.forEach { $0.request.endAudio() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = ResumeOnceVoid(continuation)
            finalContinuation = box
            // распознавание могло не успеть отдать финальный результат —
            // тогда берём накопленное, оно почти всегда то же самое
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { box.finish() }
        }

        let result = ranked().map {
            Hypothesis(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), locale: $0.locale)
        }
        cleanup()
        return result.filter { !$0.text.isEmpty }
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        channels.forEach { $0.request.endAudio() }
        finalContinuation?.finish()
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
            finalContinuation?.finish()
        }
    }

    private func bestPartial() -> String {
        ranked().first?.text ?? ""
    }

    /// Порядок предпочтения, по убыванию важности:
    ///
    /// 1. доля настоящих слов — отсеивает «резильенс» на месте `resilience`;
    /// 2. меньше слов — русское слово, услышанное английским распознавателем,
    ///    распадается на несколько коротких, но настоящих слов («собака» → «so back a»),
    ///    и на первом критерии выходит ничья;
    /// 3. уверенность — на устройстве она почти всегда нулевая и вдобавок несравнима
    ///    между двумя разными моделями, поэтому стоит после смысловых признаков;
    /// 4. английский — основное направление приложения.
    ///
    /// На разборе типовых случаев это даёт верный язык почти всегда. Неразрешимой
    /// остаётся честная омонимия вроде «мама»/«mama» — для неё есть ⇥.
    private func ranked() -> [Channel] {
        let candidates = channels.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        return candidates.sorted { lhs, rhs in
            let known = (Self.knownWordRatio(lhs), Self.knownWordRatio(rhs))
            if let l = known.0, let r = known.1, abs(l - r) > 0.01 { return l > r }

            let words = (Self.wordCount(lhs.text), Self.wordCount(rhs.text))
            if words.0 != words.1 { return words.0 < words.1 }

            if abs(lhs.confidence - rhs.confidence) > 0.02 { return lhs.confidence > rhs.confidence }
            return lhs.locale.hasPrefix("en")
        }
    }

    /// Доля слов, которые системный словарь орфографии считает существующими.
    /// nil — словаря этого языка в системе нет, и критерий пропускается,
    /// иначе язык без словаря проигрывал бы всегда.
    private static func knownWordRatio(_ channel: Channel) -> Double? {
        let language = String(channel.locale.prefix(2))
        guard spellCheckerSupports(language) else { return nil }

        let words = channel.text.split { !$0.isLetter && $0 != "'" && $0 != "-" }.map(String.init)
        guard !words.isEmpty else { return 0 }

        let known = words.filter { word in
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language,
                                                wrap: false, inSpellDocumentWithTag: 0,
                                                wordCount: nil).location == NSNotFound
        }
        return Double(known.count) / Double(words.count)
    }

    private static func spellCheckerSupports(_ language: String) -> Bool {
        NSSpellChecker.shared.availableLanguages.contains {
            $0 == language || $0.hasPrefix(language + "_") || $0.hasPrefix(language + "-")
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && $0 != "'" && $0 != "-" }.count
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
final class ResumeOnceVoid: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func finish() {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        continuation.resume()
    }
}
