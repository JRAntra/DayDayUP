import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Inspector on Mac, detail screen on iPhone.
struct WordEditorView: View {
    @ObservedObject var word: WordMO

    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var lookup: LookupService
    @EnvironmentObject private var speech: SpeechService
    @Environment(\.dismiss) private var dismiss

    @State private var senses: [Sense] = []
    @State private var picker: LookupSession?
    @State private var lookingUp = false
    @State private var showMove = false
    @State private var alsoIn: CategoryMO?
    @State private var confirmDelete = false
    #if os(iOS)
    @State private var showAppleDictionary = false
    #endif

    private var accent: Color { word.pair?.accent ?? Palette.grape }
    private var pair: LanguagePairMO? { word.pair }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                sensesCard
                notesCard
                statusCard
            }
            .padding(16)
        }
        .background(Palette.background)
        .navigationTitle(word.termValue)
        .onAppear { senses = word.senses }
        .onChange(of: senses) { newValue in
            if newValue != word.senses {
                word.senses = newValue
                repository.save()
            }
        }
        .onDisappear { repository.save() }
        .sheet(item: $picker) { session in
            LookupSheet(session: session, accent: accent) { _, chosen in
                repository.mergeSenses(chosen.map(\.sense), into: word)
                senses = word.senses
                picker = nil
            } onLookup: { _ in picker = nil } onAddEmpty: { _ in picker = nil }
        }
        .sheet(isPresented: $showMove) { MoveWordsSheet(words: [word]) }
        .sheet(item: $alsoIn) { category in
            NavigationStackCompat {
                WordListScreen(target: .category(category))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { alsoIn = nil } } }
            }
            .macSheetSize(minWidth: 640, minHeight: 520)
        }
        #if os(iOS)
        .sheet(isPresented: $showAppleDictionary) { AppleDictionarySheet(term: word.termValue) }
        #endif
        .confirmationDialog("Delete \(word.termValue)?", isPresented: $confirmDelete) {
            Button("Move to Recently Deleted", role: .destructive) {
                repository.delete([word])
                dismiss()
            }
        } message: {
            Text("You can restore it from Recently Deleted for 30 days.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ProgressRing(step: Int(word.step), inReview: word.inReview, accent: accent, size: 54)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Word", text: Binding(get: { word.termValue }, set: { newValue in
                    word.term = newValue
                    if let category = word.category { word.termKey = repository.termKey(newValue, in: category) }
                    word.touch()
                }))
                .textFieldStyle(.plain)
                .font(Typeface.display(30))
                TextField("Reading (pinyin, kana or phonetic)", text: Binding(get: { word.readingValue }, set: {
                    word.reading = $0
                    word.touch()
                }))
                .textFieldStyle(.plain)
                .font(Typeface.body(16))
                .foregroundColor(Palette.ink.opacity(0.7))
            }
            Spacer()
            Button { speech.speak(word) } label: {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 18, weight: .bold))
            }
            .buttonStyle(ChunkyButtonStyle(color: accent, height: 44, fullWidth: false))
            .accessibilityLabel("Play pronunciation")
        }
        .card()
    }

    // MARK: Senses

    private var sensesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Meanings").font(Typeface.title(18))
                Spacer()
                Text("The first meaning is the one quizzes test.")
                    .font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.55))
            }
            ForEach(Array(senses.enumerated()), id: \.element.id) { index, sense in
                senseEditor(index, id: sense.id)
            }
            HStack(spacing: 10) {
                Button { senses.append(Sense(translation: "")) } label: { Label("Add meaning", systemImage: "plus") }
                    .buttonStyle(OutlineChunkyButtonStyle(color: accent))
                Button { Task { await lookUpMore() } } label: {
                    if lookingUp { ProgressView().controlSize(.small) } else { Label("Look up more", systemImage: "text.magnifyingglass") }
                }
                .buttonStyle(OutlineChunkyButtonStyle(color: accent))
                Button { openAppleDictionary() } label: { Label("Apple Dictionary", systemImage: "character.book.closed") }
                    .buttonStyle(OutlineChunkyButtonStyle(color: accent))
            }
        }
        .card()
    }

    /// Bindings are looked up by id so deleting or reordering never reads a stale index.
    private func binding(for id: UUID) -> Binding<Sense> {
        Binding(get: { senses.first { $0.id == id } ?? Sense(translation: "") },
                set: { newValue in
                    if let i = senses.firstIndex(where: { $0.id == id }) { senses[i] = newValue }
                })
    }

    private func currentIndex(_ id: UUID) -> Int? { senses.firstIndex { $0.id == id } }

    private func senseEditor(_ index: Int, id: UUID) -> some View {
        let field = binding(for: id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(Typeface.label(13)).foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(index == 0 ? accent : Palette.ink.opacity(0.35)))
                TextField(pair.map { "Translation in \($0.to.displayName)" } ?? "Translation", text: field.translation)
                    .textFieldStyle(.plain)
                    .font(Typeface.title(17))
                if field.wrappedValue.approximate {
                    Text("approximate").font(Typeface.label(10)).foregroundColor(Palette.tangerine)
                }
                Menu {
                    if index > 0 {
                        Button("Make primary") { if let i = currentIndex(id) { move(i, to: 0) } }
                        Button("Move up") { if let i = currentIndex(id), i > 0 { move(i, to: i - 1) } }
                    }
                    if index < senses.count - 1 {
                        Button("Move down") { if let i = currentIndex(id), i < senses.count - 1 { move(i, to: i + 1) } }
                    }
                    Divider()
                    Button("Delete meaning", role: .destructive) { senses.removeAll { $0.id == id } }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 18))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HStack(spacing: 8) {
                TextField("Part of speech", text: field.partOfSpeech)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                TextField("English explanation", text: field.english)
                    .textFieldStyle(.roundedBorder)
            }
            .font(Typeface.body(14))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surfaceSunken))
    }

    private func move(_ from: Int, to: Int) {
        let item = senses.remove(at: from)
        senses.insert(item, at: to)
    }

    private func lookUpMore() async {
        guard let pair else { return }
        lookingUp = true
        let outcome = await lookup.lookup(word.termValue, from: pair.from, to: pair.to)
        lookingUp = false
        picker = LookupSession(outcome: outcome, existing: word)
    }

    private func openAppleDictionary() {
        #if os(iOS)
        showAppleDictionary = true
        #else
        let encoded = word.termValue.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word.termValue
        if let url = URL(string: "dict://\(encoded)") { NSWorkspace.shared.open(url) }
        #endif
    }

    // MARK: Notes

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Example sentence").font(Typeface.label(13)).foregroundColor(Palette.ink.opacity(0.6))
            TextField("Optional", text: Binding(get: { word.example ?? "" }, set: { word.example = $0; word.touch() }))
                .textFieldStyle(.roundedBorder)
            Text("Notes").font(Typeface.label(13)).foregroundColor(Palette.ink.opacity(0.6))
            TextField("Anything that helps you remember", text: Binding(get: { word.notes ?? "" }, set: { word.notes = $0; word.touch() }))
                .textFieldStyle(.roundedBorder)
        }
        .font(Typeface.body(15))
        .card()
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusText).font(Typeface.title(16))
            Text("\(word.timesMissed) times missed · added \(word.addedDate.formatted(date: .abbreviated, time: .omitted)) · \(word.category?.displayName ?? "") / \(word.folderName)")
                .font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.6))

            let others = repository.otherCategories(for: word)
            if !others.isEmpty {
                HStack(spacing: 6) {
                    Text("Also in:").font(Typeface.label(13))
                    ForEach(others, id: \.objectID) { category in
                        Button(category.displayName) { alsoIn = category }
                            .buttonStyle(.borderless)
                            .font(Typeface.label(13))
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    repository.setInReview([word], !word.inReview)
                } label: {
                    Label(word.inReview ? "Remove from Review Book" : "Add to Review Book", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(OutlineChunkyButtonStyle(color: Palette.cherry))
                Button { showMove = true } label: { Label("Move", systemImage: "folder") }
                    .buttonStyle(OutlineChunkyButtonStyle(color: accent))
                Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .buttonStyle(OutlineChunkyButtonStyle(color: Palette.cherry))
            }
        }
        .card()
    }

    private var statusText: String {
        let total = ReviewSchedule.reviewsToRemember
        let passed = max(0, min(Int(word.step), ReviewSchedule.rememberedStep) - 1)
        let next = word.isDue ? "due today" : "next review \(word.dueText.lowercased())"
        if word.isNew { return "New · starts the first time you answer it" }
        if word.inReview { return "In the Review Book · \(next)" }
        if word.isRemembered { return "Remembered · next check-up \(word.dueText.lowercased())" }
        return "\(passed) of \(total) reviews passed · \(next)"
    }
}

#if os(iOS)
/// Apple's built-in dictionaries, including Chinese and Japanese ones the user has downloaded.
struct AppleDictionarySheet: UIViewControllerRepresentable {
    let term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController { UIReferenceLibraryViewController(term: term) }
    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}
#endif
