import SwiftUI

/// The entry row under every table. Return or the Add button runs a lookup.
struct AddWordBar: View {
    let category: CategoryMO
    let folder: FolderMO?
    let accent: Color

    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var lookup: LookupService
    @EnvironmentObject private var gamification: GamificationService
    @State private var text = ""
    @State private var busy = false
    @State private var picker: LookupSession?
    @State private var toast: String?
    @FocusState private var focused: Bool

    private var pair: LanguagePairMO? { category.pair }

    private var placeholder: String {
        guard let language = pair?.from.displayName else { return "Add a word" }
        let article = "AEIOU".contains(language.prefix(1).uppercased()) ? "an" : "a"
        return "Add \(article) \(language) word"
    }

    var body: some View {
        VStack(spacing: 6) {
            if let toast {
                Text(toast)
                    .font(Typeface.label(13))
                    .foregroundColor(Palette.ink.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Palette.surfaceSunken))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                // Return is only delivered after Chinese/Japanese input-method composition is committed,
                // so confirming a candidate in the IME never triggers a lookup.
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(Typeface.title(18))
                    .focused($focused)
                    .onSubmit(submit)
                    .disableAutocorrection(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surfaceSunken))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(focused ? accent : Palette.line, lineWidth: 2))
                Button(action: submit) {
                    if busy { ProgressView().controlSize(.small) } else { Label("Add", systemImage: "plus") }
                }
                .buttonStyle(ChunkyButtonStyle(color: accent, height: 48, fullWidth: false))
                .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Palette.surface.ignoresSafeArea(edges: .bottom))
        .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .top)
        .sheet(item: $picker) { session in
            LookupSheet(session: session, accent: accent) { term, candidates in
                save(term: term, chosen: candidates, existing: session.existing)
            } onLookup: { newTerm in
                picker = nil
                text = newTerm
                Task { await run(newTerm) }
            } onAddEmpty: { term in
                picker = nil
                let word = repository.addWord(term: term, reading: "", senses: [Sense(translation: "")], category: category, folder: folder)
                gamification.recordWordsAdded()
                showToast("Added \(word.termValue). Open it to type the meaning.")
                text = ""
            }
        }
    }

    private func submit() {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !busy else { return }
        Task { await run(term) }
    }

    private func run(_ term: String) async {
        guard let pair else { return }
        busy = true
        defer { busy = false }
        let existing = repository.existingWord(term: term, in: category)
        let outcome = await lookup.lookup(existing?.termValue ?? term, from: pair.from, to: pair.to)

        // Always ask before saving, even when there's only one meaning: the person confirms or changes it.
        // For a word already in this category, its saved meanings show ticked and locked.
        picker = LookupSession(outcome: outcome, existing: existing)
    }

    private func save(term: String, chosen: [LookupCandidate], existing: WordMO?) {
        picker = nil
        if let existing {
            let before = existing.senses.count
            repository.mergeSenses(chosen.map(\.sense), into: existing)
            let added = existing.senses.count - before
            showToast(added == 0 ? "\(existing.termValue) is already saved here." : "Added \(added) meaning\(added == 1 ? "" : "s") to \(existing.termValue).")
        } else {
            let reading = chosen.first?.reading ?? ""
            let word = repository.addWord(term: term, reading: reading, senses: chosen.map(\.sense), category: category, folder: folder)
            gamification.recordWordsAdded()
            let others = repository.otherCategories(for: word).map(\.displayName)
            var message = "Added \(word.termValue)."
            if !others.isEmpty { message += " Also in \(others.joined(separator: ", "))." }
            showToast(message)
        }
        text = ""
        focused = true
    }

    private func showToast(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { toast = message }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            withAnimation(.easeOut(duration: 0.25)) { if toast == message { toast = nil } }
        }
    }
}

struct LookupSession: Identifiable {
    let id = UUID()
    let outcome: LookupOutcome
    let existing: WordMO?
}

/// Pick meanings in order (first pick = primary), choose a suggestion, or add without a meaning.
struct LookupSheet: View {
    let session: LookupSession
    let accent: Color
    let onSave: (String, [LookupCandidate]) -> Void
    let onLookup: (String) -> Void
    let onAddEmpty: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var order: [UUID]

    init(session: LookupSession, accent: Color,
         onSave: @escaping (String, [LookupCandidate]) -> Void,
         onLookup: @escaping (String) -> Void,
         onAddEmpty: @escaping (String) -> Void) {
        self.session = session
        self.accent = accent
        self.onSave = onSave
        self.onLookup = onLookup
        self.onAddEmpty = onAddEmpty
        // A new word starts with the first (most common) meaning ticked, so confirming is one click.
        if session.existing == nil, case .senses(_, let candidates) = session.outcome, let first = candidates.first {
            _order = State(initialValue: [first.id])
        } else {
            _order = State(initialValue: [])
        }
    }

    private var term: String {
        switch session.outcome {
        case .senses(let t, _), .suggestions(let t, _), .nothing(let t, _): return session.existing?.termValue ?? t
        }
    }

    private var existingKeys: Set<String> { Set((session.existing?.senses ?? []).map(\.matchKey)) }

