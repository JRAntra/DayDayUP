import CoreData
import SwiftUI

enum TodayMode: String, CaseIterable, Identifiable {
    case quiz = "Quiz"
    case flashcards = "Flashcards"
    var id: String { rawValue }
}

/// The daily review screen: the streak (opens Progress), struggling words (the Review Book),
/// and one row per language pair with what's due and how many new words are ready.
/// Pairs without words are hidden.
struct TodayView: View {
    /// On Mac these switch the detail pane; on iPhone they're nil and the rows push a screen.
    var openReviewBook: (() -> Void)? = nil
    var openProgress: (() -> Void)? = nil

    @FetchRequest(fetchRequest: Fetch.pairs()) private var pairs: FetchedResults<LanguagePairMO>
    /// Watched so the counts refresh as soon as an answer changes a word.
    @FetchRequest(fetchRequest: Fetch.words(NSPredicate(format: "deletedAt == nil"))) private var words: FetchedResults<WordMO>
    @EnvironmentObject private var planner: TodayPlanner
    @EnvironmentObject private var gamification: GamificationService
    @EnvironmentObject private var reminders: ReminderService
    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var speech: SpeechService
    @AppStorage("today.mode") private var mode: TodayMode = .quiz
    @State private var launch: TodayLaunch?

    var body: some View {
        let visiblePairs = pairs.filter(\.hasWords)
        let struggling = words.filter(\.inReview).count
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                link(open: openProgress, destination: ProgressPage()) { streakCard }

                if visiblePairs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add your first word").font(Typeface.title(19)).foregroundColor(Palette.ink)
                        Text("Open Library, pick a language pair and type a word. Its reviews show up here.")
                            .font(Typeface.body(14)).foregroundColor(Palette.ink.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                } else {
                    HStack(spacing: 12) {
                        Picker("Review with", selection: $mode) {
                            ForEach(TodayMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Toggle(isOn: Binding(get: { speech.speakAloud }, set: { speech.speakAloud = $0 })) {
                            Image(systemName: speech.speakAloud ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        }
                        .toggleStyle(.button)
                        .help("Speak words aloud")
                        .accessibilityLabel("Speak words aloud")
                    }

                    if struggling > 0 {
                        link(open: openReviewBook, destination: WordListScreen(target: .review)) {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.uturn.backward.circle.fill")
                                    .font(.system(size: 26)).foregroundColor(Palette.cherry)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Struggling words (\(struggling))").font(Typeface.title(17)).foregroundColor(Palette.ink)
                                    Text("Your Review Book: words you missed. Two correct reviews in a row clear them.")
                                        .font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.65))
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").foregroundColor(Palette.ink.opacity(0.35))
                            }
                            .card()
                        }
                    }

                    ForEach(visiblePairs) { pair in
                        TodayPairCard(pair: pair, summary: planner.summary(for: pair)) {
                            launch = TodayLaunch(pair: pair, mode: mode)
                        }
                    }

                    Text("Reviews follow the forgetting curve: a word comes back after 1, 2, 4, 7, 15 and 30 days, and is remembered once it passes the 30-day review. Up to \(planner.newPerDay) new words a day per language pair; change it in Settings → Daily review.")
                        .font(Typeface.body(13))
                        .foregroundColor(Palette.ink.opacity(0.6))
                }
                if reminders.enabled && reminders.authorization == .denied {
                    Label("Reminders are off because notifications are turned off for DayDayUP in system Settings.",
                          systemImage: "bell.slash")
                        .font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.6))
                }
            }
            .padding(16)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Today")
        .sheet(item: $launch) { TodaySessionSheet(launch: $0) }
        .task { await reminders.requestPermissionIfNeeded() }
    }

    /// A tappable card: calls `open` when given (Mac), otherwise pushes `destination` (iPhone).
    @ViewBuilder private func link<Destination: View, Label: View>(open: (() -> Void)?, destination: Destination,
                                                                  @ViewBuilder label: () -> Label) -> some View {
        if let open {
            Button(action: open, label: label).buttonStyle(.plain)
        } else {
            NavigationLink(destination: destination, label: label).buttonStyle(.plain)
        }
    }

    private var streakCard: some View {
        HStack(spacing: 14) {
            StreakFlame(count: gamification.currentStreak, lit: gamification.todayQualifies)
                .font(Typeface.display(28))
            VStack(alignment: .leading, spacing: 2) {
                Text(gamification.todayQualifies ? "Streak earned today" : "Keep your streak going")
                    .font(Typeface.title(17)).foregroundColor(Palette.ink)
                Text(gamification.todayQualifies
                     ? "Come back tomorrow to make it \(gamification.currentStreak + 1). Tap for your progress."
                     : "Clear today's reviews, or finish a round of \(ReviewSchedule.roundSize). Tap for your progress.")
                    .font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.65))
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chart.bar.fill").foregroundColor(Palette.grape)
        }
        .card()
    }
}

private struct TodayPairCard: View {
    @ObservedObject var pair: LanguagePairMO
    let summary: TodayPlanner.Summary
    let start: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            PairBadge(from: pair.from, to: pair.to, accent: pair.accent, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(pair.title).font(Typeface.title(19)).foregroundColor(Palette.ink)
                Text(detail).font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.65))
            }
            Spacer(minLength: 0)
            if summary.isEmpty {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundColor(Palette.mint)
                    .accessibilityLabel("All done for today")
            } else {
                Button("Start", action: start)
                    .buttonStyle(ChunkyButtonStyle(color: pair.accent, height: 40, fullWidth: false))
                    .lineLimit(1).fixedSize()
            }
        }
        .card()
    }

    private var detail: String {
        var parts: [String] = []
        if summary.due > 0 { parts.append("\(summary.due) due") }
        if summary.newToday > 0 { parts.append("\(summary.newToday) new") }
        if parts.isEmpty {
            if summary.total == 0 { return "No words yet · add some in Library" }
            return summary.newWaiting > 0 ? "All done · today's new words are started" : "All done for today"
        }
        return parts.joined(separator: " · ")
    }
}

struct TodayLaunch: Identifiable {
    let id = UUID()
    let pair: LanguagePairMO
    let mode: TodayMode
}

/// Runs Today rounds for one pair as a quiz or flashcards.
private struct TodaySessionSheet: View {
    let launch: TodayLaunch
    @EnvironmentObject private var planner: TodayPlanner
    @EnvironmentObject private var repository: VocabRepository

    var body: some View {
        let pair = launch.pair
        let source = TodayRoundSource(
            next: { planner.nextRound(for: pair) },
            remaining: {
                let summary = planner.summary(for: pair)
                return summary.due + summary.newToday
            })
        let pool = repository.liveWords(in: pair)
        Group {
            switch launch.mode {
            case .quiz: QuizFlow(pool: pool, accent: pair.accent, today: source)
            case .flashcards: FlashcardSession(pool: pool, accent: pair.accent, today: source)
            }
        }
        .macSheetSize(minWidth: 640, minHeight: 640)
    }
}
