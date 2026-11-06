import Foundation

// MARK: - Sense

/// One meaning of a word. A word stores an ordered list; the first is the primary sense.
struct Sense: Codable, Hashable, Identifiable {
    var id = UUID()
    /// The translation in the pair's target language. The quiz answer for the primary sense.
    var translation: String
    var partOfSpeech: String
    /// English explanation, shown as the hint in the picker and on the flashcard's English side.
    var english: String
    /// True when the translation was produced by pivoting through English (e.g. Japanese → Chinese).
    var approximate: Bool = false

    init(translation: String, partOfSpeech: String = "", english: String = "", approximate: Bool = false) {
        self.translation = translation
        self.partOfSpeech = partOfSpeech
        self.english = english
        self.approximate = approximate
    }

    enum CodingKeys: String, CodingKey { case id, translation, partOfSpeech, english, approximate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        translation = try c.decodeIfPresent(String.self, forKey: .translation) ?? ""
        partOfSpeech = try c.decodeIfPresent(String.self, forKey: .partOfSpeech) ?? ""
        english = try c.decodeIfPresent(String.self, forKey: .english) ?? ""
        approximate = try c.decodeIfPresent(Bool.self, forKey: .approximate) ?? false
    }

    /// Two senses are "the same meaning" if their translations match.
    var matchKey: String { translation.trimmingCharacters(in: .whitespaces).lowercased() }
}

enum SenseCodec {
    static func decode(_ json: String?) -> [Sense] {
        guard let data = json?.data(using: .utf8), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([Sense].self, from: data)) ?? []
    }

    static func encode(_ senses: [Sense]) -> String {
        guard let data = try? JSONEncoder().encode(senses) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A sense offered by the lookup, before the user picks it.
struct LookupCandidate: Identifiable, Hashable {
    let id = UUID()
    var sense: Sense
    /// Pinyin, kana or phonetic spelling for this sense's entry.
    var reading: String
    /// Which source produced it, e.g. "ECDICT" or "MyMemory".
    var source: String
    /// From a machine translator (Apple Translate, MyMemory): shown with a "machine translation" tag.
    var machine = false
}

// MARK: - Day keys

/// Calendar days in the user's local time zone, formatted yyyy-MM-dd.
enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func of(_ date: Date) -> String {
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static var today: String { of(Date()) }

    static func date(from key: String) -> Date? {
        formatter.timeZone = .current
        return formatter.date(from: key)
    }

    static func previous(_ key: String) -> String { adding(-1, to: key) }

    static func adding(_ days: Int, to key: String) -> String {
        guard let d = date(from: key),
              let moved = Calendar.current.date(byAdding: .day, value: days, to: d) else { return key }
        return of(moved)
    }

    /// Whole calendar days from one key to another (negative if `to` is earlier).
    static func days(from: String, to: String) -> Int {
        guard let a = date(from: from), let b = date(from: to) else { return 0 }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: a),
                                               to: Calendar.current.startOfDay(for: b)).day ?? 0
    }
}

// MARK: - Filtering

enum RememberedFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case dueToday = "Due today"
    case inReview = "In Review Book"
    case notRemembered = "Not remembered"
    case remembered = "Remembered"
    var id: String { rawValue }
}

/// Where a word list is pointed: a pair, category, folder, Unfiled, or the Review Book.
struct WordScope: Hashable {
    var pairID: UUID?
    var categoryID: UUID?
    var folderID: UUID?
    var unfiledOnly = false
    var reviewOnly = false

    static let reviewBook = WordScope(reviewOnly: true)
}

struct WordFilter: Hashable {
    var scope: WordScope
    var useDateRange = false
    var dateFrom: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    var dateTo: Date = Date()
    var remembered: RememberedFilter = .all
    var searchText = ""
}
