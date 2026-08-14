import Foundation

struct Sense: Codable, Hashable {
    var pos: String
    var definition: String
    var example: String?
}

/// Словарная статья: транскрипция и значения на английском.
///
/// Берётся из открытого API поверх Wiktionary и навсегда оседает в локальном кэше —
/// одно и то же слово ходит в сеть ровно один раз, дальше работает офлайн.
/// Перевод при этом не зависит от сети вообще: он приходит от системного переводчика,
/// а статья лишь дополняет его, когда доедет.
enum DictionaryService {

    struct Entry: Codable {
        var ipa: String?
        var senses: [Sense]

        var isEmpty: Bool { ipa == nil && senses.isEmpty }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func entry(for word: String) async -> Entry? {
        let key = "dict:" + word.lowercased()

        if let cached = Store.shared.cached(key) {
            guard cached != "-" else { return nil }   // отрицательный кэш: слова нет в словаре
            return try? JSONDecoder().decode(Entry.self, from: Data(cached.utf8))
        }

        guard let encoded = word.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)")
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue("MrDi/0.1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                Store.shared.putCache(key, "-")
                return nil
            }
            let payload = try JSONDecoder().decode([RemoteEntry].self, from: data)
            let entry = build(from: payload)
            guard !entry.isEmpty else {
                Store.shared.putCache(key, "-")
                return nil
            }
            if let encodedEntry = try? JSONEncoder().encode(entry),
               let json = String(data: encodedEntry, encoding: .utf8) {
                Store.shared.putCache(key, json)
            }
            return entry
        } catch {
            return nil   // сеть недоступна — молча обходимся переводом
        }
    }

    // MARK: - Разбор ответа

    private struct RemoteEntry: Decodable {
        struct Phonetic: Decodable { var text: String? }
        struct Meaning: Decodable {
            struct Definition: Decodable {
                var definition: String
                var example: String?
            }
            var partOfSpeech: String
            var definitions: [Definition]
        }
        var phonetics: [Phonetic]?
        var meanings: [Meaning]?
    }

    private static func build(from payload: [RemoteEntry]) -> Entry {
        let ipa = payload
            .flatMap { $0.phonetics ?? [] }
            .compactMap { $0.text }
            .first { !$0.isEmpty }

        // по два значения на часть речи и не больше четырёх всего:
        // подсказка должна читаться за секунду, а не быть словарной страницей
        var senses: [Sense] = []
        for entry in payload {
            for meaning in entry.meanings ?? [] {
                let pos = russianPOS(meaning.partOfSpeech)
                for definition in meaning.definitions.prefix(2) {
                    guard senses.count < 4 else { break }
                    let text = definition.definition.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !senses.contains(where: { $0.definition == text }) else { continue }
                    senses.append(Sense(pos: pos, definition: text, example: definition.example))
                }
            }
        }
        return Entry(ipa: ipa, senses: senses)
    }

    static func russianPOS(_ english: String) -> String {
        switch english.lowercased() {
        case "noun": return "сущ."
        case "verb": return "гл."
        case "adjective": return "прил."
        case "adverb": return "нареч."
        case "preposition": return "предлог"
        case "pronoun": return "мест."
        case "conjunction": return "союз"
        case "interjection", "exclamation": return "межд."
        case "numeral": return "числ."
        default: return english.lowercased()
        }
    }
}
