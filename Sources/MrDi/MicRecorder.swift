import AVFoundation
import Speech

/// Диктовка с микрофона с живой расшифровкой.
///
/// Слова показываются прямо во время речи: незнакомое слово обычно произносят
/// неуверенно, и увидеть, что именно расслышал распознаватель, важнее, чем ждать
/// финального результата.
@MainActor
final class MicRecorder {
    static let shared = MicRecorder()

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latestText = ""
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
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable
        else { throw TranscribeError.unavailable }
        guard Transcriber.isAuthorized else { throw TranscribeError.notAuthorized }

        latestText = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.latestText = result.bestTranscription.formattedString
                    self.onPartial?(self.latestText)
                    if result.isFinal { self.finalContinuation?.finish(self.latestText) }
                }
                if error != nil { self.finalContinuation?.finish(self.latestText) }
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Останавливает запись и отдаёт распознанный текст.
    /// Финального результата ждём недолго: обычно он уже совпадает с последним частичным.
    func stop() async -> String {
        guard isRecording else { return "" }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()

        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let box = ResumeOnceString(continuation)
            finalContinuation = box
            // распознавание могло не успеть отдать финальный результат —
            // тогда берём последний частичный, он почти всегда тот же самый
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                box.finish(self?.latestText ?? "")
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
        request?.endAudio()
        finalContinuation?.finish("")
        cleanup()
    }

    private func cleanup() {
        task?.cancel()
        task = nil
        request = nil
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
