import CoreData
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var gamification: GamificationService
    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var reminders: ReminderService
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .top) {
            #if os(macOS)
            MacRootView()
            #else
            IOSRootView()
            #endif
            AchievementBanner()
        }
        .alert("Couldn't save", isPresented: Binding(get: { repository.saveError != nil },
                                                    set: { if !$0 { repository.saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(repository.saveError ?? "")
        }
        // Keeps the icon badge and the week of reminders in step with what's due.
        .onChange(of: scenePhase) { phase in
            if phase != .inactive {
                gamification.refresh()
                Task { await reminders.refresh() }
            }
        }
    }
}

/// Words due today or earlier, for tab and sidebar badges.
func dueWordsRequest() -> NSFetchRequest<WordMO> {
    Fetch.words(NSPredicate(format: "deletedAt == nil AND step > 0 AND (dueDay == nil OR dueDay <= %@)", DayKey.today))
}

/// Slides in when an achievement unlocks anywhere in the app.
private struct AchievementBanner: View {
    @EnvironmentObject private var gamification: GamificationService
    @State private var showing: AchievementDefinition?
    @State private var confetti = 0

    var body: some View {
        ZStack(alignment: .top) {
            ConfettiBurst(trigger: confetti).ignoresSafeArea()
            if let showing {
                HStack(spacing: 12) {
                    Image(systemName: showing.symbol)
                        .font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Palette.sunshine))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Achievement unlocked").font(Typeface.label(12)).foregroundColor(Palette.ink.opacity(0.6))
                        Text(showing.title).font(Typeface.title(18))
                        Text(showing.detail).font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.7))
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Palette.sunshine, lineWidth: 3))
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { withAnimation { self.showing = nil } }
            }
        }
        .onChange(of: gamification.freshlyUnlocked.count) { _ in showNext() }
    }

    private func showNext() {
        guard showing == nil, let next = gamification.freshlyUnlocked.first else { return }
        gamification.freshlyUnlocked.removeFirst()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { showing = next }
        confetti += 1
        Haptics.success()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            withAnimation(.easeOut) { showing = nil }
            try? await Task.sleep(nanoseconds: 400_000_000)
            showNext()
        }
    }
}

#if os(macOS)

// MARK: - Mac

enum SidebarItem: Hashable {
    case today, recentlyDeleted
    /// Opened from Today (no sidebar row of their own).
    case review, progress
    case recent(String)
    case pair(NSManagedObjectID)
    case category(NSManagedObjectID)
    case unfiled(NSManagedObjectID)
    case folder(NSManagedObjectID)
}

