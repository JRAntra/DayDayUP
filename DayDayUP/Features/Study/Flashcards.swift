import SwiftUI

/// The one Study sheet for a word list: choose Quiz or Flashcards and the options, then study.
struct StudySheet: View {
    let launch: StudyLaunch

    @EnvironmentObject private var speech: SpeechService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("study.mode") private var mode: TodayMode = .quiz
    @State private var length: QuizEngine.Length = .ten
    @State private var includeRemembered = false
    @State private var back: FlashcardBack = .translation
    @State private var running = false
    /// Changes on every start, so a new round gets a fresh session.
    @State private var session = UUID()

    private var pool: [WordMO] { launch.words }
    private var unrememberedCount: Int { pool.filter { !$0.isRemembered }.count }
    private var showsBackToggle: Bool { pool.contains { $0.pair?.hasEnglishToggle ?? false } }

    var body: some View {
        Group {
            if running {
                switch mode {
                case .quiz:
                    QuizFlow(pool: pool, accent: launch.accent,
                             preset: .init(length: length, includeRemembered: includeRemembered),
                             onSetup: { running = false })
                        .id(session)
                case .flashcards:
                    FlashcardSession(pool: pool, accent: launch.accent,
                                     preset: .init(includeRemembered: includeRemembered, back: back),
                                     onSetup: { running = false })
                        .id(session)
                }
            } else {
                setup
            }
        }
        .macSheetSize(minWidth: 640, minHeight: 640)
    }

