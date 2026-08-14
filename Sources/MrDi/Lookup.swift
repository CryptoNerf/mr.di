import Foundation
import NaturalLanguage

struct LookupResult {
    var surface: String          // как встретилось в тексте
    var lemma: String            // словарная форма
    var translation: String
    var pos: String?
    var ipa: String?
    var senses: [Sense] = []
    var context: String?
    var contextTranslation: String?
    var source: String?
    var isPhrase: Bool
}

enum Lookup {

    /// Быстрый путь: только то, что нужно показать в первые миллисекунды.
    /// Транскрипция, значения и перевод предложения доезжают следом и дописываются в панель —
    /// пользователь не должен ждать сеть, чтобы увидеть перевод слова.
    static func base(_ capture: Capture, mode: String) async -> Result<LookupResult, Error> {
        let raw = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failure(LookupError.empty) }

        let isPhrase = raw.split(whereSeparator: { $0 == " " || $0 == "\n" }).count > 1
        let surface = isPhrase ? raw : raw.trimmingCharacters(in: .punctuationCharacters)
        let lemma = isPhrase ? surface : lemmatize(surface)
        let pos = isPhrase ? nil : partOfSpeech(surface)

        Store.shared.recordLookup(lemma: lemma.lowercased(), mode: mode)

        var result = LookupResult(surface: surface, lemma: lemma, translation: "",
                                  pos: pos, ipa: nil, context: capture.context,
                                  source: capture.sourceApp, isPhrase: isPhrase)

        let key = "en-ru:" + lemma.lowercased()
        if let hit = Store.shared.cached(key) {
            result.translation = hit
            return .success(result)
        }

        do {
            let translation = try await TranslationBridge.shared.translate(lemma)
            Store.shared.putCache(key, translation)
            result.translation = translation
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    /// Перевод предложения-контекста — только подсказка о смысле, поэтому идёт следом.
    static func contextTranslation(_ context: String?) async -> String? {
        guard let context, context.count < 400 else { return nil }
        let key = "en-ru-ctx:" + String(context.hashValue)
        if let hit = Store.shared.cached(key) { return hit }
        guard let translated = try? await TranslationBridge.shared.translate(context) else { return nil }
        Store.shared.putCache(key, translated)
        return translated
    }

    static func lemmatize(_ word: String) -> String {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma)
        if let lemma = tag?.rawValue, !lemma.isEmpty { return lemma }
        return word
    }

    static func partOfSpeech(_ word: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = word
        let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lexicalClass)
        switch tag {
        case .noun?: return "сущ."
        case .verb?: return "гл."
        case .adjective?: return "прил."
        case .adverb?: return "нареч."
        case .preposition?: return "предлог"
        case .pronoun?: return "мест."
        case .conjunction?: return "союз"
        default: return nil
        }
    }
}

enum LookupError: LocalizedError {
    case empty
    case noSelection

    var errorDescription: String? {
        switch self {
        case .empty: return "Пустое выделение"
        case .noSelection: return "Не удалось получить выделенный текст"
        }
    }
}
