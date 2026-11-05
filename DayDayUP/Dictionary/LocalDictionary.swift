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

    init(id: DictionaryID, path: String) throws {
        self.id = id
        self.db = try SQLiteDatabase(readOnlyPath: path)
        // Validate the schema early so a wrong file fails at import, not at lookup.
        _ = try db.query("SELECT headword, reading, senses, rank FROM entries LIMIT 1")
        _ = try db.query("SELECT form, entry_id FROM forms LIMIT 1")
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

    /// Words that start with what was typed, plus near-misses for typos (Question 2.3).
    func suggestions(for form: String, limit: Int = 10) -> [String] {
        guard !form.isEmpty else { return [] }
        let escaped = form.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        var results: [String] = []

        // 1. Completions of what was typed.
        let prefixSQL = """
            SELECT f.form, MIN(e.rank) AS r FROM forms f JOIN entries e ON e.id = f.entry_id
            WHERE f.form LIKE ? ESCAPE '\\' AND f.form != ? GROUP BY f.form ORDER BY r LIMIT ?
            """
        for row in (try? db.query(prefixSQL, [.text(escaped + "%"), .text(form), .int(limit)])) ?? [] {
            if let f = row[0] { results.append(f) }
        }

        // 2. Spelling neighbours: same first character, similar length, edit distance ≤ 2.
        let first = String(form.prefix(1)).replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let length = form.count
        let fuzzySQL = """
            SELECT f.form, MIN(e.rank) AS r FROM forms f JOIN entries e ON e.id = f.entry_id
            WHERE f.form LIKE ? ESCAPE '\\' AND length(f.form) BETWEEN ? AND ?
            GROUP BY f.form ORDER BY r LIMIT 4000
            """
        let rows = (try? db.query(fuzzySQL, [.text(first + "%"), .int(max(1, length - 2)), .int(length + 2)])) ?? []
        let scored = rows.compactMap { row -> (String, Int, Int)? in
            guard let candidate = row[0], candidate != form else { return nil }
            let distance = Self.editDistance(form, candidate)
            guard distance <= (length <= 4 ? 1 : 2) else { return nil }
            return (candidate, distance, Int(row[1] ?? "") ?? Int.max)
        }
        .sorted { ($0.1, $0.2) < ($1.1, $1.2) }

        for (candidate, _, _) in scored where !results.contains(candidate) {
            results.append(candidate)
        }
        // Near-misses first when the prefix list is crowded with long completions.
        let fuzzy = scored.map(\.0)
        let ordered = fuzzy.prefix(5) + results.filter { !fuzzy.prefix(5).contains($0) }
        return Array(ordered.prefix(limit))
    }

    /// Random common senses, used to top up quiz distractors when a table is small.
    func randomSenses(limit: Int = 300) -> [DictEntry.RawSense] {
        let rows = (try? db.query("SELECT senses FROM entries WHERE rank < 50000 ORDER BY RANDOM() LIMIT ?", [.int(limit)])) ?? []
        return rows.flatMap { Self.decodeSenses($0[0]) }
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