struct MacRootView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var library: LibraryState
    @State private var selection: SidebarItem? = .today

    var body: some View {
        NavigationView {
            SidebarView(selection: $selection)
                .frame(minWidth: 240)
            detail
        }
        .frame(minWidth: 1000, minHeight: 620)
    }

    private func object<T: NSManagedObject>(_ id: NSManagedObjectID, as type: T.Type) -> T? {
        guard let object = try? context.existingObject(with: id) as? T,
              (object.value(forKey: "deletedAt") as? Date) == nil else { return nil }
        return object
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .today:
            TodayView(openReviewBook: { selection = .review }, openProgress: { selection = .progress })
        case .review:
            WordListScreen(target: .review).id("review")
        case .progress:
            ProgressPage()
        case .recentlyDeleted:
            RecentlyDeletedView()
        case .recent(let key):
            if let target = library.target(for: key) { WordListScreen(target: target).id(key) } else { placeholder }
        case .pair(let id):
            if let pair = object(id, as: LanguagePairMO.self) { WordListScreen(target: .pair(pair)).id(id) } else { placeholder }
        case .category(let id):
            if let category = object(id, as: CategoryMO.self) { WordListScreen(target: .category(category)).id(id) } else { placeholder }
        case .unfiled(let id):
            if let category = object(id, as: CategoryMO.self) { WordListScreen(target: .unfiled(category)).id("unfiled-\(id)") } else { placeholder }
        case .folder(let id):
            if let folder = object(id, as: FolderMO.self) { WordListScreen(target: .folder(folder)).id(id) } else { placeholder }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        EmptyStateView(symbol: "sidebar.left", title: "Pick a table", message: "Choose a language pair, category or folder in the sidebar.")
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    @FetchRequest(fetchRequest: Fetch.pairs()) private var pairs: FetchedResults<LanguagePairMO>
    @FetchRequest(fetchRequest: Fetch.categories()) private var categories: FetchedResults<CategoryMO>
    @FetchRequest(fetchRequest: Fetch.folders()) private var folders: FetchedResults<FolderMO>
    @FetchRequest(fetchRequest: dueWordsRequest()) private var dueWords: FetchedResults<WordMO>
    /// Watched so pairs appear as soon as they get their first word.
    @FetchRequest(fetchRequest: Fetch.words(NSPredicate(format: "deletedAt == nil"))) private var allWords: FetchedResults<WordMO>
    @EnvironmentObject private var gamification: GamificationService
    @EnvironmentObject private var repository: VocabRepository
    @EnvironmentObject private var library: LibraryState
    @State private var action: ManageAction?
    @State private var folderToDelete: FolderMO?

    var body: some View {
        let _ = allWords.count
        let visiblePairs = pairs.filter(library.isVisible)
        List(selection: $selection) {
            Section {
                Label("Today", systemImage: "calendar.badge.clock")
                    .badge(dueWords.count)
                    .tag(SidebarItem.today)
            }

            let recent = library.recentTargets
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent, id: \.key) { item in
                        Label(item.target.recentTitle, systemImage: item.target.symbol)
                            .lineLimit(1)
                            .tag(SidebarItem.recent(item.key))
                    }
                }
            }

            ForEach(visiblePairs) { pair in
                Section {
                    Label("All words", systemImage: "square.stack.3d.up.fill")
                        .tag(SidebarItem.pair(pair.objectID))
                    ForEach(categories.filter { $0.pair == pair }) { category in
                        let categoryFolders = folders.filter { $0.category == category }
                        if categoryFolders.isEmpty {
                            categoryRow(category)
                        } else {
                            DisclosureGroup {
                                HStack {
                                    Label("Unfiled", systemImage: "tray")
                                    Spacer()
                                    RememberedCount(unfiledIn: category, compact: true)
                                }
                                .tag(SidebarItem.unfiled(category.objectID))
                                ForEach(categoryFolders) { folder in
                                    HStack {
                                        Label(folder.displayName, systemImage: "folder.fill")
                                        Spacer()
                                        RememberedCount(folder: folder, compact: true)
                                    }
                                    .tag(SidebarItem.folder(folder.objectID))
                                    .contextMenu {
                                        Button("Rename folder") { action = .renameFolder(folder) }
                                        Button("Delete folder…") { folderToDelete = folder }
                                    }
                                }
                            } label: {
                                categoryRow(category)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Circle().fill(pair.accent).frame(width: 9, height: 9)
                        Text(pair.title)
                        Spacer()
                        Menu {
                            Button("New category") { action = .newCategory(pair) }
                            Divider()
                            Button("Delete language pair…") { action = .deletePair(pair) }
                        } label: { Image(systemName: "plus.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }

            Section {
                Label("Recently Deleted", systemImage: "trash")
                    .tag(SidebarItem.recentlyDeleted)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                StreakFlame(count: gamification.currentStreak, lit: gamification.todayQualifies)
                Text(gamification.todayQualifies ? "Today's streak earned" : "Clear today's reviews to keep your streak")
                    .font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.6))
                    .lineLimit(2)
                Spacer()
            }
            .padding(12)
        }
        .toolbar {
            ToolbarItem {
                Button { action = .newPair } label: { Label("Add a language pair", systemImage: "plus") }
                    .help("Add a language pair")
            }
        }
        .sheet(item: $action) { ManageSheet(action: $0) }
        .confirmationDialog("Delete folder \(folderToDelete?.displayName ?? "")?",
                            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } })) {
            Button("Keep its words in Unfiled") {
                if let folder = folderToDelete { repository.delete(folder, keepWords: true) }
            }
            Button("Delete the folder and its words", role: .destructive) {
                if let folder = folderToDelete { repository.delete(folder, keepWords: false) }
            }
        } message: {
            Text("Deleted items stay in Recently Deleted for 30 days.")
        }
    }

    private func categoryRow(_ category: CategoryMO) -> some View {
        HStack {
            Label(category.displayName, systemImage: "tag.fill")
            Spacer()
            RememberedCount(category: category, compact: true)
        }
        .tag(SidebarItem.category(category.objectID))
        .contextMenu {
            Button("New folder") { action = .newFolder(category) }
            Button("Rename category") { action = .renameCategory(category) }
            Divider()
            Button("Delete category…") { action = .deleteCategory(category) }
        }
    }
}

#else

// MARK: - iPhone

struct IOSRootView: View {
    @FetchRequest(fetchRequest: dueWordsRequest()) private var dueWords: FetchedResults<WordMO>

