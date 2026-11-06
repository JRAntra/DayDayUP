import CoreData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File documents

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // A UTF-8 byte-order mark helps Excel open Chinese and Japanese correctly.
        FileWrapper(regularFileWithContents: Data("\u{FEFF}".utf8) + Data(text.utf8))
    }
}

// MARK: - Full backup

/// One JSON file holding everything: tables, progress, Review Book, streak, achievements and settings.
/// The same record shapes are the intended wire format for a future custom sync backend.
struct BackupFile: Codable {
    struct Pair: Codable { var id: UUID; var from: String; var to: String; var script: String; var accent: String; var sortIndex: Int64; var createdAt: Date? }
    struct Category: Codable {
        var id: UUID; var pairID: UUID; var name: String; var sortIndex: Int64; var createdAt: Date?
        /// Added in backup version 4.
        var referenceOnly: Bool? = nil
    }
    struct Folder: Codable { var id: UUID; var categoryID: UUID; var name: String; var sortIndex: Int64; var createdAt: Date? }
    struct Word: Codable {
        var id: UUID; var categoryID: UUID; var folderID: UUID?
        var term: String; var termKey: String; var reading: String; var senses: [Sense]
        var example: String; var notes: String
        var ring: Int16; var lastCorrectDay: String?; var inReview: Bool; var timesMissed: Int32
        var rememberedAt: Date?; var createdAt: Date?; var updatedAt: Date?
        /// Review ladder, added in backup version 2. Missing in older backups, whose ring is mapped instead.
        var step: Int16? = nil; var dueDay: String? = nil; var startedDay: String? = nil
    }
    struct Activity: Codable {
        var day: String; var quizzes: Int32; var remembered: Int32; var added: Int32
        /// Added in backup version 2; older backups use the old streak rule.
        var streakEarned: Bool? = nil
        /// Added in backup version 3: answers per language pair that day, pair id → [correct, missed].
        var answers: [String: [Int]]? = nil
    }
    struct Achievement: Codable { var key: String; var unlockedAt: Date? }

    /// Kept from the app's former name, VocaQuest, so old and new backups restore either way.
    var format = "vocaquest-backup"
    /// 2 added the review schedule (word step / due day / started day, and the streak flag per day).
    /// 3 added the daily answer counts per language pair.
    /// 4 added reference-only categories.
    var version = 4
    var exportedAt = Date()
    var pairs: [Pair] = []
    var categories: [Category] = []
    var folders: [Folder] = []
    var words: [Word] = []
    var activity: [Activity] = []
    var achievements: [Achievement] = []
    var settings: [String: String] = [:]
}

@MainActor
enum BackupService {
    /// UserDefaults keys that travel with a backup.
    private static let settingKeys = ["lookup.myMemoryEmail"]

    static func makeBackup(context: NSManagedObjectContext) throws -> Data {
        func all<T: NSManagedObject>(_ type: T.Type) -> [T] {
            let request = NSFetchRequest<T>(entityName: String(describing: type))
            request.predicate = NSPredicate(format: "deletedAt == nil")
            return (try? context.fetch(request)) ?? []
        }
        var file = BackupFile()
        file.pairs = all(LanguagePairMO.self).map {
            BackupFile.Pair(id: $0.uuid, from: $0.fromCode ?? "en", to: $0.toCode ?? "zh", script: $0.script ?? "simplified",
                  accent: $0.accentHex ?? "1FA2FF", sortIndex: $0.sortIndex, createdAt: $0.createdAt)
        }
        file.categories = all(CategoryMO.self).compactMap { c -> BackupFile.Category? in
            guard let pairID = c.pair?.id else { return nil }
            return .init(id: c.uuid, pairID: pairID, name: c.displayName, sortIndex: c.sortIndex, createdAt: c.createdAt,
                         referenceOnly: c.referenceOnly)
        }
        file.folders = all(FolderMO.self).compactMap { f -> BackupFile.Folder? in
            guard let categoryID = f.category?.id else { return nil }
            return .init(id: f.uuid, categoryID: categoryID, name: f.displayName, sortIndex: f.sortIndex, createdAt: f.createdAt)
        }
        file.words = all(WordMO.self).compactMap { w -> BackupFile.Word? in
            guard let categoryID = w.category?.id else { return nil }
            return .init(id: w.uuid, categoryID: categoryID, folderID: w.folder?.deletedAt == nil ? w.folder?.id : nil,
                         term: w.termValue, termKey: w.termKey ?? "", reading: w.readingValue, senses: w.senses,
                         example: w.example ?? "", notes: w.notes ?? "", ring: w.ring, lastCorrectDay: w.lastCorrectDay,
                         inReview: w.inReview, timesMissed: w.timesMissed, rememberedAt: w.rememberedAt,
                         createdAt: w.createdAt, updatedAt: w.updatedAt,
                         step: w.step, dueDay: w.dueDay, startedDay: w.startedDay)
        }
        file.activity = all(DailyActivityMO.self).map {
            BackupFile.Activity(day: $0.dayKey ?? "", quizzes: $0.quizzesCompleted, remembered: $0.wordsRemembered,
                                added: $0.wordsAdded, streakEarned: $0.streakEarned, answers: $0.answerCounts)
        }
        file.achievements = all(AchievementMO.self).map { BackupFile.Achievement(key: $0.key ?? "", unlockedAt: $0.unlockedAt) }
        for key in settingKeys { if let value = UserDefaults.standard.string(forKey: key) { file.settings[key] = value } }
        if let sources = UserDefaults.standard.data(forKey: "lookup.sources") {
            file.settings["lookup.sources"] = sources.base64EncodedString()
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    static func decode(_ data: Data) throws -> BackupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(BackupFile.self, from: data)
        guard file.format == "vocaquest-backup" else {
            throw NSError(domain: "Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file isn't a DayDayUP backup."])
        }
        return file
    }

