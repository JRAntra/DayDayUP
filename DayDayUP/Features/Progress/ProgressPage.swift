import SwiftUI

/// Charts, streak and achievements in one place, opened from the streak card on Today.
struct ProgressPage: View {
    @EnvironmentObject private var gamification: GamificationService
    @EnvironmentObject private var repository: VocabRepository
    @FetchRequest(fetchRequest: Fetch.pairs()) private var pairs: FetchedResults<LanguagePairMO>
    /// Watched so the charts update as soon as an answer or new word changes the data.
    @FetchRequest(fetchRequest: Fetch.words(NSPredicate(format: "deletedAt == nil"))) private var words: FetchedResults<WordMO>
    @State private var pairID: UUID?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        let pairsWithWords = pairs.filter(\.hasWords)
        let scoped = words.filter { pairID == nil || $0.pair?.id == pairID }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if pairsWithWords.count > 1 {
                    Picker("Language pair", selection: $pairID) {
                        Text("All pairs").tag(UUID?.none)
                        ForEach(pairsWithWords) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                ActivityChart(days: activityDays(scoped))
                LadderChart(counts: ladderCounts(scoped.filter(\.isReviewable)))
                streakHeader
                section("Remembered words", kind: .remembered)
                section("Daily streak", kind: .streak)
                section("Collector", kind: .collected)
            }
            .padding(20)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Progress")
        .onAppear { gamification.refresh() }
    }

    /// The last 30 days, oldest first.
    private func activityDays(_ scoped: [WordMO]) -> [ActivityChart.Day] {
        let today = DayKey.today
        let first = DayKey.adding(-(ActivityChart.dayCount - 1), to: today)
        let records = repository.activities(from: first)
        var added: [String: Int] = [:]
        for word in scoped { added[DayKey.of(word.addedDate), default: 0] += 1 }
        return (0..<ActivityChart.dayCount).map { offset in
            let day = DayKey.adding(offset, to: first)
            let answers = records[day]?.answers(pairID: pairID) ?? (correct: 0, missed: 0)
            return .init(day: day, correct: answers.correct, missed: answers.missed, added: added[day] ?? 0)
        }
    }

    /// Words per ladder step: New, steps 1–6, Remembered.
    private func ladderCounts(_ scoped: [WordMO]) -> [Int] {
        var counts = Array(repeating: 0, count: ReviewSchedule.rememberedStep + 1)
        for word in scoped { counts[min(max(Int(word.step), 0), ReviewSchedule.rememberedStep)] += 1 }
        return counts
    }

