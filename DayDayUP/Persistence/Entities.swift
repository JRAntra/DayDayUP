import CoreData
import SwiftUI

/// Shared bookkeeping for every synced record.
protocol SyncRecord: NSManagedObject {
    var id: UUID? { get set }
    var createdAt: Date? { get set }
    var updatedAt: Date? { get set }
    var deletedAt: Date? { get set }
    var deletionBatch: UUID? { get set }
}

extension SyncRecord {
    func stampNew() {
        id = UUID()
        createdAt = Date()
        updatedAt = Date()
    }

    func touch() { updatedAt = Date() }
    var uuid: UUID { id ?? UUID() }
}

// SwiftUI (ForEach, Table, sheet(item:)) needs Identifiable. The current SDK no longer
// gives NSManagedObject an implicit conformance, so declare it using the stored `id`.
extension LanguagePairMO: Identifiable {}
extension CategoryMO: Identifiable {}
extension FolderMO: Identifiable {}
extension WordMO: Identifiable {}
extension DailyActivityMO: Identifiable {}
extension AchievementMO: Identifiable {}

// MARK: - Language pair

@objc(LanguagePairMO)
final class LanguagePairMO: NSManagedObject, SyncRecord {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var deletedAt: Date?
    @NSManaged var deletionBatch: UUID?
    @NSManaged var fromCode: String?
    @NSManaged var toCode: String?
    @NSManaged var script: String?
    @NSManaged var accentHex: String?
    @NSManaged var sortIndex: Int64
    @NSManaged var categories: Set<CategoryMO>?

    var from: AppLanguage { AppLanguage(rawValue: fromCode ?? "") ?? .english }
    var to: AppLanguage { AppLanguage(rawValue: toCode ?? "") ?? .chinese }
    var title: String { "\(from.displayName) → \(to.displayName)" }
    var accent: Color { Color(hex: accentHex ?? "1FA2FF") }

    var liveCategories: [CategoryMO] {
        (categories ?? []).filter { $0.deletedAt == nil }
            .sorted { ($0.sortIndex, $0.name ?? "") < ($1.sortIndex, $1.name ?? "") }
    }

    /// The flashcard back can toggle only when the target language isn't English.
    var hasEnglishToggle: Bool { to != .english }

    /// Pairs without any words are hidden on Today and in the Library (see LibraryState).
    var hasWords: Bool { liveCategories.contains { !$0.liveWords.isEmpty } }
}

// MARK: - Category

@objc(CategoryMO)
final class CategoryMO: NSManagedObject, SyncRecord {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var deletedAt: Date?
    @NSManaged var deletionBatch: UUID?
    @NSManaged var name: String?
    @NSManaged var sortIndex: Int64
    @NSManaged var pair: LanguagePairMO?
    @NSManaged var folders: Set<FolderMO>?
    @NSManaged var words: Set<WordMO>?

    var displayName: String { name ?? "Untitled" }

    var liveFolders: [FolderMO] {
        (folders ?? []).filter { $0.deletedAt == nil }
            .sorted { ($0.sortIndex, $0.name ?? "") < ($1.sortIndex, $1.name ?? "") }
    }

    var liveWords: [WordMO] { (words ?? []).filter { $0.deletedAt == nil } }
}

// MARK: - Folder

@objc(FolderMO)
final class FolderMO: NSManagedObject, SyncRecord {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var deletedAt: Date?
    @NSManaged var deletionBatch: UUID?
    @NSManaged var name: String?
    @NSManaged var sortIndex: Int64
    @NSManaged var category: CategoryMO?
    @NSManaged var words: Set<WordMO>?

    var displayName: String { name ?? "Untitled" }
    var liveWords: [WordMO] { (words ?? []).filter { $0.deletedAt == nil } }
}

// MARK: - Word

