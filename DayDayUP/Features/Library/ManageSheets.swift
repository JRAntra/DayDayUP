import SwiftUI

/// Everything the library can ask the user to name, create or confirm.
enum ManageAction: Identifiable {
    case newPair
    case newCategory(LanguagePairMO)
    case newFolder(CategoryMO)
    case renameCategory(CategoryMO)
    case renameFolder(FolderMO)
    case deleteCategory(CategoryMO)
    case deletePair(LanguagePairMO)

    var id: String {
        switch self {
        case .newPair: return "newPair"
        case .newCategory(let p): return "newCategory-\(p.objectID)"
        case .newFolder(let c): return "newFolder-\(c.objectID)"
        case .renameCategory(let c): return "renameCategory-\(c.objectID)"
        case .renameFolder(let f): return "renameFolder-\(f.objectID)"
        case .deleteCategory(let c): return "deleteCategory-\(c.objectID)"
        case .deletePair(let p): return "deletePair-\(p.objectID)"
        }
    }
}

struct ManageSheet: View {
    let action: ManageAction
    @EnvironmentObject private var repository: VocabRepository
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch action {
            case .newPair:
                // Scrolls, so the hidden-pair list and the form both fit in a half-height sheet.
                ScrollView { NewPairForm().padding(.vertical, 4) }
            case .newCategory(let pair):
                NameForm(title: "New category in \(pair.title)", placeholder: "Category name, e.g. Medicine",
                         suggestions: repository.allCategoryNames().filter { name in
                             !pair.liveCategories.contains { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
                         },
                         actionTitle: "Create category") { name in
                    _ = try repository.createCategory(named: name, in: pair)
                }
            case .newFolder(let category):
                NameForm(title: "New folder in \(category.displayName)", placeholder: "Folder name, e.g. Chapter 3",
                         actionTitle: "Create folder") { name in
                    _ = try repository.createFolder(named: name, in: category)
                }
            case .renameCategory(let category):
                NameForm(title: "Rename category", placeholder: "Category name", initial: category.displayName,
                         actionTitle: "Rename") { name in repository.rename(category, to: name) }
            case .renameFolder(let folder):
                NameForm(title: "Rename folder", placeholder: "Folder name", initial: folder.displayName,
                         actionTitle: "Rename") { name in repository.rename(folder, to: name) }
            case .deleteCategory(let category):
                TypedDeleteForm(name: category.displayName,
                                detail: "Deletes the category, its \(category.liveFolders.count) folders and \(category.liveWords.count) words.") {
                    repository.delete(category)
                }
            case .deletePair(let pair):
                TypedDeleteForm(name: pair.title,
                                detail: "Deletes every category, folder and word in this language pair.") {
                    repository.delete(pair)
                }
            }
        }
        .padding(24)
        .macSheetSize(minWidth: 420)
        .background(Palette.background.ignoresSafeArea())
    }
}

/// Opens a language pair that's hidden because it has no words yet, or creates a new one.
private struct NewPairForm: View {
    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var library: LibraryState
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(fetchRequest: Fetch.pairs()) private var pairs: FetchedResults<LanguagePairMO>
    @State private var from: AppLanguage = .english
    @State private var to: AppLanguage = .chinese
    @State private var error: String?

    var body: some View {
        let hidden = pairs.filter { !library.isVisible($0) }
        VStack(alignment: .leading, spacing: 16) {
            if !hidden.isEmpty {
                Text("Start a language pair").font(Typeface.title(24))
                Text("These pairs have no words yet, so they're hidden. Open one to add its first word.")
                    .font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(hidden) { pair in
                    Button {
                        library.reveal(pair)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PairBadge(from: pair.from, to: pair.to, accent: pair.accent, size: 36)
                            Text(pair.title).font(Typeface.title(16)).foregroundColor(Palette.ink)
                            Spacer()
                            Text("Open").font(Typeface.label(14)).foregroundColor(pair.accent)
                        }
                        .card(padding: 12)
                    }
                    .buttonStyle(.plain)
                }
                Divider().padding(.vertical, 4)
            }
            Text("New language pair").font(Typeface.title(hidden.isEmpty ? 24 : 18))
            Picker("Translate from", selection: $from) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Translate to", selection: $to) {
                ForEach(AppLanguage.allCases.filter { $0 != from }) { Text($0.displayName).tag($0) }
            }
            .onChange(of: from) { newValue in if to == newValue { to = AppLanguage.allCases.first { $0 != newValue } ?? .english } }
            if to == .chinese || from == .chinese {
                Text("Chinese uses Simplified characters and mainland Mandarin pronunciation.")
                    .font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.6))
            }
            if let error { Text(error).font(Typeface.body(14)).foregroundColor(Palette.cherry) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(OutlineChunkyButtonStyle())
                Button("Create pair") {
                    do {
                        let pair = try repository.createPair(from: from, to: to)
                        _ = try? repository.createCategory(named: "General", in: pair)
                        library.reveal(pair)   // a pair you just made shows even before it has words
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(ChunkyButtonStyle())
            }
        }
    }
}

