import AppKit
import NaturalLanguage

struct LookupResult {
    var surface: String          // как встретилось в тексте или прозвучало
    var lemma: String            // всегда английская сторона, в словарной форме
    var translation: String      // всегда русская сторона
    /// Второй вариант от точного режима переводчика, если он расходится с первым.
    var alternative: String?
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
    /// `record: false` — для ввода с клавиатуры: каждое промежуточное слово по мере
    /// набора не должно попадать в историю просмотров.
    static func base(_ capture: Capture, mode: String, record: Bool = true) async -> Result<LookupResult, Error> {
        let raw = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failure(LookupError.empty) }

        let isPhrase = raw.split(whereSeparator: { $0 == " " || $0 == "\n" }).count > 1
        let surface = isPhrase ? raw : raw.trimmingCharacters(in: .punctuationCharacters)

        switch Direction.detect(surface) {
        case .enToRu:
            return await englishLookup(surface: surface, isPhrase: isPhrase, capture: capture,
                                       mode: mode, record: record)
        case .ruToEn:
            return await russianLookup(surface: surface, isPhrase: isPhrase, capture: capture,
                                       mode: mode, record: record)
        }
    }

    /// Спросили английское слово — нужен его русский перевод.
    private static func englishLookup(surface: String, isPhrase: Bool,
                                      capture: Capture, mode: String,
                                      record: Bool) async -> Result<LookupResult, Error> {
        let lemma = isPhrase ? surface : lemmatize(surface, language: .english)
        let pos = isPhrase ? nil : partOfSpeech(surface)

        if record { Store.shared.recordLookup(lemma: lemma.lowercased(), mode: mode) }

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
                                      capture: Capture, mode: String,
                                      record: Bool) async -> Result<LookupResult, Error> {
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

        let headword = isPhrase ? english : englishHeadword(english)
        let englishPhrase = headword.contains(" ")
        let lemma = englishPhrase ? headword : lemmatize(headword, language: .english)
        let russian = isPhrase ? surface : lemmatize(surface, language: .russian)
        if record { Store.shared.recordLookup(lemma: lemma.lowercased(), mode: mode) }

        return .success(LookupResult(surface: surface, lemma: lemma, translation: russian,
                                     direction: .ruToEn,
                                     pos: englishPhrase ? nil : partOfSpeech(headword, in: english),
                                     ipa: nil, context: capture.context,
                                     source: capture.sourceApp, isPhrase: englishPhrase))
    }

    /// Глагол в личной форме переводчик отдаёт с местоимением: «бегу» → «I run»,
    /// «прокрастинирую» → «I procrastinate», а инфинитив — с «to». Для одного
    /// русского слова нужно одно английское, иначе в словарь попадёт «I».
    /// Что осталось после местоимения — то и слово: «I give up» → «give up».
    static func englishHeadword(_ english: String) -> String {
        let leading: Set<String> = ["i", "you", "he", "she", "it", "we", "they", "to",
                                    "i'm", "you're", "he's", "she's", "it's", "we're", "they're",
                                    "i’m", "you’re", "he’s", "she’s", "it’s", "we’re", "they’re"]
        var words = english.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(separator: " ").map(String.init)
        while words.count > 1, leading.contains(words[0].lowercased()) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// Перевод предложения-контекста — только подсказка о смысле, поэтому идёт следом.
    /// Целое предложение точный режим переводит заметно лучше, а спешить тут некуда.
    static func contextTranslation(_ context: String?) async -> String? {
        guard let context, context.count < 400 else { return nil }
        let precise = TranslationBridge.supportsPrecise
        let key = (precise ? "en-ru-ctx-hq:" : "en-ru-ctx:") + String(context.hashValue)
        if let hit = Store.shared.cached(key) { return hit }
        let bridge = precise ? TranslationBridge.enToRuPrecise : TranslationBridge.enToRu
        guard let translated = try? await bridge.translate(context) else { return nil }
        Store.shared.putCache(key, translated)
        return translated
    }

    /// Второй вариант перевода английского слова — от точного режима.
    /// nil, если режима нет в системе или он сказал то же самое, что быстрый.
    static func alternative(for result: LookupResult) async -> String? {
        guard TranslationBridge.supportsPrecise, result.direction == .enToRu, !result.isPhrase,
              !result.translation.isEmpty
        else { return nil }
        let key = "en-ru-hq:" + result.lemma.lowercased()
        let precise: String
        if let hit = Store.shared.cached(key) {
            precise = hit
        } else {
            guard let translated = try? await TranslationBridge.enToRuPrecise.translate(result.lemma) else { return nil }
            Store.shared.putCache(key, translated)
            precise = translated
        }
        guard !isSameMeaning(result.translation, precise) else { return nil }
        // точный режим иногда выдумывает слова (handle → «обергать»):
        // несуществующее слово хуже, чем никакого второго варианта
        guard await MainActor.run(body: { isRealRussian(precise) }) else { return nil }
        return precise
    }

    @MainActor
    private static func isRealRussian(_ text: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: text, startingAt: 0, language: "ru", wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    /// Быстрый режим часто перечисляет формы через запятую («Развёртывать, развернуть»):
    /// если точный назвал одну из них, второй вариант ничего нового не скажет.
    private static func isSameMeaning(_ fast: String, _ precise: String) -> Bool {
        func normalized(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        let candidate = normalized(precise)
        guard !candidate.isEmpty else { return true }
        let variants = fast.split(whereSeparator: { $0 == "," || $0 == ";" }).map { normalized(String($0)) }
        return normalized(fast) == candidate || variants.contains(candidate)
    }

    static func lemmatize(_ word: String, language: NLLanguage) -> String {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        tagger.setLanguage(language, range: word.startIndex..<word.endIndex)
        let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma)
        if let lemma = tag?.rawValue, !lemma.isEmpty { return lemma }
        return word
    }

    /// `phrase` — перевод, из которого взято слово: «procrastinate» в одиночку
    /// теггер считает существительным, а в «I procrastinate» видит глагол.
    static func partOfSpeech(_ word: String, in phrase: String? = nil) -> String? {
        let text = phrase ?? word
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        let at = text.range(of: word, options: [.caseInsensitive, .backwards])?.lowerBound ?? text.startIndex
        let (tag, _) = tagger.tag(at: at, unit: .word, scheme: .lexicalClass)
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