    var body: some View {
        NavigationStackCompat {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { content }
                        .padding(16)
                }
                footer
            }
            .background(Palette.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .macSheetSize(minWidth: 460, minHeight: 520)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(term).font(Typeface.display(34)).foregroundColor(Palette.ink)
            Text(subtitle).font(Typeface.body(14)).foregroundColor(Palette.ink.opacity(0.6))
        }
        .padding(.top, 20).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        switch session.outcome {
        case .senses(_, let candidates): return session.existing != nil
            ? "Already saved here. Tap any meanings you want to add after the saved ones."
            : candidates.count == 1
                ? "Check the meaning, then add the word."
                : "Tap to choose the meanings to save. Number 1 is the one quizzes test."
        case .suggestions: return "No exact match. Did you mean one of these?"
        case .nothing: return "No match found."
        }
    }

    @ViewBuilder private var content: some View {
        switch session.outcome {
        case .senses(_, let candidates):
            if let existing = session.existing, !existing.senses.isEmpty {
                Text("Saved").font(Typeface.label(13)).foregroundColor(Palette.ink.opacity(0.6))
                ForEach(Array(existing.senses.enumerated()), id: \.offset) { index, sense in
                    SenseRow(sense: sense, reading: "", source: "", badge: "\(index + 1)", selected: true, locked: true, accent: accent)
                }
                Text("More meanings").font(Typeface.label(13)).foregroundColor(Palette.ink.opacity(0.6)).padding(.top, 6)
            }
            ForEach(candidates) { candidate in
                let already = existingKeys.contains(candidate.sense.matchKey)
                let position = order.firstIndex(of: candidate.id)
                Button {
                    guard !already else { return }
                    Haptics.tap()
                    if let position { order.remove(at: position) } else { order.append(candidate.id) }
                } label: {
                    SenseRow(sense: candidate.sense, reading: candidate.reading, source: candidate.source,
                             badge: position.map { "\((session.existing?.senses.count ?? 0) + $0 + 1)" },
                             selected: already || position != nil, locked: already, accent: accent)
                }
                .buttonStyle(.plain)
            }
            if session.existing == nil {
                Button { onAddEmpty(term) } label: {
                    Label("None of these fit? Add \(term) and type the meaning myself", systemImage: "square.and.pencil")
                        .font(Typeface.label(13))
                }
                .buttonStyle(.plain)
                .foregroundColor(accent)
                .padding(.top, 6)
            }

        case .suggestions(_, let words):
            ForEach(words, id: \.self) { word in
                Button { onLookup(word) } label: {
                    HStack {
                        Text(word).font(Typeface.title(18)).foregroundColor(Palette.ink)
                        Spacer()
                        Image(systemName: "arrow.forward.circle.fill").foregroundColor(accent)
                    }
                    .card(padding: 14)
                }
                .buttonStyle(.plain)
            }
            addEmptyButton

        case .nothing(_, let message):
            Text(message).font(Typeface.body(15)).foregroundColor(Palette.ink.opacity(0.75))
            addEmptyButton
        }
    }

    private var addEmptyButton: some View {
        Button { onAddEmpty(term) } label: { Label("Add \(term) and type the meaning myself", systemImage: "square.and.pencil") }
            .buttonStyle(OutlineChunkyButtonStyle(color: accent))
            .padding(.top, 8)
            .opacity(session.existing == nil ? 1 : 0)
    }

    @ViewBuilder private var footer: some View {
        if case .senses(let headword, let candidates) = session.outcome {
            let chosen = order.compactMap { id in candidates.first { $0.id == id } }
            let name = session.existing?.termValue ?? headword
            Button {
                onSave(name, chosen)
            } label: {
                Text(chosen.isEmpty ? "Pick at least one meaning"
                     : session.existing != nil ? "Add \(chosen.count) meaning\(chosen.count == 1 ? "" : "s") to \(name)"
                     : chosen.count == 1 ? "Add \(name)"
                     : "Add \(name) with \(chosen.count) meanings")
            }
            .buttonStyle(ChunkyButtonStyle(color: chosen.isEmpty ? Palette.line : accent))
            .disabled(chosen.isEmpty)
            .keyboardShortcut(.defaultAction)   // Return confirms; Esc cancels (the Cancel button).
            .padding(16)
            .background(Palette.surface)
        }
    }
}

private struct SenseRow: View {
    let sense: Sense
    let reading: String
    let source: String
    let badge: String?
    let selected: Bool
    let locked: Bool
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(selected ? accent : Palette.surfaceSunken)
                    .overlay(Circle().stroke(selected ? accent : Palette.line, lineWidth: 2))
                if let badge, selected {
                    Text(badge).font(Typeface.label(13)).foregroundColor(.white)
                } else if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .black)).foregroundColor(.white)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !sense.partOfSpeech.isEmpty {
                        Text(sense.partOfSpeech).font(Typeface.label(12)).foregroundColor(accent)
                    }
                    Text(sense.translation.isEmpty ? "No translation found" : sense.translation)
                        .font(Typeface.title(17))
                        .foregroundColor(sense.translation.isEmpty ? Palette.ink.opacity(0.4) : Palette.ink)
                    if sense.approximate {
                        Text("approximate").font(Typeface.label(10)).foregroundColor(Palette.tangerine)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Palette.tangerine.opacity(0.15)))
                    }
                }
                if !sense.english.isEmpty && sense.english != sense.translation {
                    Text(sense.english).font(Typeface.body(14)).foregroundColor(Palette.ink.opacity(0.65))
                }
                if !reading.isEmpty || !source.isEmpty {
                    Text([reading, source].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                        .font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: 12)
        .opacity(locked ? 0.6 : 1)
        .contentShape(Rectangle())
    }
}