@objc(WordMO)
final class WordMO: NSManagedObject, SyncRecord {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var deletedAt: Date?
    @NSManaged var deletionBatch: UUID?
    @NSManaged var term: String?
    @NSManaged var termKey: String?
    @NSManaged var reading: String?
    @NSManaged var sensesJSON: String?
    @NSManaged var example: String?
    @NSManaged var notes: String?
    /// Legacy progress from the old 3-ring rule; only read when mapping old data onto the ladder.
    @NSManaged var ring: Int16
    @NSManaged var lastCorrectDay: String?
    /// Review ladder (see ReviewSchedule): 0 = New, 1–6 waiting, 7 = remembered.
    @NSManaged var step: Int16
    @NSManaged var dueDay: String?
    @NSManaged var startedDay: String?
    @NSManaged var inReview: Bool
    @NSManaged var timesMissed: Int32
    @NSManaged var rememberedAt: Date?
    @NSManaged var category: CategoryMO?
    @NSManaged var folder: FolderMO?

    var senses: [Sense] {
        get { SenseCodec.decode(sensesJSON) }
        set { sensesJSON = SenseCodec.encode(newValue); touch() }
    }

    var primarySense: Sense? { senses.first { !$0.translation.isEmpty } ?? senses.first }
    var pair: LanguagePairMO? { category?.pair }
    var schedule: ReviewSchedule.State {
        get { ReviewSchedule.State(step: Int(step), dueDay: dueDay, inReview: inReview, startedDay: startedDay) }
        set {
            step = Int16(newValue.step)
            dueDay = newValue.dueDay
            inReview = newValue.inReview
            startedDay = newValue.startedDay
        }
    }
    var isRemembered: Bool { schedule.isRemembered }
    var isNew: Bool { step == 0 }
    var isDue: Bool { ReviewSchedule.isDue(schedule) }
    var dueText: String { ReviewSchedule.dueText(schedule) }
    /// For sorting by next review; New words sort last.
    var daysUntilDue: Int { ReviewSchedule.daysUntilDue(schedule) }

    // Non-optional values for sorting in tables.
    var termValue: String { term ?? "" }
    var readingValue: String { reading ?? "" }
    var translationSummary: String { senses.map(\.translation).filter { !$0.isEmpty }.joined(separator: "; ") }
    var posSummary: String {
        var seen: [String] = []
        for p in senses.map(\.partOfSpeech) where !p.isEmpty && !seen.contains(p) { seen.append(p) }
        return seen.joined(separator: " ")
    }
    var addedDate: Date { createdAt ?? .distantPast }
    /// For sorting by progress: Review Book first, then by step.
    var stepValue: Int { inReview ? -1 : Int(step) }
    var folderName: String { folder?.displayName ?? "Unfiled" }
}

// MARK: - Gamification records

@objc(DailyActivityMO)
final class DailyActivityMO: NSManagedObject, SyncRecord {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var deletedAt: Date?
    @NSManaged var deletionBatch: UUID?
    @NSManaged var dayKey: String?
    @NSManaged var quizzesCompleted: Int32
    @NSManaged var wordsRemembered: Int32
    @NSManaged var wordsAdded: Int32
    @NSManaged var streakEarned: Bool
    @NSManaged var answersJSON: String?

    /// Answers given that day per language pair: pair id → [correct, missed].
    var answerCounts: [String: [Int]] {
        get {
            guard let data = answersJSON?.data(using: .utf8) else { return [:] }
            return (try? JSONDecoder().decode([String: [Int]].self, from: data)) ?? [:]
        }
        set {
            answersJSON = (try? JSONEncoder().encode(newValue)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }

    /// Correct and missed answers that day, for one pair or (nil) all pairs.
    func answers(pairID: UUID?) -> (correct: Int, missed: Int) {
        let counts = answerCounts
        let rows = pairID.map { counts[$0.uuidString].map { [$0] } ?? [] } ?? Array(counts.values)
        return rows.reduce((0, 0)) { total, row in
            (total.0 + (row.first ?? 0), total.1 + (row.count > 1 ? row[1] : 0))
        }
    }

    /// The rule before the review ladder: a quiz was finished and at least one word became remembered.
    var earnedUnderOldRule: Bool { quizzesCompleted > 0 && wordsRemembered > 0 }
    var countsForStreak: Bool { streakEarned }
}

@objc(AchievementMO)
final class AchievementMO: NSManagedObject, SyncRecord {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var deletedAt: Date?
    @NSManaged var deletionBatch: UUID?
    @NSManaged var key: String?
    @NSManaged var unlockedAt: Date?
}
