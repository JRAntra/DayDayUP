import Foundation
import SQLite3

/// A tiny read-only wrapper around the system SQLite library. No third-party dependencies.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    enum Value { case text(String), int(Int) }

    init(readOnlyPath path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        // Lets `LIKE 'abc%'` use the index on forms(form). English forms are stored lower-cased.
        _ = try? query("PRAGMA case_sensitive_like = ON")
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    func query(_ sql: String, _ params: [Value] = []) throws -> [[String?]] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
        defer { sqlite3_finalize(statement) }
        for (i, param) in params.enumerated() {
            switch param {
            case .text(let s): sqlite3_bind_text(statement, Int32(i + 1), s, -1, Self.transient)
            case .int(let n): sqlite3_bind_int64(statement, Int32(i + 1), Int64(n))
            }
        }
        var rows: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            rows.append((0..<count).map { column in
                guard let text = sqlite3_column_text(statement, column) else { return nil }
                return String(cString: text)
            })
        }
        return rows
    }
}

/// One entry from an offline dictionary.
struct DictEntry {
    struct RawSense: Decodable {
        var pos: String
        var en: String
        var zh: String
    }

    var headword: String
    var reading: String
    var senses: [RawSense]
}

/// Queries one of the dictionaries produced by Tools/build_dictionaries.py.
final class LocalDictionary {
    let id: DictionaryID
    private let db: SQLiteDatabase
    /// Whether the file has sound keys for "sounds like" suggestions (ECDICT format 2 and later).
    private let hasSounds: Bool

    init(id: DictionaryID, path: String) throws {
        self.id = id
        self.db = try SQLiteDatabase(readOnlyPath: path)
        // Validate the schema early so a wrong file fails at import, not at lookup.
        _ = try db.query("SELECT headword, reading, senses, rank FROM entries LIMIT 1")
        _ = try db.query("SELECT form, entry_id FROM forms LIMIT 1")
        hasSounds = !((try? db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sounds'")) ?? []).isEmpty
    }

    var entryCount: Int {
        guard let rows = try? db.query("SELECT value FROM meta WHERE key = 'entries'"),
              let value = rows.first?.first ?? nil else { return 0 }
        return Int(value) ?? 0
    }

    private static func decodeSenses(_ json: String?) -> [DictEntry.RawSense] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([DictEntry.RawSense].self, from: data)) ?? []
    }

    /// Exact lookup by any form (headword, alternative script, or kana reading).
    func lookup(_ form: String) -> [DictEntry] {
        let sql = """
            SELECT DISTINCT e.id, e.headword, e.reading, e.senses FROM forms f
            JOIN entries e ON e.id = f.entry_id
            WHERE f.form = ? ORDER BY e.rank LIMIT 12
            """
        let rows = (try? db.query(sql, [.text(form)])) ?? []
        return rows.map { row in
            DictEntry(headword: row[1] ?? form, reading: row[2] ?? "", senses: Self.decodeSenses(row[3]))
        }
    }

    /// The version of the file's layout (ECDICT: see `DictionaryBuilder.ecdictFormat`); 1 for older files.
    var format: Int {
        guard let rows = try? db.query("SELECT value FROM meta WHERE key = 'format'"),
              let value = rows.first?.first ?? nil else { return 1 }
        return Int(value) ?? 1
    }

    /// Similar words for something the dictionary doesn't have (see LOOKUP_AND_REFERENCE.md):
    /// spelling neighbours and sound-alikes first, then words that start with what was typed.
    /// In ECDICT, rare words (rank above 60k) only show when no common word matches.
    func suggestions(for form: String, limit: Int = 10) -> [String] {
        guard !form.isEmpty else { return [] }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
        }
        struct Candidate { let form: String; let distance: Int; let rank: Int }
        let length = form.count
        let maxDistance = length <= 4 ? 1 : 2

        // 1. Completions of what was typed.
        let prefixSQL = """
            SELECT f.form, MIN(e.rank) AS r FROM forms f JOIN entries e ON e.id = f.entry_id
            WHERE f.form LIKE ? ESCAPE '\\' AND f.form != ? GROUP BY f.form ORDER BY r LIMIT ?
            """
        let completions = ((try? db.query(prefixSQL, [.text(escape(form) + "%"), .text(form), .int(limit * 3)])) ?? [])
            .compactMap { row -> Candidate? in
                guard let f = row[0] else { return nil }
                return Candidate(form: f, distance: 0, rank: Int(row[1] ?? "") ?? Int.max)
            }