    private var streakHeader: some View {
        HStack(spacing: 18) {
            Image(systemName: "flame.fill")
                .font(.system(size: 54, weight: .bold))
                .foregroundColor(gamification.currentStreak > 0 ? Palette.tangerine : Palette.line)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(gamification.currentStreak)-day streak").font(Typeface.display(30))
                Text("Longest: \(gamification.longestStreak) days").font(Typeface.body(15)).foregroundColor(Palette.ink.opacity(0.7))
                Text(gamification.todayQualifies
                     ? "Today is done. See you tomorrow."
                     : "Today counts once you clear today's reviews or finish a round of \(ReviewSchedule.roundSize).")
                    .font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.6))
            }
            Spacer()
        }
        .card(padding: 20)
    }

    private func section(_ title: String, kind: AchievementDefinition.Kind) -> some View {
        let items = AchievementDefinition.all.filter { $0.kind == kind }
        let progress = items.first.map { gamification.progress(for: $0) } ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Typeface.title(20))
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { item in
                    badge(item, unlockedAt: gamification.unlockedKeys[item.key], progress: progress)
                }
            }
        }
    }

    private func badge(_ item: AchievementDefinition, unlockedAt: Date?, progress: Int) -> some View {
        let unlocked = unlockedAt != nil
        return VStack(spacing: 8) {
            ZStack {
                Circle().fill(unlocked ? Palette.sunshine : Palette.surfaceSunken)
                Circle().stroke(unlocked ? Palette.tangerine : Palette.line, lineWidth: 4)
                Image(systemName: unlocked ? item.symbol : "lock.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(unlocked ? .white : Palette.ink.opacity(0.3))
            }
            .frame(width: 70, height: 70)
            Text(item.title).font(Typeface.title(15)).foregroundColor(Palette.ink).multilineTextAlignment(.center)
            Text(item.detail).font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.6)).multilineTextAlignment(.center)
            if let unlockedAt {
                Text(unlockedAt.formatted(date: .abbreviated, time: .omitted)).font(Typeface.label(11)).foregroundColor(Palette.tangerine)
            } else {
                ProgressView(value: Double(min(progress, item.threshold)), total: Double(item.threshold)).tint(Palette.grape)
                Text("\(min(progress, item.threshold)) / \(item.threshold)").font(Typeface.label(11)).foregroundColor(Palette.ink.opacity(0.5)).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 14)
        .opacity(unlocked ? 1 : 0.85)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Charts

/// Chart colors, checked with the dataviz palette validator for colorblind separation in both modes.
enum ChartPalette {
    static let correct = Color.adaptive(light: "2563EB", dark: "4C8DFF")
    static let missed = Color.adaptive(light: "EA7A12", dark: "D9741C")
    /// Words added is a neutral line, so it never competes with the two answer colors.
    static let added = Palette.ink
}

/// Reviews per day (correct and missed stacked) with words added as a line, on one shared count axis.
/// Tap or hover a day to read its numbers; otherwise the line shows 30-day totals.
struct ActivityChart: View {
    static let dayCount = 30

    struct Day: Identifiable {
        let day: String
        let correct: Int
        let missed: Int
        let added: Int
        var id: String { day }
        var reviews: Int { correct + missed }
    }

    let days: [Day]
    @State private var selected: String?

    private var maxValue: Int { max(1, days.map { max($0.reviews, $0.added) }.max() ?? 1) }
    private var plotHeight: CGFloat { 150 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity · last 30 days").font(Typeface.title(18))
            legend
            Text(readout).font(Typeface.label(13)).foregroundColor(Palette.ink.opacity(0.75)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            plot
            HStack {
                Text(shortDate(days.first?.day))
                Spacer()
                Text("Today")
            }
            .font(Typeface.body(11)).foregroundColor(Palette.ink.opacity(0.55))
            .padding(.trailing, 26)
            if days.allSatisfy({ $0.reviews == 0 }) {
                Text("Review counts start from this version of DayDayUP. Finish a Today round to see your first bar.")
                    .font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(ChartPalette.correct, "Correct")
            legendItem(ChartPalette.missed, "Missed")
            HStack(spacing: 6) {
                Capsule().fill(ChartPalette.added).frame(width: 16, height: 2)
                Text("Words added")
            }
        }
        .font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.75))
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private var readout: String {
        if let selected, let day = days.first(where: { $0.day == selected }) {
            return "\(shortDate(day.day)) · \(day.correct) correct · \(day.missed) missed · \(day.added) added"
        }
        let correct = days.reduce(0) { $0 + $1.correct }
        let missed = days.reduce(0) { $0 + $1.missed }
        let added = days.reduce(0) { $0 + $1.added }
        return "30 days · \(correct) correct · \(missed) missed · \(added) added"
    }

    private var plot: some View {
        GeometryReader { geo in
            let count = CGFloat(days.count)
            // A right-hand gutter holds the axis label, so it never sits on top of the data.
            let gutter: CGFloat = 26
            let slot = (geo.size.width - gutter) / count
            let barWidth = max(3, slot - 3)
            let scale = plotHeight / CGFloat(maxValue)
            ZStack(alignment: .bottomLeading) {
                // Recessive grid: baseline and the top value.
                // Grid lines at exactly 0 and the top value, with their labels in the gutter.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0.5))
                    path.addLine(to: CGPoint(x: geo.size.width - gutter, y: 0.5))
                }
                .stroke(Palette.line.opacity(0.6), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: plotHeight - 0.5))
                    path.addLine(to: CGPoint(x: geo.size.width - gutter, y: plotHeight - 0.5))
                }
                .stroke(Palette.line, lineWidth: 1)
                Text("\(maxValue)").font(Typeface.body(10)).foregroundColor(Palette.ink.opacity(0.5)).monospacedDigit()
                    .position(x: geo.size.width - gutter / 2, y: 0)
                Text("0").font(Typeface.body(10)).foregroundColor(Palette.ink.opacity(0.5))
                    .position(x: geo.size.width - gutter / 2, y: plotHeight)
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let x = CGFloat(index) * slot + (slot - barWidth) / 2
                    let correctHeight = CGFloat(day.correct) * scale
                    let missedHeight = CGFloat(day.missed) * scale
                    let dimmed = selected != nil && selected != day.day
                    VStack(spacing: 2) {   // 2pt surface gap between the stacked segments
                        if day.missed > 0 {
                            UnevenRoundedTop(radius: min(4, barWidth / 2))
                                .fill(ChartPalette.missed)
                                .frame(width: barWidth, height: max(2, missedHeight - (day.correct > 0 ? 2 : 0)))
                        }
                        if day.correct > 0 {
                            UnevenRoundedTop(radius: day.missed > 0 ? 0 : min(4, barWidth / 2))
                                .fill(ChartPalette.correct)
                                .frame(width: barWidth, height: max(2, correctHeight))
                        }
                    }
                    .opacity(dimmed ? 0.35 : 1)
                    .offset(x: x)
                }
                // Words added: a 2pt line with ≥8pt markers on days with additions.
                Path { path in
                    for (index, day) in days.enumerated() {
                        let point = CGPoint(x: CGFloat(index) * slot + slot / 2, y: plotHeight - CGFloat(day.added) * scale)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(ChartPalette.added.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(height: plotHeight)
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    if day.added > 0 {
                        Circle().fill(ChartPalette.added)
                            .overlay(Circle().stroke(Palette.surface, lineWidth: 2))
                            .frame(width: 8, height: 8)
                            .position(x: CGFloat(index) * slot + slot / 2, y: plotHeight - CGFloat(day.added) * scale)
                    }
                }
                .frame(height: plotHeight)
                // Hit targets: one full-height column per day, wider than the bar.
                HStack(spacing: 0) {
                    ForEach(days) { day in
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .frame(width: slot, height: plotHeight)
                            .onTapGesture { selected = selected == day.day ? nil : day.day }
                            #if os(macOS)
                            .onHover { inside in
                                if inside { selected = day.day } else if selected == day.day { selected = nil }
                            }
                            #endif
                            .accessibilityElement()
                            .accessibilityLabel("\(shortDate(day.day)): \(day.correct) correct, \(day.missed) missed, \(day.added) added")
                    }
                }
            }
            .frame(height: plotHeight, alignment: .bottom)
        }
        .frame(height: plotHeight)
    }

    private func shortDate(_ key: String?) -> String {
        guard let key, let date = DayKey.date(from: key) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A rectangle with rounded top corners only, so bars stay anchored to the baseline.
struct UnevenRoundedTop: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// How many words sit on each step of the review ladder.
struct LadderChart: View {
    /// New, steps 1–6, Remembered.
    let counts: [Int]

    private var labels: [String] {
        ["New"] + ReviewSchedule.gaps.map { "\($0)-day" } + ["Remembered"]
    }

    var body: some View {
        let maxCount = max(1, counts.max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            Text("Where your words are").font(Typeface.title(18))
            Text("Words on each step of the review ladder. A word moves down the list as it passes reviews.")
                .font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(counts.enumerated()), id: \.offset) { index, count in
                HStack(spacing: 10) {
                    Text(labels[index]).font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.75))
                        .frame(width: 84, alignment: .leading)
                    GeometryReader { geo in
                        UnevenRoundedRight(radius: 4)
                            .fill(index == 0 ? Palette.ink.opacity(0.3) : ChartPalette.correct)
                            .frame(width: count == 0 ? 0 : max(4, geo.size.width * CGFloat(count) / CGFloat(maxCount)))
                    }
                    .frame(height: 14)
                    Text("\(count)").font(Typeface.label(12)).foregroundColor(Palette.ink.opacity(0.8)).monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }
}

/// A rectangle with rounded right corners only, anchored at the left baseline.
struct UnevenRoundedRight: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
