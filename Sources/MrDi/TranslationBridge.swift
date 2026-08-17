import Foundation
import SwiftUI
import Translation

enum Direction {
    case enToRu
    case ruToEn

    var source: String { self == .enToRu ? "en" : "ru" }
    var target: String { self == .enToRu ? "ru" : "en" }

    /// Направление определяется по алфавиту, а не вероятностным определителем языка:
    /// кириллица в тексте однозначно означает русский ввод, ошибиться тут невозможно.
    static func detect(_ text: String) -> Direction {
        text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil ? .ruToEn : .enToRu
    }
}

/// Мост к системному переводчику Apple — по одному на направление.
///
/// `TranslationSession` живёт только внутри замыкания `.translationTask`, поэтому
/// держим постоянно работающий цикл: невидимая SwiftUI-вью в HUD-панели читает
/// очередь заданий и отвечает на них, пока приложение запущено. Сессия остаётся
/// «прогретой» — перевод отдаётся за десятки миллисекунд, без сети и бесплатно.
final class TranslationBridge {
    static let enToRu = TranslationBridge(direction: .enToRu)
    static let ruToEn = TranslationBridge(direction: .ruToEn)

    static func bridge(for direction: Direction) -> TranslationBridge {
        direction == .enToRu ? enToRu : ruToEn
    }

    struct Job {
        let text: String
        let reply: (Result<String, Error>) -> Void
    }

    enum Failure: Error { case unavailable }

    let direction: Direction
    private let stream: AsyncStream<Job>
    private let continuation: AsyncStream<Job>.Continuation

    private init(direction: Direction) {
        self.direction = direction
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
        // языковой пакет скачиваем заранее только для основного направления:
        // ради обратного не стоит показывать пользователю загрузку на старте
        if direction == .enToRu {
            try? await session.prepareTranslation()
        }
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
    private let direction: Direction
    @State private var configuration: TranslationSession.Configuration

    init(direction: Direction) {
        self.direction = direction
        _configuration = State(initialValue: TranslationSession.Configuration(
            source: Locale.Language(identifier: direction.source),
            target: Locale.Language(identifier: direction.target)
        ))
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                await TranslationBridge.bridge(for: direction).serve(session: session)
            }
    }
}