        // 2. Spelling neighbours: same first character, similar length, few mistakes.
        let fuzzySQL = """
            SELECT f.form, MIN(e.rank) AS r FROM forms f JOIN entries e ON e.id = f.entry_id
            WHERE f.form LIKE ? ESCAPE '\\' AND length(f.form) BETWEEN ? AND ?
            GROUP BY f.form ORDER BY r LIMIT 4000
            """
        let rows = (try? db.query(fuzzySQL, [.text(escape(String(form.prefix(1))) + "%"),
                                             .int(max(1, length - 2)), .int(length + 2)])) ?? []
        var near: [String: Candidate] = [:]
        for row in rows {
            guard let candidate = row[0], candidate != form else { continue }
            let distance = Self.editDistance(form, candidate)
            guard distance <= maxDistance else { continue }
            near[candidate] = Candidate(form: candidate, distance: distance, rank: Int(row[1] ?? "") ?? Int.max)
        }

        // 3. Sounds-like matches (English): same sound key. Any first letter, so kat finds cat.
        //    A short key (KT) matches too much, so it needs a near spelling as well; a longer key
        //    (NLJ) also brings in common words spelled quite differently (nolij → knowledge),
        //    ranked like a word with the most mistakes allowed.
        if hasSounds {
            let key = SoundKey.make(form)
            if key.count >= 2 {
                let soundRows = (try? db.query("SELECT form, MIN(rank) FROM sounds WHERE key = ? GROUP BY form ORDER BY MIN(rank) LIMIT 60",
                                               [.text(key)])) ?? []
                var soundOnly = 0
                for row in soundRows {
                    guard let candidate = row[0], candidate != form, near[candidate] == nil else { continue }
                    let rank = Int(row[1] ?? "") ?? Int.max
                    let distance = Self.editDistance(form, candidate)
                    if distance <= maxDistance {
                        near[candidate] = Candidate(form: candidate, distance: distance, rank: rank)
                    } else if key.count >= 3, rank <= DictionaryBuilder.ecdictMaxRank, soundOnly < 3 {
                        soundOnly += 1
                        near[candidate] = Candidate(form: candidate, distance: maxDistance, rank: rank)
                    }
                }
            }
        }

        // Rare words step aside when a common one matches (ECDICT has real frequency ranks).
        let filterRare = id == .ecdict
        func isRare(_ c: Candidate) -> Bool { filterRare && c.rank > DictionaryBuilder.ecdictMaxRank }
        let pool = Array(near.values) + completions
        let hideRare = filterRare && pool.contains { !isRare($0) }
        let keep: (Candidate) -> Bool = { !hideRare || !isRare($0) }

        let nearOrdered = near.values.filter(keep)
            .sorted { ($0.distance, $0.rank, $0.form) < ($1.distance, $1.rank, $1.form) }
            .map(\.form)
        let completionOrdered = completions.filter(keep).map(\.form)

        // Near-misses first (up to 5), then completions, then the remaining near-misses.
        var results: [String] = []
        for word in nearOrdered.prefix(5) + completionOrdered + nearOrdered.dropFirst(5) where !results.contains(word) {
            results.append(word)
        }
        return Array(results.prefix(limit))
    }

    /// Random common senses, used to top up quiz distractors when a table is small.
    func randomSenses(limit: Int = 300) -> [DictEntry.RawSense] {
        let rows = (try? db.query("SELECT senses FROM entries WHERE rank < 50000 ORDER BY RANDOM() LIMIT ?", [.int(limit)])) ?? []
        return rows.flatMap { Self.decodeSenses($0[0]) }
    }

    /// Edit distance where two swapped neighbouring letters count as one mistake (recieve → receive).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var before = [Int](repeating: 0, count: b.count + 1)   // row i-2
        var previous = Array(0...b.count)                      // row i-1
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, before[j - 2] + 1)
                }
                current[j] = value
            }
            (before, previous, current) = (previous, current, before)
        }
        return previous[b.count]
    }
}
