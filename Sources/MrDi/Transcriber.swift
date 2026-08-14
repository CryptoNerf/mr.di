import AVFoundation
import Speech

enum TranscribeError: LocalizedError {
    case notAuthorized
    case unavailable
    case nothingHeard

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Нужен доступ: Системные настройки → Конфиденциальность и безопасность → Распознавание речи"
        case .unavailable: return "Распознавание речи недоступно"
        case .nothingHeard: return "В последних секундах не разобрать речь"
        }
    }
}

/// Распознавание английской речи из готового куска аудио.
/// Работает на устройстве — бесплатно, офлайн и без отправки звука куда-либо.
enum Transcriber {

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        guard isAuthorized else { throw TranscribeError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable
        else { throw TranscribeError.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { cont in
            let box = ResumeOnce(cont)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    box.finish(.failure(error))
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                box.finish(text.isEmpty ? .failure(TranscribeError.nothingHeard) : .success(text))
            }
            request.append(buffer)
            request.endAudio()

            // страховка от зависшей задачи распознавания
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if box.finish(.failure(TranscribeError.nothingHeard)) { task.cancel() }
            }
        }
    }
}

/// Колбэк распознавания может прийти несколько раз — продолжение возобновляем строго один раз.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ result: Result<String, Error>) -> Bool {
        lock.lock()
        guard let continuation else { lock.unlock(); return false }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
