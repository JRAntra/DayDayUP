import CoreData
import SwiftUI

/// Supplies Today rounds to a quiz or flashcard session.
struct TodayRoundSource {
    /// The next round's words; empty when nothing is left for today.
    var next: () -> [WordMO]
    /// Words still due or new for today, shown on "Keep going".
    var remaining: () -> Int
}

struct QuizFlow: View {
    struct Preset { var length: QuizEngine.Length; var includeRemembered: Bool }

    /// Every word in scope, used for wrong answers. In Today mode the questions come from `today`.
    let pool: [WordMO]
    let accent: Color
    var today: TodayRoundSource? = nil
    /// Options chosen in the Study sheet; the quiz starts straight away.
    var preset: Preset? = nil
    /// Goes back to the Study sheet's options.
    var onSetup: (() -> Void)? = nil

    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var dictionaries: DictionaryManager
    @EnvironmentObject private var gamification: GamificationService
    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var reminders: ReminderService
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case setup, playing, summary, allDone }

    @State private var phase: Phase = .setup
    @State private var length: QuizEngine.Length = .ten
    @State private var includeRemembered = false
    @State private var questions: [QuizQuestion] = []
    @State private var index = 0
    @State private var chosen: Int?
    @State private var lastOutcome: ReviewSchedule.Outcome?
    @State private var correctCount = 0
    @State private var rememberedNow: [WordMO] = []
    @State private var missedWords: [WordMO] = []
    @State private var completion: QuizCompletionResult?
    @State private var confetti = 0
    @State private var setupMessage: String?

    var body: some View {
        NavigationStackCompat {
            ZStack {
                Palette.background.ignoresSafeArea()
                switch phase {
                case .setup: setup
                case .playing: playing
                case .summary: summary
                case .allDone: allDone
                }
                ConfettiBurst(trigger: confetti).ignoresSafeArea()
            }
            .navigationTitle(today == nil ? "Quiz" : "Today")
            .onAppear {
                guard phase == .setup else { return }
                if today != nil {
                    startTodayRound()
                } else if let preset {
                    length = preset.length
                    includeRemembered = preset.includeRemembered
                    start()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .playing ? "Quit" : "Close") { dismiss() }
                        .help(phase == .playing ? "Answers so far are kept, but an unfinished quiz doesn't count toward your streak." : "")
                }
            }
        }
    }

    // MARK: Setup

    private var unremembered: [WordMO] { pool.filter { !$0.isRemembered } }

    /// Shown only when the chosen words can't make a quiz.
    private var setup: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Can't start a quiz").font(Typeface.display(28))
            Text(setupMessage ?? "")
                .font(Typeface.body(15)).foregroundColor(Palette.ink.opacity(0.7)).multilineTextAlignment(.center)
            Spacer()
            if let onSetup {
                Button("Back") { onSetup() }.buttonStyle(ChunkyButtonStyle(color: accent))
            }
        }
        .padding(24)
    }

    private func start() {
        begin(QuizEngine.pickWords(from: pool, length: length, includeRemembered: includeRemembered))
    }

    private func startTodayRound() {
        guard let today else { return }
        let words = today.next()
        if words.isEmpty { phase = .allDone; return }
        begin(words)
    }

    private func begin(_ picked: [WordMO]) {
        var categoryCache: [NSManagedObjectID: [WordMO]] = [:]
        var dictionaryCache: [NSManagedObjectID: [(pos: String, text: String)]] = [:]
        var built: [QuizQuestion] = []
        for word in picked {
            var categoryWords: [WordMO] = []
            if let category = word.category {
                if let cached = categoryCache[category.objectID] { categoryWords = cached } else {
                    categoryWords = repository.liveWords(in: category)
                    categoryCache[category.objectID] = categoryWords
                }
            }
            var dictionarySenses: [(pos: String, text: String)] = []
            if let pair = word.pair {
                if let cached = dictionaryCache[pair.objectID] { dictionarySenses = cached } else {
                    dictionarySenses = QuizEngine.dictionaryDistractors(for: pair, dictionaries: dictionaries)
                    dictionaryCache[pair.objectID] = dictionarySenses
                }
            }
            if let question = QuizEngine.makeQuestion(for: word, scope: pool, categoryWords: categoryWords,
                                                      dictionarySenses: dictionarySenses) {
                built.append(question)
            }
        }
        guard !built.isEmpty else {
            if today != nil { phase = .allDone; return }
            setupMessage = includeRemembered || unremembered.count > 1
                ? "A quiz needs at least two words with meanings, or an installed dictionary to borrow wrong answers from."
                : "Every word here is remembered. Choose All words to review them anyway."
            return
        }
        questions = built
        index = 0
        chosen = nil
        lastOutcome = nil
        correctCount = 0
        rememberedNow = []
        missedWords = []
        phase = .playing
        speakIfNeeded()
    }

    // MARK: Playing

    private var question: QuizQuestion? { index < questions.count ? questions[index] : nil }

    @ViewBuilder private var playing: some View {
        if let question {
            let pairAccent = question.word.pair?.accent ?? accent
            VStack(spacing: 16) {
                ProgressView(value: Double(index), total: Double(questions.count)).tint(pairAccent)
                HStack {
                    Text("Question \(index + 1) of \(questions.count)").font(Typeface.label(13)).monospacedDigit()
                    Spacer()
                    Label("\(correctCount)", systemImage: "checkmark.circle.fill").font(Typeface.label(13)).foregroundColor(Palette.mint)
                }
                .foregroundColor(Palette.ink.opacity(0.6))

                VStack(spacing: 10) {
                    HStack {
                        ProgressRing(step: Int(question.word.step), inReview: question.word.inReview, accent: pairAccent, size: 34)
                        Spacer()
                        Button { speech.speak(question.word) } label: { Image(systemName: "speaker.wave.2.fill") }
                            .buttonStyle(ChunkyButtonStyle(color: pairAccent, height: 38, fullWidth: false))
                            .accessibilityLabel("Play pronunciation")
                    }
                    Text(question.prompt)
                        .font(Typeface.display(46))
                        .foregroundColor(Palette.ink)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.4)
                    if chosen != nil, !question.word.readingValue.isEmpty {
                        Text(question.word.readingValue).font(Typeface.body(17)).foregroundColor(Palette.ink.opacity(0.6))
                    }
                }
                .card(padding: 20)

                VStack(spacing: 10) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { i, option in
                        Button { choose(i) } label: {
                            HStack {
                                Text(option).font(Typeface.title(18)).multilineTextAlignment(.leading)
                                Spacer()
                                if chosen != nil && i == question.correctIndex { Image(systemName: "checkmark.circle.fill") }
                                else if chosen == i { Image(systemName: "xmark.circle.fill") }
                            }
                        }
                        .buttonStyle(ChunkyButtonStyle(color: optionColor(i, question: question, accent: pairAccent),
                                                       foreground: optionForeground(i, question: question), height: 54,
                                                       ledge: chosen == nil ? Palette.line : nil))
                        .disabled(chosen != nil)
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
                    }
                }

                if chosen != nil { feedback(question, accent: pairAccent) }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private func optionColor(_ i: Int, question: QuizQuestion, accent: Color) -> Color {
        guard let chosen else { return Palette.surface }
        if i == question.correctIndex { return Palette.mint }
        if i == chosen { return Palette.cherry }
        return Palette.surfaceSunken
    }

    private func optionForeground(_ i: Int, question: QuizQuestion) -> Color {
        guard let chosen else { return Palette.ink }
        return (i == question.correctIndex || i == chosen) ? .white : Palette.ink.opacity(0.45)
    }

    private func feedback(_ question: QuizQuestion, accent: Color) -> some View {
        let correct = chosen == question.correctIndex
        let others = Array(question.word.senses.dropFirst())
        return VStack(alignment: .leading, spacing: 8) {
            Text(headline(correct: correct)).font(Typeface.title(20)).foregroundColor(correct ? Palette.mint : Palette.cherry)
            if let detail = outcomeDetail(correct: correct) {
                Text(detail).font(Typeface.body(14)).foregroundColor(Palette.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !others.isEmpty {
                Text("+\(others.count) more meaning\(others.count == 1 ? "" : "s"): " + others.map(\.translation).joined(separator: "; "))
                    .font(Typeface.body(14)).foregroundColor(Palette.ink.opacity(0.65))
            }
            Button(index + 1 < questions.count ? "Continue" : "See results", action: next)
                .buttonStyle(ChunkyButtonStyle(color: accent))
                .keyboardShortcut(.return, modifiers: [])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func headline(correct: Bool) -> String {
        if lastOutcome?.becameRemembered == true { return "Remembered!" }
        return correct ? "Correct" : "Not quite"
    }

    private func outcomeDetail(correct: Bool) -> String? {
        guard let outcome = lastOutcome else { return nil }
        let next = outcome.dueDay.map { ReviewSchedule.dueText(.init(step: outcome.stepAfter, dueDay: $0, inReview: false, startedDay: nil)).lowercased() } ?? ""
        if !correct {
            return outcome.sentToReview
                ? "Back to the start. It's due again tomorrow and now in the Review Book."
                : "Back to the start. It's due again tomorrow."
        }
        if outcome.started { return "Started. Its first review is tomorrow." }
        if outcome.early { return "Not due yet (\(next)), so early answers don't move it up." }
        if outcome.becameRemembered { return "Passed the 30-day review. It's remembered; next check-up in \(ReviewSchedule.maintenanceGap) days." }
        if outcome.keptRemembered { return "Still remembered. Next check-up \(next)." }
        var text = "Step \(outcome.stepAfter - 1) of \(ReviewSchedule.reviewsToRemember) passed. Next review \(next)."
        if outcome.leftReview { text += " It's out of the Review Book." }
        return text
    }

    private func choose(_ i: Int) {
        guard chosen == nil, let question else { return }
        let correct = i == question.correctIndex
        let outcome = repository.recordAnswer(for: question.word, correct: correct)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            chosen = i
            lastOutcome = outcome
        }
        if correct {
            correctCount += 1
            Haptics.success()
        } else {
            missedWords.append(question.word)
            Haptics.error()
        }
        if outcome.becameRemembered {
            rememberedNow.append(question.word)
            gamification.recordRemembered()
            confetti += 1
        }
    }

    private func next() {
        if index + 1 < questions.count {
            index += 1
            chosen = nil
            lastOutcome = nil
            speakIfNeeded()
        } else {
            completion = gamification.recordSessionCompleted(answered: questions.count)
            if completion?.streakEarnedToday == true, !rememberedNow.isEmpty { confetti += 1 }
            Task { await reminders.refresh() }
            phase = .summary
        }
    }

    private func speakIfNeeded() {
        guard speech.speakInQuiz, let question else { return }
        speech.speak(question.word)
    }

    // MARK: Summary

    private var summary: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("\(correctCount) / \(questions.count)").font(Typeface.display(56)).foregroundColor(accent)
                Text(correctCount == questions.count ? "Perfect round!" : "Round complete").font(Typeface.title(22))

                if let completion {
                    HStack(spacing: 12) {
                        StreakFlame(count: completion.currentStreak, lit: completion.streakEarnedToday).font(Typeface.display(26))
                        Text(completion.streakEarnedToday
                             ? "Today counts toward your streak."
                             : "To earn today's streak, clear today's reviews or finish a round of \(ReviewSchedule.roundSize).")
                            .font(Typeface.body(14)).foregroundColor(Palette.ink.opacity(0.75))
                        Spacer()
                    }
                    .card()
                }

                if !rememberedNow.isEmpty {
                    summaryList(title: "Newly remembered", words: rememberedNow, color: Palette.mint, symbol: "checkmark.seal.fill")
                }
                if !missedWords.isEmpty {
                    summaryList(title: "Sent to the Review Book", words: missedWords, color: Palette.cherry, symbol: "arrow.uturn.backward.circle.fill")
                }
                if let unlocked = completion?.unlocked, !unlocked.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Achievements unlocked").font(Typeface.label(14))
                        ForEach(unlocked) { a in
                            Label(a.title, systemImage: a.symbol).font(Typeface.title(16)).foregroundColor(Palette.ink)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                if let today {
                    let left = today.remaining()
                    if left > 0 {
                        Button("Keep going (\(left) left today)") { startTodayRound() }
                            .buttonStyle(ChunkyButtonStyle(color: accent))
                    } else {
                        Label("That's everything for today.", systemImage: "checkmark.seal.fill")
                            .font(Typeface.title(17)).foregroundColor(Palette.mint)
                    }
                } else {
                    Button("Play another round") { start() }
                        .buttonStyle(ChunkyButtonStyle(color: accent))
                    if let onSetup {
                        Button("Change options") { onSetup() }
                            .buttonStyle(OutlineChunkyButtonStyle(color: accent))
                    }
                }
                Button("Done") { dismiss() }
                    .buttonStyle(OutlineChunkyButtonStyle(color: accent))
            }
            .padding(24)
        }
    }

    private var allDone: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundColor(Palette.mint)
            Text("All done for today").font(Typeface.display(30))
            Text("Nothing is due and today's new words are started. Come back tomorrow.")
                .font(Typeface.body(15)).foregroundColor(Palette.ink.opacity(0.7)).multilineTextAlignment(.center)
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(OutlineChunkyButtonStyle(color: accent))
        }
        .padding(24)
    }

    private func summaryList(title: String, words: [WordMO], color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(Typeface.label(14)).foregroundColor(color)
            Text(words.map(\.termValue).joined(separator: ", ")).font(Typeface.body(16)).foregroundColor(Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