    private var setup: some View {
        NavigationStackCompat {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Mode", selection: $mode) {
                        ForEach(TodayMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(mode == .quiz
                         ? "Pick the meaning of each word. Words that are due move up a step when you're right; any miss sends a word back to the start."
                         : "Flip cards to practise. Flashcards here don't change progress; Today reviews and quizzes do.")
                        .font(Typeface.body(15)).foregroundColor(Palette.ink.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Words").font(Typeface.label(14))
                    Picker("Words", selection: $includeRemembered) {
                        Text("Not remembered (\(unrememberedCount))").tag(false)
                        Text("All words (\(pool.count))").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if mode == .quiz {
                        Text("Questions").font(Typeface.label(14))
                        Picker("Questions", selection: $length) {
                            ForEach(QuizEngine.Length.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        let due = QuizEngine.dueToday(pool).count
                        if due > 0 {
                            Label("\(due) word\(due == 1 ? " is" : "s are") due for review. They come first.",
                                  systemImage: "clock.badge.exclamationmark.fill")
                                .font(Typeface.body(14)).foregroundColor(Palette.tangerine)
                        }
                    } else if showsBackToggle {
                        Text("Back of the card").font(Typeface.label(14))
                        Picker("Back", selection: $back) {
                            ForEach(FlashcardBack.allCases) { Text($0 == .english ? "English explanation" : "Translation").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    Toggle("Speak words aloud", isOn: Binding(get: { speech.speakAloud }, set: { speech.speakAloud = $0 }))
                        .font(Typeface.body(15))

                    Button(mode == .quiz ? "Start quiz" : "Start flashcards") {
                        session = UUID()
                        running = true
                    }
                    .buttonStyle(ChunkyButtonStyle(color: launch.accent))
                    .padding(.top, 8)
                }
                .padding(24)
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Study")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

enum FlashcardBack: String, CaseIterable, Identifiable {
    case english = "English"
    case translation = "Translation"
    var id: String { rawValue }
}

/// Flashcards are practice only and never change progress, except in a Today round (`today` set),
/// where "Knew it / Didn't know" counts like a quiz answer.
struct FlashcardSession: View {
    struct Preset { var includeRemembered: Bool; var back: FlashcardBack }

    let pool: [WordMO]
    let accent: Color
    var today: TodayRoundSource? = nil
    /// Options chosen in the Study sheet; the session starts straight away.
    var preset: Preset? = nil
    /// Goes back to the Study sheet's options.
    var onSetup: (() -> Void)? = nil

    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var gamification: GamificationService
    @EnvironmentObject private var reminders: ReminderService
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case setup, studying, summary, allDone }

    @State private var phase: Phase = .setup
    @State private var includeRemembered = false
    @State private var back: FlashcardBack = .translation
    @State private var deck: [WordMO] = []
    @State private var index = 0
    @State private var flipped = false
    @State private var drag: CGSize = .zero
    @State private var known: [WordMO] = []
    @State private var missed: [WordMO] = []
    @State private var completion: QuizCompletionResult?

    /// The toggle is hidden when every word's target language is English (e.g. Chinese → English).
    private var showsBackToggle: Bool { pool.contains { $0.pair?.hasEnglishToggle ?? false } }
    private var available: [WordMO] { includeRemembered ? pool : pool.filter { !$0.isRemembered } }

    var body: some View {
        NavigationStackCompat {
            Group {
                switch phase {
                case .setup: setup
                case .studying: studying
                case .summary: summary
                case .allDone: allDone
                }
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(today == nil ? "Flashcards" : "Today")
            .onAppear {
                guard phase == .setup else { return }
                if today != nil {
                    startTodayRound()
                } else if let preset {
                    includeRemembered = preset.includeRemembered
                    back = preset.back
                    if !available.isEmpty { start(available) }
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    // MARK: Setup

    /// Shown only when the chosen words can't make a deck.
    private var setup: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("No cards to study").font(Typeface.display(28))
            Text("Every word here is remembered. Choose All words to practise them anyway.")
                .font(Typeface.body(15)).foregroundColor(Palette.ink.opacity(0.7)).multilineTextAlignment(.center)
            Spacer()
            if let onSetup {
                Button("Back") { onSetup() }.buttonStyle(ChunkyButtonStyle(color: accent))
            }
        }
        .padding(24)
    }

    private func startTodayRound() {
        guard let today else { return }
        let words = today.next()
        if words.isEmpty { phase = .allDone } else { start(words) }
    }

    private func start(_ words: [WordMO]) {
        completion = nil
        deck = words.shuffled()
        index = 0
        flipped = false
        known = []
        missed = []
        phase = .studying
        speakCurrent()
    }

    // MARK: Studying

    private var current: WordMO? { index < deck.count ? deck[index] : nil }

    private var studying: some View {
        VStack(spacing: 18) {
            ProgressView(value: Double(index), total: Double(max(deck.count, 1))).tint(accent)
            Text("\(min(index + 1, deck.count)) of \(deck.count)")
                .font(Typeface.label(13)).foregroundColor(Palette.ink.opacity(0.6)).monospacedDigit()
            if let word = current {
                card(word)
                    .offset(x: drag.width, y: drag.height * 0.2)
                    .rotationEffect(.degrees(Double(drag.width / 18)))
                    .gesture(
                        DragGesture()
                            .onChanged { drag = $0.translation }
                            .onEnded { value in
                                if value.translation.width > 110 { answer(knew: true) }
                                else if value.translation.width < -110 { answer(knew: false) }
                                withAnimation(.spring()) { drag = .zero }
                            }
                    )
                    .onTapGesture { flip() }
            }
            HStack(spacing: 12) {
                Button { answer(knew: false) } label: { Label("Didn't know", systemImage: "arrow.left") }
                    .buttonStyle(ChunkyButtonStyle(color: Palette.cherry))
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { flip() } label: { Label("Flip", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(OutlineChunkyButtonStyle(color: accent))
                    .keyboardShortcut(.space, modifiers: [])
                Button { answer(knew: true) } label: { Label("Knew it", systemImage: "arrow.right") }
                    .buttonStyle(ChunkyButtonStyle(color: Palette.mint))
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            #if os(iOS)
            Text("Swipe right if you knew it, left if you didn't.").font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.5))
            #else
            Text("← didn't know   ·   space flips   ·   → knew it").font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.5))
            #endif
        }
        .padding(20)
    }

    private func card(_ word: WordMO) -> some View {
        let pairAccent = word.pair?.accent ?? accent
        return ZStack {
            // Front: the word itself.
            VStack(spacing: 14) {
                Spacer()
                Text(word.termValue)
                    .font(Typeface.display(52))
                    .foregroundColor(Palette.ink)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.4)
                Button { speech.speak(word) } label: { Image(systemName: "speaker.wave.2.fill").font(.system(size: 20, weight: .bold)) }
                    .buttonStyle(ChunkyButtonStyle(color: pairAccent, height: 44, fullWidth: false))
                    .accessibilityLabel("Play pronunciation")
                Spacer()
                Text("Tap to flip").font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.4))
            }
            .padding(24)
            .opacity(flipped ? 0 : 1)

            // Back: reading, then every meaning in the user's order.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(word.termValue).font(Typeface.title(24))
                        if !word.readingValue.isEmpty {
                            Text(word.readingValue).font(Typeface.body(17)).foregroundColor(Palette.ink.opacity(0.6))
                        }
                        Spacer()
                        ProgressRing(step: Int(word.step), inReview: word.inReview, accent: pairAccent, size: 30)
                    }
                    ForEach(Array(word.senses.enumerated()), id: \.offset) { i, sense in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1)").font(Typeface.label(12)).foregroundColor(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(i == 0 ? pairAccent : Palette.ink.opacity(0.35)))
                            if !sense.partOfSpeech.isEmpty {
                                Text(sense.partOfSpeech).font(Typeface.label(13)).foregroundColor(pairAccent)
                            }
                            Text(backText(sense, word: word)).font(Typeface.title(19)).foregroundColor(Palette.ink)
                        }
                    }
                    if let example = word.example, !example.isEmpty {
                        Text(example).font(Typeface.body(15)).italic().foregroundColor(Palette.ink.opacity(0.7))
                    }
                    if let notes = word.notes, !notes.isEmpty {
                        Text(notes).font(Typeface.body(14)).foregroundColor(Palette.ink.opacity(0.6))
                    }
                }
                .padding(24)
            }
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            .opacity(flipped ? 1 : 0)
        }
        .frame(maxWidth: 560, minHeight: 340, maxHeight: 460)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(pairAccent.opacity(0.6), lineWidth: 3))
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.ledge(for: pairAccent)).offset(y: 8))
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: flipped)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Flips the card")
    }

    private func backText(_ sense: Sense, word: WordMO) -> String {
        guard word.pair?.hasEnglishToggle ?? false, back == .english else { return sense.translation }
        return sense.english.isEmpty ? sense.translation : sense.english
    }

    private func flip() {
        Haptics.tap()
        flipped.toggle()
    }

    private func answer(knew: Bool) {
        guard let word = current else { return }
        if knew { known.append(word) } else { missed.append(word) }
        if today != nil {
            repository.recordAnswer(for: word, correct: knew)
            if knew { Haptics.success() } else { Haptics.error() }
        }
        flipped = false
        if index + 1 >= deck.count {
            if today != nil {
                completion = gamification.recordSessionCompleted(answered: deck.count)
                Task { await reminders.refresh() }
            }
            phase = .summary
        } else {
            index += 1
            speakCurrent()
        }
    }

    private func speakCurrent() {
        guard speech.autoPlayFlashcards, let word = current else { return }
        speech.speak(word)
    }

    // MARK: Summary

    private var summary: some View {
        VStack(spacing: 18) {
            Text(missed.isEmpty ? "Clean sweep!" : "Session done").font(Typeface.display(38))
            HStack(spacing: 24) {
                stat("\(known.count)", "knew", Palette.mint)
                stat("\(missed.count)", "didn't know", Palette.cherry)
            }
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
            if !missed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(today == nil ? "Still learning" : "Back to the start, due tomorrow").font(Typeface.label(14))
                    Text(missed.map(\.termValue).joined(separator: ", ")).font(Typeface.body(15))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                if today == nil {
                    Button("Retry the \(missed.count) I missed") { start(missed) }
                        .buttonStyle(ChunkyButtonStyle(color: accent))
                }
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
            }
            Spacer()
            if today == nil, let onSetup {
                Button("Change options") { onSetup() }.buttonStyle(OutlineChunkyButtonStyle(color: accent))
            }
            Button("Done") { dismiss() }.buttonStyle(OutlineChunkyButtonStyle(color: accent))
        }
        .padding(24)
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

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack {
            Text(value).font(Typeface.display(44)).foregroundColor(color)
            Text(label).font(Typeface.label(14)).foregroundColor(Palette.ink.opacity(0.65))
        }
    }
}