    var body: some View {
        TabView {
            NavigationStack { TodayView() }
                .tabItem { Label("Today", systemImage: "calendar.badge.clock") }
                .badge(dueWords.count)
            NavigationStack { LibraryHomeView() }
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

struct LibraryHomeView: View {
    @FetchRequest(fetchRequest: Fetch.pairs()) private var pairs: FetchedResults<LanguagePairMO>
    /// Watched so pairs appear as soon as they get their first word.
    @FetchRequest(fetchRequest: Fetch.words(NSPredicate(format: "deletedAt == nil"))) private var words: FetchedResults<WordMO>
    @EnvironmentObject private var library: LibraryState
    @State private var action: ManageAction?

    var body: some View {
        let _ = words.count
        let visiblePairs = pairs.filter(library.isVisible)
        let recent = library.recentTargets
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent").font(Typeface.label(14)).foregroundColor(Palette.ink.opacity(0.6))
                        VStack(spacing: 0) {
                            ForEach(Array(recent.enumerated()), id: \.element.key) { index, item in
                                NavigationLink(destination: WordListScreen(target: item.target)) {
                                    RecentRow(target: item.target)
                                }
                                .buttonStyle(.plain)
                                if index < recent.count - 1 { Divider() }
                            }
                        }
                        .card(padding: 12)
                    }
                }

                ForEach(visiblePairs) { pair in
                    NavigationLink(destination: PairView(pair: pair)) { PairCard(pair: pair) }
                        .buttonStyle(.plain)
                }

                if visiblePairs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add your first word").font(Typeface.title(19)).foregroundColor(Palette.ink)
                        Text("Choose a language pair to start. Pairs you haven't added words to stay out of the way until you open them.")
                            .font(Typeface.body(14)).foregroundColor(Palette.ink.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                Button { action = .newPair } label: { Label("Add a language pair", systemImage: "plus") }
                    .buttonStyle(OutlineChunkyButtonStyle())
            }
            .padding(16)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Library")
        .sheet(item: $action) { ManageSheet(action: $0).presentationDetents([.medium, .large]) }
    }
}

private struct RecentRow: View {
    let target: WordListTarget

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: target.symbol).foregroundColor(target.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title).font(Typeface.title(16)).foregroundColor(Palette.ink).lineLimit(1)
                if let context = target.recentContext {
                    Text(context).font(Typeface.body(12)).foregroundColor(Palette.ink.opacity(0.55)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            RememberedCount(target: target, compact: true)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.ink.opacity(0.3))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct PairCard: View {
    @ObservedObject var pair: LanguagePairMO

    var body: some View {
        let wordCount = pair.liveCategories.reduce(0) { $0 + $1.liveWords.count }
        let categoryCount = pair.liveCategories.count
        return HStack(spacing: 14) {
            PairBadge(from: pair.from, to: pair.to, accent: pair.accent, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(pair.title).font(Typeface.title(19)).foregroundColor(Palette.ink)
                Text("\(wordCount) word\(wordCount == 1 ? "" : "s") · \(categoryCount) categor\(categoryCount == 1 ? "y" : "ies")")
                    .font(Typeface.body(13)).foregroundColor(Palette.ink.opacity(0.65))
            }
            Spacer(minLength: 0)   // Keeps every card full width.
            Image(systemName: "chevron.right").foregroundColor(Palette.ink.opacity(0.35))
        }
        .card()
    }
}

/// A language pair: all its words, then each category with its folders underneath.
/// Tapping a category opens its word list; the chevron shows or hides its folders.
struct PairView: View {
    @ObservedObject var pair: LanguagePairMO
    @FetchRequest(fetchRequest: Fetch.categories()) private var categories: FetchedResults<CategoryMO>
    @FetchRequest(fetchRequest: Fetch.folders()) private var folders: FetchedResults<FolderMO>
    @EnvironmentObject private var repository: VocabRepository
    @State private var action: ManageAction?
    @State private var folderToDelete: FolderMO?
    @State private var collapsed: Set<NSManagedObjectID> = []

    var body: some View {
        List {
            Section {
                NavigationLink(destination: WordListScreen(target: .pair(pair))) {
                    Label("All words in \(pair.title)", systemImage: "square.stack.3d.up.fill")
                }
            }
            Section("Categories") {
                ForEach(categories.filter { $0.pair == pair }) { category in
                    let categoryFolders = folders.filter { $0.category == category }
                    categoryRow(category, hasFolders: !categoryFolders.isEmpty)
                    if !categoryFolders.isEmpty && !collapsed.contains(category.objectID) {
                        NavigationLink(destination: WordListScreen(target: .unfiled(category))) {
                            HStack {
                                Label("Unfiled", systemImage: "tray")
                                Spacer()
                                RememberedCount(unfiledIn: category)
                            }
                        }
                        .padding(.leading, 28)
                        ForEach(categoryFolders) { folder in
                            NavigationLink(destination: WordListScreen(target: .folder(folder))) {
                                HStack {
                                    Label(folder.displayName, systemImage: "folder.fill")
                                    Spacer()
                                    RememberedCount(folder: folder)
                                }
                            }
                            .padding(.leading, 28)
                            .swipeActions {
                                Button(role: .destructive) { folderToDelete = folder } label: { Label("Delete", systemImage: "trash") }
                                Button { action = .renameFolder(folder) } label: { Label("Rename", systemImage: "pencil") }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(pair.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { action = .newCategory(pair) } label: { Label("New category", systemImage: "tag") }
                    Button(role: .destructive) { action = .deletePair(pair) } label: { Label("Delete language pair", systemImage: "trash") }
                } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .tint(pair.accent)
        .sheet(item: $action) { ManageSheet(action: $0).presentationDetents([.medium, .large]) }
        .confirmationDialog("Delete folder \(folderToDelete?.displayName ?? "")?",
                            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Keep its words in Unfiled") { if let f = folderToDelete { repository.delete(f, keepWords: true) } }
            Button("Delete the folder and its words", role: .destructive) { if let f = folderToDelete { repository.delete(f, keepWords: false) } }
        } message: {
            Text("Deleted items stay in Recently Deleted for 30 days.")
        }
    }

    private func categoryRow(_ category: CategoryMO, hasFolders: Bool) -> some View {
        HStack(spacing: 6) {
            if hasFolders {
                let isCollapsed = collapsed.contains(category.objectID)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isCollapsed { collapsed.remove(category.objectID) } else { collapsed.insert(category.objectID) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isCollapsed ? "Show folders" : "Hide folders")
            }
            NavigationLink(destination: WordListScreen(target: .category(category))) {
                HStack {
                    Label(category.displayName, systemImage: "tag.fill")
                    Spacer()
                    RememberedCount(category: category)
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) { action = .deleteCategory(category) } label: { Label("Delete", systemImage: "trash") }
            Button { action = .renameCategory(category) } label: { Label("Rename", systemImage: "pencil") }
            Button { action = .newFolder(category) } label: { Label("New folder", systemImage: "folder.badge.plus") }
                .tint(Palette.grape)
        }
        .contextMenu {
            Button { action = .newFolder(category) } label: { Label("New folder", systemImage: "folder.badge.plus") }
            Button { action = .renameCategory(category) } label: { Label("Rename category", systemImage: "pencil") }
            Button(role: .destructive) { action = .deleteCategory(category) } label: { Label("Delete category", systemImage: "trash") }
        }
    }
}
#endif

// MARK: - Remembered count

/// "3 of 10 remembered" for one list (category, folder, Unfiled, or any list for Recent). It runs its own fetch, so the number
/// updates as soon as a quiz, edit or delete changes a word.
struct RememberedCount: View {
    @FetchRequest private var words: FetchedResults<WordMO>
    private let compact: Bool

    init(category: CategoryMO, compact: Bool = false) {
        self.init(NSPredicate(format: "deletedAt == nil AND category == %@", category), compact: compact)
    }

    init(folder: FolderMO, compact: Bool = false) {
        self.init(NSPredicate(format: "deletedAt == nil AND folder == %@", folder), compact: compact)
    }

    init(unfiledIn category: CategoryMO, compact: Bool = false) {
        self.init(NSPredicate(format: "deletedAt == nil AND category == %@ AND folder == nil", category), compact: compact)
    }

    /// Any list, for the Recent rows.
    init(target: WordListTarget, compact: Bool = false) {
        self.init(VocabRepository.predicate(for: WordFilter(scope: target.scope)), compact: compact)
    }

    private init(_ predicate: NSPredicate, compact: Bool) {
        _words = FetchRequest(fetchRequest: Fetch.words(predicate))
        self.compact = compact
    }

    var body: some View {
        let remembered = words.filter(\.isRemembered).count
        let full = "\(remembered) of \(words.count) remembered"
        // The Mac sidebar is narrow, so it shows "3/10" with the full wording as a tooltip.
        Text(compact ? "\(remembered)/\(words.count)" : full)
            .font(Typeface.body(compact ? 11 : 13))
            .monospacedDigit()
            .foregroundColor(Palette.ink.opacity(0.55))
            .help(full)
            .accessibilityLabel(full)
    }
}