    /// Saves a safety copy of the current data before a restore replaces it.
    @discardableResult
    static func writeSafetyBackup(context: NSManagedObjectContext) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("VocaQuest/Safety Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let url = folder.appendingPathComponent("Before restore \(formatter.string(from: Date())).json")
        try makeBackup(context: context).write(to: url)
        return url
    }

    /// Replaces all data with the backup's contents.
    static func restore(_ file: BackupFile, repository: VocabRepository) {
        let context = repository.context
        repository.wipeAll()

        var pairs: [UUID: LanguagePairMO] = [:]
        for p in file.pairs {
            let pair = LanguagePairMO(context: context)
            pair.id = p.id; pair.createdAt = p.createdAt ?? Date(); pair.updatedAt = Date()
            pair.fromCode = p.from; pair.toCode = p.to; pair.script = p.script; pair.accentHex = p.accent; pair.sortIndex = p.sortIndex
            pairs[p.id] = pair
        }
        var categories: [UUID: CategoryMO] = [:]
        for c in file.categories {
            guard let pair = pairs[c.pairID] else { continue }
            let category = CategoryMO(context: context)
            category.id = c.id; category.createdAt = c.createdAt ?? Date(); category.updatedAt = Date()
            category.name = c.name; category.sortIndex = c.sortIndex; category.pair = pair
            category.referenceOnly = c.referenceOnly ?? false
            categories[c.id] = category
        }
        var folders: [UUID: FolderMO] = [:]
        for f in file.folders {
            guard let category = categories[f.categoryID] else { continue }
            let folder = FolderMO(context: context)
            folder.id = f.id; folder.createdAt = f.createdAt ?? Date(); folder.updatedAt = Date()
            folder.name = f.name; folder.sortIndex = f.sortIndex; folder.category = category
            folders[f.id] = folder
        }
        var legacyIndex = 0
        for w in file.words {
            guard let category = categories[w.categoryID] else { continue }
            let word = WordMO(context: context)
            word.id = w.id; word.createdAt = w.createdAt ?? Date(); word.updatedAt = w.updatedAt ?? Date()
            word.term = w.term; word.termKey = w.termKey.isEmpty ? repository.termKey(w.term, in: category) : w.termKey
            word.reading = w.reading; word.sensesJSON = SenseCodec.encode(w.senses)
            word.example = w.example; word.notes = w.notes
            word.ring = w.ring; word.lastCorrectDay = w.lastCorrectDay; word.inReview = w.inReview
            word.timesMissed = w.timesMissed; word.rememberedAt = w.rememberedAt
            if let step = w.step {
                word.step = step; word.dueDay = w.dueDay; word.startedDay = w.startedDay
            } else if let state = ReviewSchedule.fromLegacy(ring: Int(w.ring), inReview: w.inReview,
                                                            lastCorrectDay: w.lastCorrectDay, spreadIndex: legacyIndex) {
                // A backup from before the review ladder: same mapping as the one-time upgrade.
                word.schedule = state
                if !state.isRemembered { word.rememberedAt = nil }
                legacyIndex += 1
            }
            word.category = category
            word.folder = w.folderID.flatMap { folders[$0] }
        }
        for a in file.activity {
            let record = DailyActivityMO(context: context)
            record.stampNew(); record.dayKey = a.day
            record.quizzesCompleted = a.quizzes; record.wordsRemembered = a.remembered; record.wordsAdded = a.added
            record.streakEarned = a.streakEarned ?? record.earnedUnderOldRule
            record.answerCounts = a.answers ?? [:]
        }
        for a in file.achievements {
            let record = AchievementMO(context: context)
            record.stampNew(); record.key = a.key; record.unlockedAt = a.unlockedAt
        }
        for key in settingKeys { if let value = file.settings[key] { UserDefaults.standard.set(value, forKey: key) } }
        if let encoded = file.settings["lookup.sources"], let data = Data(base64Encoded: encoded) {
            UserDefaults.standard.set(data, forKey: "lookup.sources")
        }
        repository.save()
    }
}

