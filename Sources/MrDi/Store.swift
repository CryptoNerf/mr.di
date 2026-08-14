import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct ReviewCard: Identifiable {
    var entry: WordEntry
    var state: CardState?
    var id: Int64 { entry.id }
}

struct WordEntry: Identifiable, Hashable {
    var id: Int64
    var lemma: String
    var surface: String
    var translation: String
    var pos: String?
    var ipa: String?
    var senses: [Sense]
    var context: String?
    var source: String?
    var createdAt: Date
}

/// Хранилище на системном SQLite: без внешних зависимостей и без сервера.
final class Store {
    static let shared = Store()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "mrdi.store")

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MrDi", isDirectory: true)
    }

    private init() {
        Self.migrateFromPreviousName()
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let path = Self.directory.appendingPathComponent("mrdi.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            NSLog("[mrdi] не удалось открыть базу по пути \(path)")
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS words(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              lemma TEXT NOT NULL UNIQUE,
              surface TEXT NOT NULL,
              translation TEXT NOT NULL,
              pos TEXT, ipa TEXT, context TEXT, source TEXT,
              created_at REAL NOT NULL
            );
            """)
        migrate(column: "senses", type: "TEXT")
        // каждый просмотр, даже несохранённый: слова, которые смотрят повторно,
        // потом сами всплывут как кандидаты в словарь
        exec("""
            CREATE TABLE IF NOT EXISTS lookups(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              lemma TEXT NOT NULL, mode TEXT NOT NULL, at REAL NOT NULL
            );
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS srs(
              word_id INTEGER PRIMARY KEY,
              stability REAL NOT NULL,
              difficulty REAL NOT NULL,
              due REAL NOT NULL,
              last_review REAL,
              reps INTEGER NOT NULL DEFAULT 0,
              lapses INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS srs_due ON srs(due);")
        exec("""
            CREATE TABLE IF NOT EXISTS cache(
              key TEXT PRIMARY KEY, value TEXT NOT NULL, at REAL NOT NULL
            );
            """)
    }

    /// Добавление колонки в уже существующую базу пользователя.
    private func migrate(column: String, type: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(words)", -1, &stmt, nil) == SQLITE_OK else { return }
        var exists = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1), String(cString: name) == column { exists = true }
        }
        if !exists { exec("ALTER TABLE words ADD COLUMN \(column) \(type);") }
    }

    /// Приложение раньше называлось иначе — переносим уже собранные слова,
    /// чтобы переименование не стоило пользователю его словаря.
    private static func migrateFromPreviousName() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("Vocab", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: directory.path) else { return }

        try? fm.moveItem(at: old, to: directory)
        let oldDatabase = directory.appendingPathComponent("vocab.db")
        if fm.fileExists(atPath: oldDatabase.path) {
            for suffix in ["", "-wal", "-shm"] {
                try? fm.moveItem(at: directory.appendingPathComponent("vocab.db\(suffix)"),
                                 to: directory.appendingPathComponent("mrdi.db\(suffix)"))
            }
        }
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            NSLog("[mrdi] sql: \(String(cString: err))")
            sqlite3_free(err)
        }
    }

    // MARK: - Кэш переводов

    func cached(_ key: String) -> String? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM cache WHERE key = ?", -1, &stmt, nil) == SQLITE_OK
            else { return nil }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: c)
        }
    }

    func putCache(_ key: String, _ value: String) {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO cache(key,value,at) VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK
            else { return }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Слова

    @discardableResult
    func save(_ r: LookupResult) -> Bool {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                INSERT INTO words(lemma,surface,translation,pos,ipa,senses,context,source,created_at)
                VALUES(?,?,?,?,?,?,?,?,?)
                ON CONFLICT(lemma) DO UPDATE SET
                  translation=excluded.translation,
                  ipa=COALESCE(excluded.ipa, words.ipa),
                  senses=COALESCE(excluded.senses, words.senses),
                  context=COALESCE(excluded.context, words.context)
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            let sensesJSON = r.senses.isEmpty ? nil
                : (try? JSONEncoder().encode(r.senses)).flatMap { String(data: $0, encoding: .utf8) }
            sqlite3_bind_text(stmt, 1, r.lemma, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, r.surface, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, r.translation, -1, SQLITE_TRANSIENT)
            bindOptional(stmt, 4, r.pos)
            bindOptional(stmt, 5, r.ipa)
            bindOptional(stmt, 6, sensesJSON)
            bindOptional(stmt, 7, r.context)
            bindOptional(stmt, 8, r.source)
            sqlite3_bind_double(stmt, 9, Date().timeIntervalSince1970)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    func recordLookup(lemma: String, mode: String) {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "INSERT INTO lookups(lemma,mode,at) VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK
            else { return }
            sqlite3_bind_text(stmt, 1, lemma, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, mode, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func lookupCount(lemma: String) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM lookups WHERE lemma = ?", -1, &stmt, nil) == SQLITE_OK
            else { return 0 }
            sqlite3_bind_text(stmt, 1, lemma, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func isSaved(lemma: String) -> Bool {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT 1 FROM words WHERE lemma = ?", -1, &stmt, nil) == SQLITE_OK
            else { return false }
            sqlite3_bind_text(stmt, 1, lemma, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    func allWords() -> [WordEntry] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT id,lemma,surface,translation,pos,ipa,context,source,created_at,senses FROM words ORDER BY created_at DESC"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var out: [WordEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(WordEntry(
                    id: sqlite3_column_int64(stmt, 0),
                    lemma: text(stmt, 1) ?? "",
                    surface: text(stmt, 2) ?? "",
                    translation: text(stmt, 3) ?? "",
                    pos: text(stmt, 4),
                    ipa: text(stmt, 5),
                    senses: decodeSenses(text(stmt, 9)),
                    context: text(stmt, 6),
                    source: text(stmt, 7),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
                ))
            }
            return out
        }
    }

    func delete(id: Int64) {
        queue.sync {
            for sql in ["DELETE FROM words WHERE id = ?", "DELETE FROM srs WHERE word_id = ?"] {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                sqlite3_bind_int64(stmt, 1, id)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - Повторение

    /// Слова к показу: сначала те, у кого подошёл срок, затем ещё ни разу не показанные.
    func dueCards(limit: Int, now: Date = Date()) -> [ReviewCard] {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT w.id, w.lemma, w.surface, w.translation, w.pos, w.ipa, w.context,
                       w.source, w.created_at, w.senses,
                       s.stability, s.difficulty, s.due, s.last_review, s.reps, s.lapses
                FROM words w
                LEFT JOIN srs s ON s.word_id = w.id
                WHERE s.due IS NULL OR s.due <= ?
                ORDER BY (s.due IS NULL), COALESCE(s.due, w.created_at)
                LIMIT ?
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var cards: [ReviewCard] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let entry = WordEntry(
                    id: sqlite3_column_int64(stmt, 0),
                    lemma: text(stmt, 1) ?? "",
                    surface: text(stmt, 2) ?? "",
                    translation: text(stmt, 3) ?? "",
                    pos: text(stmt, 4),
                    ipa: text(stmt, 5),
                    senses: decodeSenses(text(stmt, 9)),
                    context: text(stmt, 6),
                    source: text(stmt, 7),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
                )
                var state: CardState?
                if sqlite3_column_type(stmt, 12) != SQLITE_NULL {
                    state = CardState(
                        stability: sqlite3_column_double(stmt, 10),
                        difficulty: sqlite3_column_double(stmt, 11),
                        due: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)),
                        lastReview: sqlite3_column_type(stmt, 13) == SQLITE_NULL
                            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13)),
                        reps: Int(sqlite3_column_int(stmt, 14)),
                        lapses: Int(sqlite3_column_int(stmt, 15))
                    )
                }
                cards.append(ReviewCard(entry: entry, state: state))
            }
            return cards
        }
    }

    func dueCount(now: Date = Date()) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT COUNT(*) FROM words w
                LEFT JOIN srs s ON s.word_id = w.id
                WHERE s.due IS NULL OR s.due <= ?
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// Ближайший срок среди уже назначенных — чтобы сказать, когда возвращаться.
    func nextDue(now: Date = Date()) -> Date? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT MIN(due) FROM srs WHERE due > ?", -1, &stmt, nil) == SQLITE_OK
            else { return nil }
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL
            else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    func saveCard(wordID: Int64, state: CardState) {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                INSERT INTO srs(word_id, stability, difficulty, due, last_review, reps, lapses)
                VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(word_id) DO UPDATE SET
                  stability=excluded.stability, difficulty=excluded.difficulty,
                  due=excluded.due, last_review=excluded.last_review,
                  reps=excluded.reps, lapses=excluded.lapses
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, wordID)
            sqlite3_bind_double(stmt, 2, state.stability)
            sqlite3_bind_double(stmt, 3, state.difficulty)
            sqlite3_bind_double(stmt, 4, state.due.timeIntervalSince1970)
            if let last = state.lastReview {
                sqlite3_bind_double(stmt, 5, last.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_int(stmt, 6, Int32(state.reps))
            sqlite3_bind_int(stmt, 7, Int32(state.lapses))
            sqlite3_step(stmt)
        }
    }

    private func decodeSenses(_ json: String?) -> [Sense] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Sense].self, from: data)) ?? []
    }

    private func bindOptional(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}
