import Foundation
import NaturalLanguage

struct LookupResult {
    var surface: String          // как встретилось в тексте или прозвучало
    var lemma: String            // всегда английская сторона, в словарной форме
    var translation: String      // всегда русская сторона
    var direction: Direction = .enToRu
    var pos: String?
    var ipa: String?
    var senses: [Sense] = []
    var context: String?
    var contextTranslation: String?
    var source: String?
    var isPhrase: Bool

    /// Главная строка подсказки — то, чего пользователь не знает.
    /// Спросили по-английски — это перевод, спросили по-русски — само английское слово.
    var primary: String { direction == .enToRu ? translation : lemma }
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

        switch Direction.detect(surface) {
        case .enToRu:
            return await englishLookup(surface: surface, isPhrase: isPhrase, capture: capture, mode: mode)
        case .ruToEn:
            return await russianLookup(surface: surface, isPhrase: isPhrase, capture: capture, mode: mode)
        }
    }

    /// Спросили английское слово — нужен его русский перевод.
    private static func englishLookup(surface: String, isPhrase: Bool,
                                      capture: Capture, mode: String) async -> Result<LookupResult, Error> {
        let lemma = isPhrase ? surface : lemmatize(surface, language: .english)
        let pos = isPhrase ? nil : partOfSpeech(surface)

        Store.shared.recordLookup(lemma: lemma.lowercased(), mode: mode)

        var result = LookupResult(surface: surface, lemma: lemma, translation: "",
                                  direction: .enToRu, pos: pos, ipa: nil,
                                  context: capture.context, source: capture.sourceApp,
                                  isPhrase: isPhrase)

        let key = "en-ru:" + lemma.lowercased()
        if let hit = Store.shared.cached(key) {
            result.translation = hit
            return .success(result)
        }
        do {
            let translation = try await TranslationBridge.enToRu.translate(lemma)
            Store.shared.putCache(key, translation)
            result.translation = translation
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    /// Сказали русское слово — нужно английское. В словарь при этом всё равно ложится
    /// карточка «английское слово → русское»: словарь остаётся английским независимо
    /// от того, с какой стороны о слове спросили.
    private static func russianLookup(surface: String, isPhrase: Bool,
                                      capture: Capture, mode: String) async -> Result<LookupResult, Error> {
        let key = "ru-en:" + surface.lowercased()
        let english: String
        if let hit = Store.shared.cached(key) {
            english = hit
        } else {
            do {
                english = try await TranslationBridge.ruToEn.translate(surface)
                Store.shared.putCache(key, english)
            } catch {
                return .failure(error)
            }
        }

        let lemma = isPhrase ? english : lemmatize(english, language: .english)
        let russian = isPhrase ? surface : lemmatize(surface, language: .russian)
        Store.shared.recordLookup(lemma: lemma.lowercased(), mode: mode)

        return .success(LookupResult(surface: surface, lemma: lemma, translation: russian,
                                     direction: .ruToEn,
                                     pos: isPhrase ? nil : partOfSpeech(english),
                                     ipa: nil, context: capture.context,
                                     source: capture.sourceApp, isPhrase: isPhrase))
    }

    /// Перевод предложения-контекста — только подсказка о смысле, поэтому идёт следом.
    static func contextTranslation(_ context: String?) async -> String? {
        guard let context, context.count < 400 else { return nil }
        let key = "en-ru-ctx:" + String(context.hashValue)
        if let hit = Store.shared.cached(key) { return hit }
        guard let translated = try? await TranslationBridge.enToRu.translate(context) else { return nil }
        Store.shared.putCache(key, translated)
        return translated
    }

    static func lemmatize(_ word: String, language: NLLanguage) -> String {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        tagger.setLanguage(language, range: word.startIndex..<word.endIndex)
        let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma)
        if let lemma = tag?.rawValue, !lemma.isEmpty { return lemma }
        return word
    }

    static func partOfSpeech(_ word: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = word
        tagger.setLanguage(.english, range: word.startIndex..<word.endIndex)
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
