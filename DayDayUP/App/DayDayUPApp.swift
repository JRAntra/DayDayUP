import CoreData
import SwiftUI

@main
struct DayDayUPApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .dayDayUpEnvironment(app)
                .appleTranslationHost()
                .task { app.onLaunch() }
        }
        #if os(macOS)
        .commands {
            SidebarCommands()
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .dayDayUpEnvironment(app)
                .frame(minWidth: 560, minHeight: 620)
        }
        #endif
    }
}

/// Owns the long-lived services. Views reach them through environment objects.
@MainActor
final class AppModel: ObservableObject {
    let persistence: PersistenceController
    let repository: VocabRepository
    let dictionaries: DictionaryManager
    let sourceSettings: LookupSourceSettings
    let lookup: LookupService
    let speech: SpeechService
    let gamification: GamificationService
    let planner: TodayPlanner
    let reminders: ReminderService
    let library: LibraryState
    /// Local-only today. Swap for `ICloudSyncService` once CLOUD_SYNC_TODO.md is done.
    let sync: SyncService

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
        let context = persistence.container.viewContext
        repository = VocabRepository(context: context)
        // Before anything reads progress: old 3-ring progress moves onto the review ladder once.
        repository.mapLegacyProgressIfNeeded()
        dictionaries = DictionaryManager()
        sourceSettings = LookupSourceSettings()
        lookup = LookupService(dictionaries: dictionaries, settings: sourceSettings)
        speech = SpeechService()
        gamification = GamificationService(context: context)
        planner = TodayPlanner(repository: repository)
        reminders = ReminderService(repository: repository)
        library = LibraryState(repository: repository)
        sync = LocalOnlySyncService()
    }

    private var launched = false

    func onLaunch() {
        guard !launched else { return }
        launched = true
        repository.purgeExpired()
        if repository.pairs().isEmpty {
            // Start with the three pairs agreed for DayDayUP so the library is never empty.
            for (from, to) in [(AppLanguage.english, AppLanguage.chinese), (.chinese, .english), (.japanese, .chinese)] {
                if let pair = try? repository.createPair(from: from, to: to) {
                    _ = try? repository.createCategory(named: "General", in: pair)
                }
            }
        }
        gamification.refresh()
        Task { await reminders.refresh() }
        Task { await sync.start() }
    }
}

extension View {
    func dayDayUpEnvironment(_ app: AppModel) -> some View {
        self
            .environment(\.managedObjectContext, app.persistence.container.viewContext)
            .environmentObject(app)
            .environmentObject(app.repository)
            .environmentObject(app.dictionaries)
            .environmentObject(app.sourceSettings)
            .environmentObject(app.lookup)
            .environmentObject(app.speech)
            .environmentObject(app.gamification)
            .environmentObject(app.planner)
            .environmentObject(app.reminders)
            .environmentObject(app.library)
            .tint(Palette.grape)
    }
}

// MARK: - Fetch requests

enum Fetch {
    static func pairs() -> NSFetchRequest<LanguagePairMO> {
        let r = NSFetchRequest<LanguagePairMO>(entityName: "LanguagePairMO")
        r.predicate = NSPredicate(format: "deletedAt == nil")
        r.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true), NSSortDescriptor(key: "createdAt", ascending: true)]
        return r
    }

    static func categories() -> NSFetchRequest<CategoryMO> {
        let r = NSFetchRequest<CategoryMO>(entityName: "CategoryMO")
        r.predicate = NSPredicate(format: "deletedAt == nil")
        r.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true), NSSortDescriptor(key: "name", ascending: true)]
        return r
    }

    static func folders() -> NSFetchRequest<FolderMO> {
        let r = NSFetchRequest<FolderMO>(entityName: "FolderMO")
        r.predicate = NSPredicate(format: "deletedAt == nil")
        r.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true), NSSortDescriptor(key: "name", ascending: true)]
        return r
    }

    static func words(_ predicate: NSPredicate) -> NSFetchRequest<WordMO> {
        let r = NSFetchRequest<WordMO>(entityName: "WordMO")
        r.predicate = predicate
        r.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return r
    }

    static func reviewWords() -> NSFetchRequest<WordMO> {
        words(VocabRepository.reviewableOnly(NSPredicate(format: "deletedAt == nil AND inReview == YES")))
    }
}
