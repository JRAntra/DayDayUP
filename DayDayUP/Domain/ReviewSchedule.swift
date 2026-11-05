import Foundation

/// The Ebbinghaus review ladder: the single definition of when a word is due and what an answer does.
/// The agreed design is written up in REVIEW_SCHEDULE.md.
///
/// * Step 0 is New: the clock starts the first time the word is answered.
/// * Steps 1–6 wait 1, 2, 4, 7, 15 and 30 days. Passing the 30-day review makes the word remembered
///   (step 7), which then comes back every 90 days.
/// * A correct answer on or after the due day moves the word up one step; before the due day it changes nothing.
/// * A wrong answer, at any time, sends the word back to step 1, due tomorrow, and into the Review Book.
/// * A word leaves the Review Book after 2 correct reviews in a row (it reaches step 3).
enum ReviewSchedule {
    /// Days to wait after reaching steps 1…6.
    static let gaps = [1, 2, 4, 7, 15, 30]
    /// Days between check-ups once a word is remembered.
    static let maintenanceGap = 90
    /// The number of reviews a word has to pass to be remembered (one per gap).
    static var reviewsToRemember: Int { gaps.count }
    /// The step a word is on once it's remembered.
    static var rememberedStep: Int { gaps.count + 1 }
    /// A missed word leaves the Review Book when it gets back to this step (2 correct reviews in a row).
    static let reviewBookExitStep = 3
    /// Words per Today round.
    static let roundSize = 20

    /// Days to wait after the word reaches `step`.
    static func gap(after step: Int) -> Int {
        if step >= rememberedStep { return maintenanceGap }
        return gaps[max(0, min(step, gaps.count) - 1)]
    }

    struct State: Equatable {
        var step: Int
        /// The local day (yyyy-MM-dd) the word is due; nil for New words.
        var dueDay: String?
        var inReview: Bool
        /// The day the word was first answered; nil for New words.
        var startedDay: String?

        static let new = State(step: 0, dueDay: nil, inReview: false, startedDay: nil)

        var isNew: Bool { step == 0 }
        var isRemembered: Bool { step >= ReviewSchedule.rememberedStep && !inReview }
    }

    struct Outcome: Equatable {
        var stepBefore = 0
        var stepAfter = 0
        /// The first answer to a New word.
        var started = false
        /// A correct answer before the due day; nothing changed.
        var early = false
        var advanced = false
        var becameRemembered = false
        /// A remembered word passed its 90-day check-up.
        var keptRemembered = false
        var lostRemembered = false
        var sentToReview = false
        var leftReview = false
        var dueDay: String?
    }

    /// Whether the word should be reviewed on `today`. New words are never due; they're offered as new words.
    static func isDue(_ state: State, today: String = DayKey.today) -> Bool {
        guard state.step > 0 else { return false }
        guard let due = state.dueDay else { return true }
        return due <= today   // yyyy-MM-dd strings sort chronologically.
    }

    static func apply(correct: Bool, to state: State, today: String = DayKey.today) -> (state: State, outcome: Outcome) {
        var next = state
        var out = Outcome(stepBefore: state.step, stepAfter: state.step, dueDay: state.dueDay)
        let wasRemembered = state.isRemembered

        if state.step == 0 {
            // First answer: the clock starts, right or wrong.
            out.started = true
            next.step = 1
            next.dueDay = DayKey.adding(1, to: today)
            next.startedDay = today
            if !correct {
                out.sentToReview = !state.inReview
                next.inReview = true
            }
        } else if !correct {
            out.lostRemembered = wasRemembered
            out.sentToReview = !state.inReview
            next.step = 1
            next.dueDay = DayKey.adding(1, to: today)
            next.inReview = true
        } else if !isDue(state, today: today) {
            out.early = true
            return (state, out)
        } else {
            let newStep = min(state.step + 1, rememberedStep)
            next.step = newStep
            next.dueDay = DayKey.adding(gap(after: newStep), to: today)
            out.advanced = newStep > state.step
            if state.inReview && newStep >= reviewBookExitStep {
                next.inReview = false
                out.leftReview = true
            }
            if next.isRemembered {
                if wasRemembered { out.keptRemembered = true } else { out.becameRemembered = true }
            }
        }
        out.stepAfter = next.step
        out.dueDay = next.dueDay
        return (next, out)
    }

    /// Maps progress from the old 3-ring rule onto the ladder (see REVIEW_SCHEDULE.md).
    /// Returns nil for words that were never answered: they stay New.
    /// `spreadIndex` spreads the due days over the next 7 days so they don't all land on one day.
    static func fromLegacy(ring: Int, inReview: Bool, lastCorrectDay: String?, spreadIndex: Int,
                           today: String = DayKey.today) -> State? {
        guard ring > 0 || inReview || lastCorrectDay != nil else { return nil }
        let step: Int
        switch ring {
        case ...0: step = 1
        case 1, 2: step = ring
        default: step = 4
        }
        // The started day only matters for today's new-word allowance, so it must not be today.
        let started = (lastCorrectDay == nil || lastCorrectDay == today) ? DayKey.previous(today) : lastCorrectDay
        return State(step: step, dueDay: DayKey.adding(abs(spreadIndex) % 7, to: today),
                     inReview: inReview, startedDay: started)
    }

    /// A short description of when a word is next due: "New", "Today", "Tomorrow", "in 4 days".
    static func dueText(_ state: State, today: String = DayKey.today) -> String {
        guard state.step > 0, let due = state.dueDay else { return state.step > 0 ? "Today" : "New" }
        let days = DayKey.days(from: today, to: due)
        switch days {
        case ...0: return "Today"
        case 1: return "Tomorrow"
        default: return "in \(days) days"
        }
    }

    /// Days until the word is due (negative when overdue); New words sort last.
    static func daysUntilDue(_ state: State, today: String = DayKey.today) -> Int {
        guard state.step > 0 else { return Int.max }
        guard let due = state.dueDay else { return 0 }
        return DayKey.days(from: today, to: due)
    }

    /// Review order for due words: Review Book first, then the lowest step, then the most overdue.
    static func reviewPriority(_ a: State, _ b: State) -> Bool {
        if a.inReview != b.inReview { return a.inReview }
        if a.step != b.step { return a.step < b.step }
        return (a.dueDay ?? "") < (b.dueDay ?? "")
    }
}
