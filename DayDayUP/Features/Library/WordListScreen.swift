import CoreData
import SwiftUI
import UniformTypeIdentifiers

/// Launches the Study sheet on whatever the list is showing.
struct StudyLaunch: Identifiable {
    let id = UUID()
    let words: [WordMO]
    let accent: Color
}

struct WordListScreen: View {
    let target: WordListTarget

    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var dictionaries: DictionaryManager
    @EnvironmentObject private var library: LibraryState
    @State private var filter: WordFilter
    @State private var showFilters = false
    @State private var study: StudyLaunch?
    @State private var exportDocument = CSVDocument(text: "")
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var importText: ImportRequest?
    @State private var message: String?

    struct ImportRequest: Identifiable { let id = UUID(); let text: String }

    init(target: WordListTarget) {
        self.target = target
        _filter = State(initialValue: WordFilter(scope: target.scope))
    }

    private var accent: Color { target.accent }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(filter: $filter, target: target, expanded: $showFilters)
            if let pair = target.pair, !dictionaries.isInstalled(pair.from.dictionary), !library.isBannerHidden(for: pair) {
                MissingDictionaryBanner(dictionary: pair.from.dictionary, pair: pair)
            }
            WordResults(filter: filter, target: target)
            if let category = target.category {
                AddWordBar(category: category, folder: target.folder, accent: accent)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(target.title)
        .onAppear { library.recordOpened(target) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { launchStudy() } label: { Label("Study", systemImage: "graduationcap.fill") }
                    .help("Quiz or flashcards on the words shown")
                Menu {
                    Button { exportCSV() } label: { Label("Export table as CSV", systemImage: "square.and.arrow.up") }
                    if target.category != nil {
                        Button { showImporter = true } label: { Label("Import CSV into this category", systemImage: "square.and.arrow.down") }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $study) { launch in
            StudySheet(launch: launch)
        }
        .sheet(item: $importText) { request in
            if let category = target.category {
                CSVImportSheet(text: request.text, category: category) { summary in
                    message = summary.message
                }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "\(target.title) words") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    importText = ImportRequest(text: String(decoding: data, as: UTF8.self))
                } else {
                    message = "That file couldn't be read. Export it from your spreadsheet as CSV (UTF-8) and try again."
                }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .alert("DayDayUP", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func launchStudy() {
        let words = repository.words(matching: filter)
        guard !words.isEmpty else {
            message = "There are no words here yet. Add some words or change the filters."
            return
        }
        study = StudyLaunch(words: words, accent: accent)
    }

    private func exportCSV() {
        exportDocument = CSVDocument(text: CSVService.export(repository.words(matching: filter)))
        showExporter = true
    }
}

// MARK: - Filters

private struct FilterBar: View {
    @Binding var filter: WordFilter
    let target: WordListTarget
    @Binding var expanded: Bool

    @FetchRequest(fetchRequest: Fetch.pairs()) private var pairs: FetchedResults<LanguagePairMO>
    @FetchRequest(fetchRequest: Fetch.categories()) private var categories: FetchedResults<CategoryMO>
    @FetchRequest(fetchRequest: Fetch.folders()) private var folders: FetchedResults<FolderMO>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(Palette.ink.opacity(0.5))
                TextField("Search words and meanings", text: $filter.searchText)
                    .textFieldStyle(.plain)
                    .font(Typeface.body(15))
                Picker("Status", selection: $filter.remembered) {
                    ForEach(RememberedFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 20, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(target.accent)
                .accessibilityLabel(expanded ? "Hide filters" : "Show filters")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    scopePickers
                    Toggle("Only words added between", isOn: $filter.useDateRange.animation())
                        .font(Typeface.label(14))
                    if filter.useDateRange {
                        HStack {
                            DatePicker("From", selection: $filter.dateFrom, displayedComponents: .date)
                            DatePicker("To", selection: $filter.dateTo, displayedComponents: .date)
                        }
                        .font(Typeface.label(14))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.surface)
        .overlay(Rectangle().fill(Palette.line).frame(height: 1), alignment: .bottom)
    }

    /// The Review Book filters by pair, category and folder like every other table;
    /// category lists filter by folder.
    @ViewBuilder private var scopePickers: some View {
        if case .review = target {
            HStack {
                Picker("Pair", selection: Binding(get: { filter.scope.pairID }, set: {
                    filter.scope = WordScope(pairID: $0, reviewOnly: true)
                })) {
                    Text("All pairs").tag(UUID?.none)
                    ForEach(pairs) { Text($0.title).tag($0.id) }
                }
                if let pairID = filter.scope.pairID {
                    Picker("Category", selection: Binding(get: { filter.scope.categoryID }, set: {
                        filter.scope = WordScope(pairID: pairID, categoryID: $0, reviewOnly: true)
                    })) {
                        Text("All categories").tag(UUID?.none)
                        ForEach(categories.filter { $0.pair?.id == pairID }) { Text($0.displayName).tag($0.id) }
                    }
                }
                if let categoryID = filter.scope.categoryID {
                    folderPicker(categoryID: categoryID, reviewOnly: true)
                }
            }
            .pickerStyle(.menu)
        } else if case .category(let category) = target, let categoryID = category.id {
            folderPicker(categoryID: categoryID, reviewOnly: false).pickerStyle(.menu)
        }
    }

    private enum FolderChoice: Hashable { case all, unfiled, folder(UUID) }

    private func folderPicker(categoryID: UUID, reviewOnly: Bool) -> some View {
        let current: FolderChoice = filter.scope.folderID.map { .folder($0) } ?? (filter.scope.unfiledOnly ? .unfiled : .all)
        return Picker("Folder", selection: Binding(get: { current }, set: { choice in
            var scope = WordScope(pairID: filter.scope.pairID, categoryID: categoryID, reviewOnly: reviewOnly)
            switch choice {
            case .all: break
            case .unfiled: scope.unfiledOnly = true
            case .folder(let id): scope.folderID = id
            }
            filter.scope = scope
        })) {
            Text("All folders").tag(FolderChoice.all)
            Text("Unfiled").tag(FolderChoice.unfiled)
            ForEach(folders.filter { $0.category?.id == categoryID }) { folder in
                if let id = folder.id { Text(folder.displayName).tag(FolderChoice.folder(id)) }
            }
        }
    }
}

private struct MissingDictionaryBanner: View {
    let dictionary: DictionaryID
    let pair: LanguagePairMO
    @EnvironmentObject private var dictionaries: DictionaryManager
    @EnvironmentObject private var library: LibraryState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical.fill").foregroundColor(Palette.tangerine)
            VStack(alignment: .leading, spacing: 2) {
                Text("Install the \(dictionary.title) dictionary").font(Typeface.label(14))
                Text(detail).font(Typeface.body(12)).foregroundColor(stateColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch dictionaries.state(dictionary) {
            case .downloading(let progress?):
                ProgressView(value: progress).frame(width: 70)
            case .building(let progress):
                ProgressView(value: progress).frame(width: 70)
            case .downloading(nil):
                ProgressView().controlSize(.small)
            default:
                Button("Not now") { library.hideBanner(for: pair) }
                    .buttonStyle(.borderless)
                    .font(Typeface.label(13))
                Button("Download (\(dictionary.downloadSize))") { Task { await dictionaries.download(dictionary) } }
                    .buttonStyle(ChunkyButtonStyle(color: Palette.tangerine, height: 34, fullWidth: false))
                    .lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.tangerine.opacity(0.12))
    }

    private var detail: String {
        switch dictionaries.state(dictionary) {
        case .downloading(let p): return p.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…"
        case .building(let p): return "Converting… \(Int(p * 100))%"
        case .failed(let message): return message
        default: return "Offline lookups, multiple meanings and spelling suggestions."
        }
    }

    private var stateColor: Color {
        if case .failed = dictionaries.state(dictionary) { return Palette.cherry }
        return Palette.ink.opacity(0.65)
    }
}

// MARK: - Results

struct WordResults: View {
    let target: WordListTarget
    @FetchRequest private var words: FetchedResults<WordMO>
    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var speech: SpeechService
    @State private var moveRequest: MoveRequest?
    #if os(macOS)
    @State private var selection = Set<WordMO.ID>()
    @State private var sortOrder = [KeyPathComparator(\WordMO.addedDate, order: .reverse)]
    #endif

    init(filter: WordFilter, target: WordListTarget) {
        self.target = target
        _words = FetchRequest(fetchRequest: Fetch.words(VocabRepository.predicate(for: filter)), animation: .default)
    }

    var body: some View {
        VStack(spacing: 0) {
            if words.isEmpty {
                EmptyStateView(symbol: target == .review ? "sparkles" : "text.badge.plus",
                               title: target == .review ? "Nothing to review" : "No words here yet",
                               message: target == .review
                                ? "Words you miss land here. Two correct reviews in a row clear them."
                                : (target.category == nil
                                   ? "Open a category to add words, or change the filters."
                                   : "Type a word below and press Return. DayDayUP looks up its meanings for you."))
            } else {
                content
            }
        }
        .sheet(item: $moveRequest) { request in
            MoveWordsSheet(words: request.words)
        }
    }

    private struct MoveRequest: Identifiable { let id = UUID(); let words: [WordMO] }

    // MARK: Mac

    #if os(macOS)
    private var sortedWords: [WordMO] { Array(words).sorted(using: sortOrder) }
    private var selectedWords: [WordMO] { words.filter { selection.contains($0.id) } }

    private func deleteSelection() {
        let doomed = selectedWords
        guard !doomed.isEmpty else { return }
        selection.removeAll()
        repository.delete(doomed)
    }

    @ViewBuilder private var content: some View {
        HSplitView {
            Table(sortedWords, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Progress", value: \.stepValue) { word in
                    ProgressRing(step: Int(word.step), inReview: word.inReview, accent: word.pair?.accent ?? target.accent, size: 20)
                }
                .width(min: 56, ideal: 64, max: 72)
                TableColumn("Next review", value: \.daysUntilDue) { word in
                    Text(word.dueText)
                        .foregroundColor(word.isDue ? Palette.tangerine : Palette.ink.opacity(word.isNew ? 0.45 : 0.8))
                }
                .width(min: 70, ideal: 90)
                TableColumn("Word", value: \.termValue) { word in
                    Text(word.termValue).font(Typeface.title(15))
                }
                TableColumn("Reading", value: \.readingValue)
                TableColumn("Part of speech", value: \.posSummary)
                    .width(min: 60, ideal: 90)
                TableColumn("Translation", value: \.translationSummary)
                TableColumn("Folder", value: \.folderName)
                    .width(min: 70, ideal: 100)
                TableColumn("Added", value: \.addedDate) { word in
                    Text(word.addedDate, format: .dateTime.year().month().day())
                }
                .width(min: 80, ideal: 100)
                TableColumn("") { word in
                    Button { speech.speak(word) } label: { Image(systemName: "speaker.wave.2.fill") }
                        .buttonStyle(.borderless)
                        .help("Play pronunciation")
                }
                .width(28)
            }
            .frame(minWidth: 520)
            .onDeleteCommand { deleteSelection() }
            // SwiftUI's Table never delivers the Delete key to onDeleteCommand on current macOS,
            // so a key monitor handles ⌫ / ⌦ while this table has focus.
            .background(TableDeleteKeyMonitor(isEnabled: !selection.isEmpty) { deleteSelection() })

            if selectedWords.count == 1, let word = selectedWords.first {
                WordEditorView(word: word)
                    .id(word.objectID)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if !selection.isEmpty {
                    Button { moveRequest = MoveRequest(words: selectedWords) } label: { Label("Move", systemImage: "folder") }
                        .help("Move the selected words")
                    Button {
                        let words = selectedWords
                        repository.setInReview(words, !words.allSatisfy(\.inReview))
                    } label: { Label("Review Book", systemImage: "arrow.uturn.backward.circle") }
                        .help("Add to or remove from the Review Book")
                    Button(role: .destructive) { deleteSelection() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Move the selected words to Recently Deleted")
                }
            }
        }
    }
    #else

    // MARK: iOS

    @ViewBuilder private var content: some View {
        List {
            ForEach(words) { word in
                NavigationLink(destination: WordEditorView(word: word)) {
                    WordRow(word: word, accent: word.pair?.accent ?? target.accent)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { repository.delete([word]) } label: { Label("Delete", systemImage: "trash") }
                    Button { moveRequest = MoveRequest(words: [word]) } label: { Label("Move", systemImage: "folder") }.tint(Palette.grape)
                }
                .swipeActions(edge: .leading) {
                    Button { repository.setInReview([word], !word.inReview) } label: {
                        Label(word.inReview ? "Clear review" : "Review", systemImage: "arrow.uturn.backward")
                    }
                    .tint(Palette.cherry)
                }
                .listRowBackground(Palette.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
    #endif
}

#if os(iOS)
struct WordRow: View {
    @ObservedObject var word: WordMO
    let accent: Color
    @EnvironmentObject private var speech: SpeechService

    var body: some View {
        HStack(spacing: 12) {
            ProgressRing(step: Int(word.step), inReview: word.inReview, accent: accent, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(word.termValue).font(Typeface.title(18)).foregroundColor(Palette.ink)
                    if !word.readingValue.isEmpty {
                        Text(word.readingValue).font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.55))
                    }
                    Spacer(minLength: 4)
                    Text(word.dueText)
                        .font(Typeface.label(11))
                        .foregroundColor(word.isDue ? Palette.tangerine : Palette.ink.opacity(0.45))
                }
                if let primary = word.primarySense {
                    HStack(spacing: 6) {
                        if !primary.partOfSpeech.isEmpty {
                            Text(primary.partOfSpeech).font(Typeface.label(11)).foregroundColor(accent)
                        }
                        Text(primary.translation.isEmpty ? "No meaning yet" : primary.translation)
                            .font(Typeface.body(15))
                            .foregroundColor(Palette.ink.opacity(primary.translation.isEmpty ? 0.4 : 0.85))
                            .lineLimit(1)
                        if word.senses.count > 1 {
                            Text("+\(word.senses.count - 1)").font(Typeface.label(11)).foregroundColor(Palette.ink.opacity(0.5))
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            Button { speech.speak(word) } label: {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 17, weight: .semibold)).foregroundColor(accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Play pronunciation of \(word.termValue)")
        }
        .padding(.vertical, 4)
    }
}
#endif

/// NavigationStack where available, NavigationView on macOS 12.
struct NavigationStackCompat<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(iOS)
        NavigationStack { content() }
        #else
        if #available(macOS 13.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
        }
        #endif
    }
}

#if os(macOS)
import AppKit

/// Calls `action` when ⌫ or ⌦ is pressed while the table this view sits behind has keyboard focus.
/// Text fields (the inspector, search) keep their normal Delete behaviour because they are the
/// first responder then, not the table.
struct TableDeleteKeyMonitor: NSViewRepresentable {
    var isEnabled: Bool
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.host = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        weak var host: NSView?
        var isEnabled = false
        var action: () -> Void = {}
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handles(event) else { return event }
                self.action()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handles(_ event: NSEvent) -> Bool {
            // 51 = Delete (backspace), 117 = Forward Delete. Ignore ⌘/⌥/⌃ combinations.
            guard isEnabled, event.keyCode == 51 || event.keyCode == 117,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let host, let window = host.window, event.window === window,
                  let table = window.firstResponder as? NSTableView else { return false }
            // Only the table this monitor belongs to, not the sidebar's outline view.
            let tableFrame = (table.enclosingScrollView ?? table).convert((table.enclosingScrollView ?? table).bounds, to: nil)
            let hostFrame = host.convert(host.bounds, to: nil)
            return hostFrame.contains(CGPoint(x: tableFrame.midX, y: tableFrame.midY))
        }
    }
}
#endif
