import Foundation
import SwiftUI
import Translation

/// Мост к системному переводчику Apple.
///
/// `TranslationSession` живёт только внутри замыкания `.translationTask`, поэтому
/// держим постоянно работающий цикл: невидимая SwiftUI-вью в HUD-панели читает
/// очередь заданий и отвечает на них, пока приложение запущено. Сессия остаётся
/// «прогретой» — перевод отдаётся за десятки миллисекунд, без сети и бесплатно.
final class TranslationBridge {
    static let shared = TranslationBridge()

    struct Job {
        let text: String
        let reply: (Result<String, Error>) -> Void
    }

    enum Failure: Error { case unavailable }

    private let stream: AsyncStream<Job>
    private let continuation: AsyncStream<Job>.Continuation

    private init() {
        var c: AsyncStream<Job>.Continuation!
        stream = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    func translate(_ text: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            continuation.yield(Job(text: text) { cont.resume(with: $0) })
        }
    }

    /// Вызывается изнутри `.translationTask`, держит очередь живой.
    func serve(session: TranslationSession) async {
        try? await session.prepareTranslation()
        for await job in stream {
            do {
                let response = try await session.translate(job.text)
                job.reply(.success(response.targetText))
            } catch {
                job.reply(.failure(error))
            }
        }
    }
}

/// Невидимая вью-подложка, к которой прицеплена сессия перевода.
struct TranslationHost: View {
    @State private var configuration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "ru")
    )

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                await TranslationBridge.shared.serve(session: session)
            }
    }
}
