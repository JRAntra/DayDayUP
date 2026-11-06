import CoreData
import Foundation

/// Builds the Today rounds and counts what's due, per language pair (see REVIEW_SCHEDULE.md).
@MainActor
final class TodayPlanner: ObservableObject {
    static let newPerDayKey = "today.newPerDay"
    static let defaultNewPerDay = 10
    static let newPerDayRange = 0...50

    /// New words introduced per pair per day.
    @Published var newPerDay: Int {
        didSet { UserDefaults.standard.set(newPerDay, forKey: Self.newPerDayKey) }
    }

    private let repository: VocabRepository

    init(repository: VocabRepository) {
        self.repository = repository
        let stored = UserDefaults.standard.object(forKey: Self.newPerDayKey) as? Int
        newPerDay = stored.map { min(max($0, Self.newPerDayRange.lowerBound), Self.newPerDayRange.upperBound) } ?? Self.defaultNewPerDay
    }

    struct Summary: Equatable {
        var due = 0
        /// New words still available to start today (limited by the daily allowance).
        var newToday = 0
        /// All New words waiting in this pair.
        var newWaiting = 0
        /// Words in the pair that can be reviewed (they have a meaning).
        var total = 0
        var isEmpty: Bool { due == 0 && newToday == 0 }
    }

    /// Words a Today round can use: live and with a meaning to test.
    private func usableWords(in pair: LanguagePairMO) -> [WordMO] {
        repository.reviewableWords(in: pair).filter(QuizEngine.hasQuizzableMeaning)
    }

    /// New words already started today in this pair, wherever they were answered.
    private func startedToday(_ words: [WordMO]) -> Int {
        let today = DayKey.today
        return words.filter { $0.startedDay == today }.count
    }

    func summary(for pair: LanguagePairMO) -> Summary {
        let words = usableWords(in: pair)
        let waiting = words.filter(\.isNew).count
        let allowance = max(0, newPerDay - startedToday(words))
        return Summary(due: words.filter(\.isDue).count, newToday: min(waiting, allowance), newWaiting: waiting, total: words.count)
    }

    /// The next round of up to 20 words: due reviews first (Review Book → lowest step → most overdue),
    /// then New words (oldest added first) to fill the round, within today's allowance.
    /// New words therefore wait while 20 or more reviews are due.
    func nextRound(for pair: LanguagePairMO) -> [WordMO] {
        let words = usableWords(in: pair)
        var round = Array(words.filter(\.isDue)
            .sorted { ReviewSchedule.reviewPriority($0.schedule, $1.schedule) }
            .prefix(ReviewSchedule.roundSize))
        let room = ReviewSchedule.roundSize - round.count
        if room > 0 {
            let allowance = max(0, newPerDay - startedToday(words))
            let new = words.filter(\.isNew).sorted { $0.addedDate < $1.addedDate }
            round += new.prefix(min(room, allowance))
        }
        return round
    }
}