// MARK: - CSV

enum DuplicateRule: String, CaseIterable, Identifiable {
    case merge = "Merge meanings"
    case skip = "Skip"
    case replace = "Replace"
    var id: String { rawValue }

    var detail: String {
        switch self {
        case .merge: return "Add new meanings after the ones you already have. Your primary meaning stays first."
        case .skip: return "Keep the word as it is and ignore the imported row."
        case .replace: return "Overwrite the word's meanings, reading and notes. Progress is kept."
        }
    }
}

struct CSVImportSummary {
    var added = 0
    var merged = 0
    var skipped = 0
    var replaced = 0
    var foldersCreated = 0
    var invalidRows = 0

    var message: String {
        var parts = ["\(added) added"]
        if merged > 0 { parts.append("\(merged) merged") }
        if replaced > 0 { parts.append("\(replaced) replaced") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if foldersCreated > 0 { parts.append("\(foldersCreated) folders created") }
        if invalidRows > 0 { parts.append("\(invalidRows) rows without a word were ignored") }
        return parts.joined(separator: ", ") + "."
    }
}

@MainActor
enum CSVService {
    static let header = ["word", "reading", "part_of_speech", "translation", "english_explanation",
                         "notes", "example", "folder", "date_added"]
    static let senseSeparator = "; "

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func export(_ words: [WordMO]) -> String {
        var lines = [header.joined(separator: ",")]
        for word in words.sorted(by: { $0.addedDate < $1.addedDate }) {
            let senses = word.senses
            let row = [
                word.termValue,
                word.readingValue,
                senses.map(\.partOfSpeech).joined(separator: senseSeparator),
                senses.map(\.translation).joined(separator: senseSeparator),
                senses.map(\.english).joined(separator: senseSeparator),
                word.notes ?? "",
                word.example ?? "",
                word.folder?.displayName ?? "",
                dateFormatter.string(from: word.addedDate),
            ]
            lines.append(row.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// RFC 4180 parser: quoted fields, escaped quotes, and line breaks inside quotes.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.replacingOccurrences(of: "\u{FEFF}", with: "").makeIterator()
        var pending: Character? = nil

        while let ch = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r\n", "\n", "\r":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.append(ch)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func importCSV(_ text: String, into category: CategoryMO, rule: DuplicateRule,
                          repository: VocabRepository) -> CSVImportSummary {
        var summary = CSVImportSummary()
        var rows = parse(text)
        guard !rows.isEmpty else { return summary }

        // Map columns by header name so hand-made spreadsheets with other column orders still work.
        let first = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var columns: [String: Int] = [:]
        if first.contains("word") {
            for (i, name) in first.enumerated() { columns[name] = i }
            rows.removeFirst()
        } else {
            for (i, name) in header.enumerated() { columns[name] = i }
        }
        func value(_ row: [String], _ name: String) -> String {
            guard let i = columns[name], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func split(_ text: String) -> [String] {
            text.isEmpty ? [] : text.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        for row in rows {
            let term = value(row, "word")
            guard !term.isEmpty else { summary.invalidRows += 1; continue }

            let translations = split(value(row, "translation"))
            let poses = split(value(row, "part_of_speech"))
            let englishRaw = value(row, "english_explanation")
            var englishes = split(englishRaw)
            if englishes.count != translations.count {
                englishes = translations.indices.map { $0 == 0 ? englishRaw : "" }
            }
            let senses = translations.enumerated().map { i, t in
                Sense(translation: t, partOfSpeech: i < poses.count ? poses[i] : "", english: i < englishes.count ? englishes[i] : "")
            }

            var folder: FolderMO?
            let folderName = value(row, "folder")
            if !folderName.isEmpty {
                let before = category.liveFolders.count
                folder = try? repository.createFolder(named: folderName, in: category)
                if category.liveFolders.count > before { summary.foldersCreated += 1 }
            }

            if let existing = repository.existingWord(term: term, in: category) {
                switch rule {
                case .skip:
                    summary.skipped += 1
                case .merge:
                    repository.mergeSenses(senses, into: existing)
                    summary.merged += 1
                case .replace:
                    existing.senses = senses
                    existing.reading = value(row, "reading")
                    existing.notes = value(row, "notes")
                    existing.example = value(row, "example")
                    if let folder { existing.folder = folder }
                    existing.touch()
                    summary.replaced += 1
                }
                continue
            }

            let word = repository.addWord(term: term, reading: value(row, "reading"), senses: senses,
                                          category: category, folder: folder)
            word.notes = value(row, "notes")
            word.example = value(row, "example")
            if let date = dateFormatter.date(from: value(row, "date_added"))
                ?? ISO8601DateFormatter().date(from: value(row, "date_added")) {
                word.createdAt = date
            }
            summary.added += 1
        }
        repository.save()
        return summary
    }
}
