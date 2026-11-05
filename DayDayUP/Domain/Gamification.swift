import CoreData
import SwiftUI

struct AchievementDefinition: Identifiable, Hashable {
    enum Kind { case remembered, collected, streak }

    let key: String
    let kind: Kind
    let threshold: Int
    let title: String
    let symbol: String

    var id: String { key }

    var detail: String {
        switch kind {
        case .remembered: return threshold == 1 ? "Remember your first word" : "Remember \(threshold) words"
        case .collected: return "Add \(threshold) words"
        case .streak: return "Keep a \(threshold)-day streak"
        }
    }

    static let all: [AchievementDefinition] = {
        var list: [AchievementDefinition] = []
        let rememberedTitles = [10: "Spark", 50: "Kindling", 100: "Centurion", 250: "Word Hoarder",
                                500: "Lexicon", 1000: "Polyglot", 2500: "Living Dictionary"]
        for n in [10, 50, 100, 250, 500, 1000, 2500] {
            list.append(.init(key: "remembered_\(n)", kind: .remembered, threshold: n,
                              title: rememberedTitles[n] ?? "\(n) words", symbol: "brain.head.profile"))
        }
        let collectorTitles = [25: "Collector", 100: "Curator", 500: "Archivist", 1000: "Librarian"]
        for n in [25, 100, 500, 1000] {
            list.append(.init(key: "collected_\(n)", kind: .collected, threshold: n,
                              title: collectorTitles[n] ?? "\(n) added", symbol: "tray.full.fill"))
        }
        let streakTitles = [3: "Warming Up", 7: "One Week", 30: "One Month", 100: "Unstoppable", 365: "A Whole Year"]
        for n in [3, 7, 30, 100, 365] {
            list.append(.init(key: "streak_\(n)", kind: .streak, threshold: n,
                              title: streakTitles[n] ?? "\(n) days", symbol: "flame.fill"))
        }
        return list
    }()
}

/// What happened when a quiz finished, for the summary screen.
struct QuizCompletionResult {
    var streakEarnedToday: Bool
    var currentStreak: Int
    var unlocked: [AchievementDefinition]
}

/// Streaks and achievements.
///
/// A streak day counts when, after finishing a quiz or Today round, either the round had at least
/// `ReviewSchedule.roundSize` answers or no reviews are left due in any pair. On a day with nothing due,
/// learning new words therefore counts. Days earned under the old rule were marked when the data was upgraded.
@MainActor
final class GamificationService: ObservableObject {
    @Published private(set) var currentStreak = 0
    @Published private(set) var longestStreak = 0
    @Published private(set) var unlockedKeys: [String: Date] = [:]
    @Published private(set) var todayQualifies = false
    /// Achievements unlocked since the banner was last shown.
    @Published var freshlyUnlocked: [AchievementDefinition] = []

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
        refresh()
    }

    // MARK: Recording

    private func activity(for day: String = DayKey.today) -> DailyActivityMO {
        let request = NSFetchRequest<DailyActivityMO>(entityName: "DailyActivityMO")
        request.predicate = NSPredicate(format: "dayKey == %@ AND deletedAt == nil", day)
        if let existing = try? context.fetch(request).first { return existing }
        let record = DailyActivityMO(context: context)
        record.stampNew()
        record.dayKey = day
        return record
    }

    func recordWordsAdded(_ count: Int = 1) {
        guard count > 0 else { return }
        let record = activity()
        record.wordsAdded += Int32(count)
        record.touch()
        save()
        evaluateAchievements()
    }

    func recordRemembered(_ count: Int = 1) {
        guard count > 0 else { return }
        let record = activity()
        record.wordsRemembered += Int32(count)
        record.touch()
        save()
        refresh()
    }

    /// Call when a quiz or Today round is finished (not quit). `answered` is the number of answers given.
    func recordSessionCompleted(answered: Int) -> QuizCompletionResult {
        let record = activity()
        record.quizzesCompleted += 1
        if answered >= ReviewSchedule.roundSize || dueCount() == 0 { record.streakEarned = true }
        record.touch()
        save()
        refresh()
        let unlocked = evaluateAchievements()
        return QuizCompletionResult(streakEarnedToday: todayQualifies, currentStreak: currentStreak, unlocked: unlocked)
    }

    // MARK: Streaks

    func refresh() {
        let request = NSFetchRequest<DailyActivityMO>(entityName: "DailyActivityMO")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        let days = Set(((try? context.fetch(request)) ?? []).filter(\.countsForStreak).compactMap(\.dayKey))

        let today = DayKey.today
        todayQualifies = days.contains(today)
        // A streak survives until the end of today even if today isn't done yet.
        var cursor = todayQualifies ? today : DayKey.previous(today)
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            cursor = DayKey.previous(cursor)
        }
        currentStreak = streak

        var longest = 0
        var run = 0
        var previous: Date?
        for key in days.sorted() {
            guard let date = DayKey.date(from: key) else { continue }
            if let previous, Calendar.current.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        longestStreak = max(longest, streak)

        let achievementRequest = NSFetchRequest<AchievementMO>(entityName: "AchievementMO")
        achievementRequest.predicate = NSPredicate(format: "deletedAt == nil")
        var keys: [String: Date] = [:]
        for record in (try? context.fetch(achievementRequest)) ?? [] {
            if let key = record.key { keys[key] = min(keys[key] ?? .distantFuture, record.unlockedAt ?? Date()) }
        }
        unlockedKeys = keys
    }

    // MARK: Achievements

    func rememberedCount() -> Int {
        let request = NSFetchRequest<WordMO>(entityName: "WordMO")
        request.predicate = NSPredicate(format: "deletedAt == nil AND step >= %d AND inReview == NO", ReviewSchedule.rememberedStep)
        return (try? context.count(for: request)) ?? 0
    }

    /// Reviews due today or earlier, across every pair.
    func dueCount() -> Int {
        let request = NSFetchRequest<WordMO>(entityName: "WordMO")
        request.predicate = NSPredicate(format: "deletedAt == nil AND step > 0 AND (dueDay == nil OR dueDay <= %@)", DayKey.today)
        return (try? context.count(for: request)) ?? 0
    }

    func addedCount() -> Int {
        let request = NSFetchRequest<DailyActivityMO>(entityName: "DailyActivityMO")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        return ((try? context.fetch(request)) ?? []).reduce(0) { $0 + Int($1.wordsAdded) }
    }

    func progress(for definition: AchievementDefinition) -> Int {
        switch definition.kind {
        case .remembered: return rememberedCount()
        case .collected: return addedCount()
        case .streak: return longestStreak
        }
    }

    @discardableResult
    func evaluateAchievements() -> [AchievementDefinition] {
        let remembered = rememberedCount()
        let added = addedCount()
        var newOnes: [AchievementDefinition] = []
        for definition in AchievementDefinition.all where unlockedKeys[definition.key] == nil {
            let value: Int
            switch definition.kind {
            case .remembered: value = remembered
            case .collected: value = added
            case .streak: value = longestStreak
            }
            guard value >= definition.threshold else { continue }
            let record = AchievementMO(context: context)
            record.stampNew()
            record.key = definition.key
            record.unlockedAt = Date()
            unlockedKeys[definition.key] = Date()
            newOnes.append(definition)
        }
        if !newOnes.isEmpty {
            save()
            freshlyUnlocked.append(contentsOf: newOnes)
        }
        return newOnes
    }

    private func save() {
        guard context.hasChanges else { return }
        try? context.save()
    }
}