private struct NameForm: View {
    let title: String
    let placeholder: String
    var initial = ""
    var suggestions: [String] = []
    let actionTitle: String
    let perform: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?

    init(title: String, placeholder: String, initial: String = "", suggestions: [String] = [],
         actionTitle: String, perform: @escaping (String) throws -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.initial = initial
        self.suggestions = suggestions
        self.actionTitle = actionTitle
        self.perform = perform
        _name = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Typeface.title(22))
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .font(Typeface.body(16))
                .onSubmit(commit)
            if !suggestions.isEmpty {
                Text("Reuse a name from another pair").font(Typeface.label(13)).foregroundColor(Palette.ink.opacity(0.6))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { name = suggestion }
                                .buttonStyle(OutlineChunkyButtonStyle())
                        }
                    }
                }
            }
            if let error { Text(error).font(Typeface.body(14)).foregroundColor(Palette.cherry) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(OutlineChunkyButtonStyle())
                Button(actionTitle, action: commit).buttonStyle(ChunkyButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func commit() {
        do {
            try perform(name)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Deleting a category or a whole pair needs its name typed, because it removes so much at once.
private struct TypedDeleteForm: View {
    let name: String
    let detail: String
    let perform: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete \(name)?").font(Typeface.title(22))
            Text(detail + " Everything stays in Recently Deleted for 30 days.")
                .font(Typeface.body(15)).foregroundColor(Palette.ink.opacity(0.75))
            Text("Type \(name) to confirm.").font(Typeface.label(14))
            TextField(name, text: $typed).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(OutlineChunkyButtonStyle())
                Button("Delete") { perform(); dismiss() }
                    .buttonStyle(ChunkyButtonStyle(color: Palette.cherry))
                    .disabled(typed.trimmingCharacters(in: .whitespaces) != name)
            }
        }
    }
}

// MARK: - Move

/// Moves words to another category or folder of the same language pair.
struct MoveWordsSheet: View {
    let words: [WordMO]
    @EnvironmentObject private var repository: VocabRepository
    @Environment(\.dismiss) private var dismiss
    @State private var categoryID: UUID?
    @State private var folderID: UUID?

    private var pair: LanguagePairMO? { words.first?.pair }
    private var category: CategoryMO? { pair?.liveCategories.first { $0.id == categoryID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(words.count == 1 ? "Move \(words[0].termValue)" : "Move \(words.count) words").font(Typeface.title(22))
            Text("Progress and Review Book status move with each word. Words already in the destination are merged.")
                .font(Typeface.body(14)).foregroundColor(Palette.ink.opacity(0.7))
            Picker("Category", selection: $categoryID) {
                ForEach(pair?.liveCategories ?? []) { Text($0.displayName).tag($0.id) }
            }
            .onChange(of: categoryID) { _ in folderID = nil }
            if let category {
                Picker("Folder", selection: $folderID) {
                    Text("Unfiled").tag(UUID?.none)
                    ForEach(category.liveFolders) { Text($0.displayName).tag($0.id) }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(OutlineChunkyButtonStyle())
                Button("Move") {
                    guard let category else { return }
                    repository.move(words, to: category, folder: category.liveFolders.first { $0.id == folderID })
                    dismiss()
                }
                .buttonStyle(ChunkyButtonStyle(color: pair?.accent ?? Palette.grape))
                .disabled(category == nil)
            }
        }
        .padding(24)
        .macSheetSize(minWidth: 420)
        .background(Palette.background.ignoresSafeArea())
        .onAppear { categoryID = words.first?.category?.id }
    }
}

// MARK: - CSV import

struct CSVImportSheet: View {
    let text: String
    let category: CategoryMO
    let completion: (CSVImportSummary) -> Void

    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var gamification: GamificationService
    @Environment(\.dismiss) private var dismiss
    @State private var rule: DuplicateRule = .merge

    private var rowCount: Int { max(0, CSVService.parse(text).count - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import into \(category.displayName)").font(Typeface.title(22))
            Text("\(rowCount) rows found. Missing folders are created automatically, and new words start at 0 of 3.")
                .font(Typeface.body(14)).foregroundColor(Palette.ink.opacity(0.7))
            Text("When a word already exists").font(Typeface.label(14))
            ForEach(DuplicateRule.allCases) { option in
                Button { rule = option } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: rule == option ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(Palette.grape)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.rawValue).font(Typeface.title(15))
                            Text(option.detail).font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.65))
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(OutlineChunkyButtonStyle())
                Button("Import") {
                    let summary = CSVService.importCSV(text, into: category, rule: rule, repository: repository)
                    gamification.recordWordsAdded(summary.added)
                    completion(summary)
                    dismiss()
                }
                .buttonStyle(ChunkyButtonStyle(color: category.pair?.accent ?? Palette.grape))
            }
        }
        .padding(24)
        .macSheetSize(minWidth: 460)
        .background(Palette.background.ignoresSafeArea())
    }
}
