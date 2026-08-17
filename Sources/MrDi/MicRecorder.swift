import AVFoundation
import Speech

/// Диктовка с микрофона с живой расшифровкой.
///
/// Язык задаётся сочетанием клавиш, а не угадывается: на слух автоматика ошибается
/// слишком часто, особенно на наборе слов, и лишнее нажатие оказывается дешевле
/// неверного языка.
///
/// Отдельная забота — режим «нажал, сказал, нажал ещё раз». `SFSpeechRecognizer`
/// сам закрывает сессию, услышав тишину, и весь звук после этого уходит в никуда.
/// Поэтому закрытую сессию мы молча открываем заново и продолжаем слушать,
/// накапливая уже распознанное.
@MainActor
final class MicRecorder {
    static let shared = MicRecorder()

    /// Ответвление звука в текущую сессию распознавания.
    /// Живёт отдельным объектом, потому что сессия меняется, а звуковой поток — нет.
    private final class AudioSink: @unchecked Sendable {
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private let lock = NSLock()

        func swap(_ new: SFSpeechAudioBufferRecognitionRequest?) {
            lock.lock(); request = new; lock.unlock()
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); let current = request; lock.unlock()
            current?.append(buffer)
        }
    }

    private static let maximumRestarts = 20

    private let engine = AVAudioEngine()
    private let sink = AudioSink()

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalContinuation: ResumeOnceVoid?

    private var settled = ""     // текст уже закрывшихся сессий
    private var current = ""     // текст текущей сессии
    private var restarts = 0

    private(set) var isRecording = false
    var onPartial: ((String) -> Void)?

    private init() {}

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var transcript: String {
        (settled + " " + current).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start(locale: String) throws {
        guard !isRecording else { return }
        guard Transcriber.isAuthorized else { throw TranscribeError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable
        else { throw TranscribeError.unavailable }

        self.recognizer = recognizer
        settled = ""
        current = ""
        restarts = 0
        startSession()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [sink] buffer, _ in
            sink.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() async -> String {
        guard isRecording else { return "" }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink.swap(nil)
        request?.endAudio()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = ResumeOnceVoid(continuation)
            finalContinuation = box
            // финального результата ждём недолго: он почти всегда совпадает
            // с последним частичным, который уже накоплен
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { box.finish() }
        }

        let text = transcript
        cleanup()
        return text
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink.swap(nil)
        request?.endAudio()
        finalContinuation?.finish()
        cleanup()
    }

    // MARK: - Сессии распознавания

    private func startSession() {
        guard let recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.taskHint = .dictation

        self.request = request
        current = ""
        sink.swap(request)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in self?.handle(result: result, error: error) }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            current = result.bestTranscription.formattedString
            if isRecording { onPartial?(transcript) }
        }

        let sessionEnded = (result?.isFinal ?? false) || error != nil
        guard sessionEnded else { return }

        guard isRecording else {
            finalContinuation?.finish()
            return
        }

        // пользователь ещё держит запись — распознаватель закрылся сам, по тишине.
        // Сохраняем услышанное и открываем новую сессию, не прерывая записи.
        settled = transcript
        current = ""
        task?.cancel()
        task = nil

        restarts += 1
        guard restarts <= Self.maximumRestarts else {
            NSLog("[mrdi] распознавание перезапускалось слишком часто, останавливаюсь")
            sink.swap(nil)
            return
        }
        startSession()
    }

    private func cleanup() {
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        finalContinuation = nil
        onPartial = nil
        settled = ""
        current = ""
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
