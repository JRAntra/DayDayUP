import CoreData
import SwiftUI

// MARK: - Persistence controller

final class PersistenceController {
    static let shared = PersistenceController()
    static let preview = PersistenceController(inMemory: true)

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        // TO BE IMPLEMENTED (iCloud): swap for NSPersistentCloudKitContainer and set
        // `cloudKitContainerOptions` on the store description. See CLOUD_SYNC_TODO.md.
        // The store keeps its original name (from when the app was called VocaQuest) so existing data opens.
        container = NSPersistentContainer(name: "VocaQuest", managedObjectModel: ManagedModel.shared)
        if let description = container.persistentStoreDescriptions.first {
            if inMemory {
                description.url = URL(fileURLWithPath: "/dev/null")
            } else if let url = description.url {
                do {
                    try Self.migrateIfNeeded(storeAt: url)
                } catch {
                    fatalError("Could not upgrade the DayDayUP store: \(error)")
                }
            }
            // History tracking is required by CloudKit sync; enabling it now avoids a migration later.
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }
        container.loadPersistentStores { _, error in
            if let error { fatalError("Could not open the DayDayUP store: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Set after the store is upgraded from model version 1, so the old 3-ring progress gets mapped onto
    /// the review ladder once the app has a context (VocabRepository.mapLegacyProgressIfNeeded).
    static let legacyMappingKey = "schedule.needsLegacyMapping"

    private static let storeOptions: [String: Any] = [NSPersistentHistoryTrackingKey: true as NSNumber]

    /// The model is built in code, so Core Data can't find the old version on its own to migrate a store.
    /// This keeps the old versions around, and upgrades an older store in place before it's opened. Before the
    /// review-schedule upgrade (from version 1), a copy of the old store is kept next to the Safety Backups.
    static func migrateIfNeeded(storeAt url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: nil)
        let current = ManagedModel.shared
        if current.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) { return }
        // Anything that isn't an older version is left for loadPersistentStores to report.
        guard let sourceVersion = (1..<ManagedModel.currentVersion).first(where: {
            ManagedModel.build(version: $0).isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        }) else { return }
        let source = ManagedModel.build(version: sourceVersion)

        if sourceVersion == 1 { try keepCopy(of: url) }
        // Every version only adds attributes, so one inferred step reaches the current model.
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: source, destinationModel: current)
        let manager = NSMigrationManager(sourceModel: source, destinationModel: current)
        let temp = url.deletingLastPathComponent().appendingPathComponent("VocaQuest-upgrading.sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: current)
        removeStoreFiles(at: temp)   // left over from an interrupted upgrade
        try manager.migrateStore(from: url, sourceType: NSSQLiteStoreType, options: storeOptions, with: mapping,
                                 toDestinationURL: temp, destinationType: NSSQLiteStoreType, destinationOptions: storeOptions)
        try coordinator.replacePersistentStore(at: url, destinationOptions: storeOptions,
                                               withPersistentStoreFrom: temp, sourceOptions: storeOptions, ofType: NSSQLiteStoreType)
        removeStoreFiles(at: temp)
        if sourceVersion == 1 { UserDefaults.standard.set(true, forKey: legacyMappingKey) }
    }

    /// Deletes a SQLite store and its side files. (destroyPersistentStore leaves an empty file behind,
    /// which makes the next migrateStore refuse to write there.)
    private static func removeStoreFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Copies the store files (the database and its write-ahead log) before an upgrade.
    private static func keepCopy(of url: URL) throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("VocaQuest/Safety Backups/Store before review schedule", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            let target = folder.appendingPathComponent(source.lastPathComponent)
            guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { continue }
            try FileManager.default.copyItem(at: source, to: target)
        }
    }
}

// MARK: - Errors and value types

enum RepositoryError: LocalizedError {
    case sameLanguage
    case pairExists
    case emptyName

    var errorDescription: String? {
        switch self {
        case .sameLanguage: return "Choose a target language that's different from the source language."
        case .pairExists: return "You already have this language pair."
        case .emptyName: return "Enter a name."
        }
    }
}

struct DeletedBatch: Identifiable, Hashable {
    let id: UUID
    let deletedAt: Date
    let title: String
    let detail: String

    var expiresAt: Date { Calendar.current.date(byAdding: .day, value: VocabRepository.retentionDays, to: deletedAt) ?? deletedAt }
}

// MARK: - Repository

/// Every read and write of vocabulary data goes through here, so the rules agreed for the app
/// (duplicates, soft deletes, moves, progress) live in one place.
@MainActor
final class VocabRepository: ObservableObject {
    nonisolated static let retentionDays = 30

    let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Set when a save fails, so the UI can say so instead of silently losing the change.
    @Published var saveError: String?

    func save() {
        guard context.hasChanges else { return }
        do { try context.save() } catch {
            context.rollback()
            saveError = "Your last change couldn't be saved and was undone. \(error.localizedDescription)"
            print("DayDayUP save failed: \(error)")
        }
    }

    // MARK: Fetching

    private func fetch<T: NSManagedObject>(_ type: T.Type, _ predicate: NSPredicate? = nil,
                                           sort: [NSSortDescriptor] = []) -> [T] {
        let request = NSFetchRequest<T>(entityName: String(describing: type))
        request.predicate = predicate
        request.sortDescriptors = sort
        return (try? context.fetch(request)) ?? []
    }

    private static let live = NSPredicate(format: "deletedAt == nil")

    func pairs() -> [LanguagePairMO] {
        fetch(LanguagePairMO.self, Self.live, sort: [NSSortDescriptor(key: "sortIndex", ascending: true),
                                                     NSSortDescriptor(key: "createdAt", ascending: true)])
    }

    func pair(id: UUID?) -> LanguagePairMO? {
        guard let id else { return nil }
        return fetch(LanguagePairMO.self, NSPredicate(format: "id == %@", id as CVarArg)).first
    }

    func category(id: UUID?) -> CategoryMO? {
        guard let id else { return nil }
        return fetch(CategoryMO.self, NSPredicate(format: "id == %@", id as CVarArg)).first
    }

    func folder(id: UUID?) -> FolderMO? {
        guard let id else { return nil }
        return fetch(FolderMO.self, NSPredicate(format: "id == %@", id as CVarArg)).first
    }

    /// Category names already used anywhere, offered for reuse in other pairs.
    func allCategoryNames() -> [String] {
        let names = fetch(CategoryMO.self, Self.live).compactMap(\.name).filter { !$0.isEmpty }
        return Array(Set(names)).sorted()
    }

    nonisolated static func predicate(for filter: WordFilter) -> NSPredicate {
        var parts: [NSPredicate] = [NSPredicate(format: "deletedAt == nil")]
        let scope = filter.scope
        if let folderID = scope.folderID {
            parts.append(NSPredicate(format: "folder.id == %@", folderID as CVarArg))
        } else if let categoryID = scope.categoryID {
            parts.append(NSPredicate(format: "category.id == %@", categoryID as CVarArg))
            if scope.unfiledOnly { parts.append(NSPredicate(format: "folder == nil")) }
        } else if let pairID = scope.pairID {
            parts.append(NSPredicate(format: "category.pair.id == %@", pairID as CVarArg))
        }
        // Words inside a deleted folder/category/pair are soft-deleted with it, so `deletedAt` is enough.
        if scope.reviewOnly { parts.append(NSPredicate(format: "inReview == YES")) }

        switch filter.remembered {
        case .all: break
        case .inReview:
            parts.append(NSPredicate(format: "inReview == YES"))
        case .dueToday:
            parts.append(NSPredicate(format: "step > 0 AND (dueDay == nil OR dueDay <= %@)", DayKey.today))
        case .remembered:
            parts.append(NSPredicate(format: "step >= %d AND inReview == NO", ReviewSchedule.rememberedStep))
        case .notRemembered:
            parts.append(NSPredicate(format: "step < %d OR inReview == YES", ReviewSchedule.rememberedStep))
        }

        if filter.useDateRange {
            let start = Calendar.current.startOfDay(for: min(filter.dateFrom, filter.dateTo))
            let endDay = Calendar.current.startOfDay(for: max(filter.dateFrom, filter.dateTo))
            let end = Calendar.current.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            parts.append(NSPredicate(format: "createdAt >= %@ AND createdAt < %@", start as NSDate, end as NSDate))
        }

        let search = filter.searchText.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            parts.append(NSPredicate(format: "term CONTAINS[cd] %@ OR sensesJSON CONTAINS[cd] %@ OR reading CONTAINS[cd] %@",
                                     search, search, search))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    func words(matching filter: WordFilter) -> [WordMO] {
        fetch(WordMO.self, Self.predicate(for: filter), sort: [NSSortDescriptor(key: "createdAt", ascending: false)])
    }

    func liveWords(in category: CategoryMO) -> [WordMO] {
        fetch(WordMO.self, NSPredicate(format: "deletedAt == nil AND category == %@", category))
    }

    func countWords(_ predicate: NSPredicate) -> Int {
        let request = NSFetchRequest<WordMO>(entityName: "WordMO")
        request.predicate = predicate
        return (try? context.count(for: request)) ?? 0
    }

    // MARK: Creating and renaming

    @discardableResult
    func createPair(from: AppLanguage, to: AppLanguage) throws -> LanguagePairMO {
        guard from != to else { throw RepositoryError.sameLanguage }
        let existing = pairs()
        guard !existing.contains(where: { $0.from == from && $0.to == to }) else { throw RepositoryError.pairExists }
        let pair = LanguagePairMO(context: context)
        pair.stampNew()
        pair.fromCode = from.rawValue
        pair.toCode = to.rawValue
        pair.script = ChineseScript.simplified.rawValue
        pair.accentHex = PairPalette.next(after: existing.compactMap(\.accentHex))
        pair.sortIndex = Int64(existing.count)
        save()
        return pair
    }

    @discardableResult
    func createCategory(named name: String, in pair: LanguagePairMO) throws -> CategoryMO {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw RepositoryError.emptyName }
        if let match = pair.liveCategories.first(where: { $0.displayName.caseInsensitiveCompare(clean) == .orderedSame }) {
            return match
        }
        let category = CategoryMO(context: context)
        category.stampNew()
        category.name = clean
        category.sortIndex = Int64(pair.liveCategories.count)
        category.pair = pair
        save()
        return category
    }

    @discardableResult
    func createFolder(named name: String, in category: CategoryMO) throws -> FolderMO {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw RepositoryError.emptyName }
        if let match = category.liveFolders.first(where: { $0.displayName.caseInsensitiveCompare(clean) == .orderedSame }) {
            return match
        }
        let folder = FolderMO(context: context)
        folder.stampNew()
        folder.name = clean
        folder.sortIndex = Int64(category.liveFolders.count)
        folder.category = category
        save()
        return folder
    }

    func rename(_ category: CategoryMO, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        category.name = clean
        category.touch()
        save()
    }

    func rename(_ folder: FolderMO, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        folder.name = clean
        folder.touch()
        save()
    }

    // MARK: Words

    func termKey(_ term: String, in category: CategoryMO) -> String {
        (category.pair?.from ?? .english).normalize(term)
    }

    /// The same word already saved in this category (Question 26: open it instead of adding a row).
    func existingWord(term: String, in category: CategoryMO) -> WordMO? {
        let key = termKey(term, in: category)
        return fetch(WordMO.self, NSPredicate(format: "deletedAt == nil AND category == %@ AND termKey == %@", category, key)).first
    }

    /// Other categories of the same pair that also contain this word, for the "also in" label.
    func otherCategories(for word: WordMO) -> [CategoryMO] {
        guard let category = word.category, let pair = category.pair, let key = word.termKey else { return [] }
        let matches = fetch(WordMO.self, NSPredicate(format: "deletedAt == nil AND termKey == %@ AND category.pair == %@ AND category != %@",
                                                     key, pair, category))
        var seen = Set<NSManagedObjectID>()
        return matches.compactMap(\.category).filter { seen.insert($0.objectID).inserted }
    }

    @discardableResult
    func addWord(term: String, reading: String, senses: [Sense], category: CategoryMO, folder: FolderMO?) -> WordMO {
        let word = WordMO(context: context)
        word.stampNew()
        word.term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        word.termKey = termKey(term, in: category)
        word.reading = reading
        word.sensesJSON = SenseCodec.encode(senses)
        word.category = category
        word.folder = folder
        save()
        return word
    }

    /// Appends senses that aren't already present, keeping the primary sense first.
    func mergeSenses(_ incoming: [Sense], into word: WordMO) {
        var current = word.senses
        let keys = Set(current.map(\.matchKey))
        current.append(contentsOf: incoming.filter { !keys.contains($0.matchKey) && !$0.translation.isEmpty })
        word.senses = current
        save()
    }

    @discardableResult
    func recordAnswer(for word: WordMO, correct: Bool) -> ReviewSchedule.Outcome {
        let result = ReviewSchedule.apply(correct: correct, to: word.schedule)
        word.schedule = result.state
        if !correct { word.timesMissed += 1 }
        if result.outcome.becameRemembered { word.rememberedAt = Date() }
        if result.outcome.lostRemembered { word.rememberedAt = nil }
        word.touch()
        if let pairID = word.pair?.id { countAnswer(correct: correct, pairID: pairID) }
        save()
        return result.outcome
    }

    /// Today's activity record, created on first use.
    func activity(for day: String = DayKey.today) -> DailyActivityMO {
        if let existing = fetch(DailyActivityMO.self, NSPredicate(format: "dayKey == %@ AND deletedAt == nil", day)).first {
            return existing
        }
        let record = DailyActivityMO(context: context)
        record.stampNew()
        record.dayKey = day
        return record
    }

    /// Adds one answer to today's per-pair counts, for the Progress chart.
    private func countAnswer(correct: Bool, pairID: UUID) {
        let record = activity()
        var counts = record.answerCounts
        var pair = counts[pairID.uuidString] ?? [0, 0]
        if pair.count < 2 { pair = [0, 0] }
        pair[correct ? 0 : 1] += 1
        counts[pairID.uuidString] = pair
        record.answerCounts = counts
        record.touch()
    }

    /// Activity records from `fromDay` on, keyed by day.
    func activities(from fromDay: String) -> [String: DailyActivityMO] {
        var byDay: [String: DailyActivityMO] = [:]
        for record in fetch(DailyActivityMO.self, NSPredicate(format: "deletedAt == nil AND dayKey >= %@", fromDay)) {
            if let day = record.dayKey { byDay[day] = record }
        }
        return byDay
    }

    // MARK: Review schedule

    /// Live words in a pair, for Today and the reminder.
    func liveWords(in pair: LanguagePairMO) -> [WordMO] {
        fetch(WordMO.self, NSPredicate(format: "deletedAt == nil AND category.pair == %@ AND category.deletedAt == nil", pair))
    }

    /// Words due on `day` or earlier, across every pair.
    func dueCount(on day: String = DayKey.today) -> Int {
        countWords(NSPredicate(format: "deletedAt == nil AND step > 0 AND (dueDay == nil OR dueDay <= %@)", day))
    }

    /// Maps progress kept under the old 3-ring rule onto the review ladder. Runs once, after the store
    /// is upgraded from model version 1; restoring an old backup maps its words directly.
    func mapLegacyProgressIfNeeded() {
        guard UserDefaults.standard.bool(forKey: PersistenceController.legacyMappingKey) else { return }
        let words = fetch(WordMO.self, NSPredicate(format: "step == 0"), sort: [NSSortDescriptor(key: "createdAt", ascending: true)])
        var mapped = 0
        for word in words {
            guard let state = ReviewSchedule.fromLegacy(ring: Int(word.ring), inReview: word.inReview,
                                                        lastCorrectDay: word.lastCorrectDay, spreadIndex: mapped) else { continue }
            mapped += 1
            word.schedule = state
            if !state.isRemembered { word.rememberedAt = nil }
        }
        for day in fetch(DailyActivityMO.self, nil) where day.earnedUnderOldRule {
            day.streakEarned = true
        }
        do {
            try context.save()
            UserDefaults.standard.set(false, forKey: PersistenceController.legacyMappingKey)
        } catch {
            // Left set, so the mapping is tried again on the next launch.
            context.rollback()
            print("DayDayUP legacy progress mapping failed: \(error)")
        }
    }

    func setInReview(_ words: [WordMO], _ value: Bool) {
        for word in words {
            word.inReview = value
            word.touch()
        }
        save()
    }

    // MARK: Moving

    /// Moves words within the same language pair. Duplicates in the destination merge:
    /// senses are combined, the further review step is kept, and Review Book status carries over.
    func move(_ words: [WordMO], to category: CategoryMO, folder: FolderMO?) {
        for word in words {
            guard word.category?.pair == category.pair else { continue }
            if let existing = existingWord(term: word.termValue, in: category), existing != word {
                var senses = existing.senses
                let keys = Set(senses.map(\.matchKey))
                senses.append(contentsOf: word.senses.filter { !keys.contains($0.matchKey) })
                existing.senses = senses
                if word.step > existing.step {
                    let inReview = existing.inReview
                    existing.schedule = word.schedule
                    existing.inReview = inReview
                    existing.rememberedAt = word.rememberedAt
                }
                existing.inReview = existing.inReview || word.inReview
                existing.timesMissed += word.timesMissed
                if let folder { existing.folder = folder }
                if (existing.notes ?? "").isEmpty { existing.notes = word.notes }
                if (existing.example ?? "").isEmpty { existing.example = word.example }
                existing.touch()
                context.delete(word)
            } else {
                word.category = category
                word.folder = folder
                word.touch()
            }
        }
        save()
    }

    // MARK: Deleting (soft, restorable for 30 days)

    private func softDelete(_ records: [SyncRecord]) {
        let batch = UUID()
        let now = Date()
        for record in records where record.deletedAt == nil {
            record.deletedAt = now
            record.deletionBatch = batch
            record.touch()
        }
        save()
    }

    func delete(_ words: [WordMO]) { softDelete(words.map { $0 as SyncRecord }) }

    func delete(_ folder: FolderMO, keepWords: Bool) {
        if keepWords {
            folder.liveWords.forEach { $0.folder = nil; $0.touch() }
            softDelete([folder])
        } else {
            softDelete([folder as SyncRecord] + folder.liveWords.map { $0 as SyncRecord })
        }
    }

    func delete(_ category: CategoryMO) {
        softDelete([category as SyncRecord]
                   + category.liveFolders.map { $0 as SyncRecord }
                   + category.liveWords.map { $0 as SyncRecord })
    }

    func delete(_ pair: LanguagePairMO) {
        var records: [SyncRecord] = [pair]
        for category in pair.liveCategories {
            records.append(category)
            records.append(contentsOf: category.liveFolders.map { $0 as SyncRecord })
            records.append(contentsOf: category.liveWords.map { $0 as SyncRecord })
        }
        softDelete(records)
    }

    private func records(inBatch batch: UUID) -> [SyncRecord] {
        let p = NSPredicate(format: "deletionBatch == %@", batch as CVarArg)
        var all: [SyncRecord] = fetch(LanguagePairMO.self, p).map { $0 as SyncRecord }
        all += fetch(CategoryMO.self, p).map { $0 as SyncRecord }
        all += fetch(FolderMO.self, p).map { $0 as SyncRecord }
        all += fetch(WordMO.self, p).map { $0 as SyncRecord }
        return all
    }

    func deletedBatches() -> [DeletedBatch] {
        let p = NSPredicate(format: "deletedAt != nil AND deletionBatch != nil")
        let pairs = fetch(LanguagePairMO.self, p)
        let categories = fetch(CategoryMO.self, p)
        let folders = fetch(FolderMO.self, p)
        let words = fetch(WordMO.self, p)

        var ids = Set<UUID>()
        pairs.forEach { if let b = $0.deletionBatch { ids.insert(b) } }
        categories.forEach { if let b = $0.deletionBatch { ids.insert(b) } }
        folders.forEach { if let b = $0.deletionBatch { ids.insert(b) } }
        words.forEach { if let b = $0.deletionBatch { ids.insert(b) } }

        return ids.compactMap { batch -> DeletedBatch? in
            let bp = pairs.filter { $0.deletionBatch == batch }
            let bc = categories.filter { $0.deletionBatch == batch }
            let bf = folders.filter { $0.deletionBatch == batch }
            let bw = words.filter { $0.deletionBatch == batch }
            guard let date = (bp.first?.deletedAt ?? bc.first?.deletedAt ?? bf.first?.deletedAt ?? bw.first?.deletedAt) else { return nil }
            let wordCount = bw.count == 1 ? "1 word" : "\(bw.count) words"
            let title: String
            let detail: String
            if let pair = bp.first {
                title = "Language pair: \(pair.title)"
                detail = "\(bc.count) categories, \(wordCount)"
            } else if let category = bc.first {
                title = "Category: \(category.displayName)"
                detail = "\(bf.count) folders, \(wordCount)"
            } else if let folder = bf.first {
                title = "Folder: \(folder.displayName)"
                detail = bw.isEmpty ? "Words were kept in Unfiled" : wordCount
            } else if bw.count == 1, let word = bw.first {
                title = word.termValue
                detail = word.translationSummary
            } else {
                title = wordCount
                detail = bw.prefix(4).map(\.termValue).joined(separator: ", ")
            }
            return DeletedBatch(id: batch, deletedAt: date, title: title, detail: detail)
        }
        .sorted { $0.deletedAt > $1.deletedAt }
    }

    func restore(_ batch: DeletedBatch) {
        for record in records(inBatch: batch.id) {
            record.deletedAt = nil
            record.deletionBatch = nil
            record.touch()
            reviveAncestors(of: record)
        }
        save()
    }

    /// A restored word whose category was deleted separately brings the category back too.
    private func reviveAncestors(of record: SyncRecord) {
        var parents: [SyncRecord] = []
        if let word = record as? WordMO {
            if let folder = word.folder { parents.append(folder) }
            if let category = word.category { parents.append(category) }
            if let pair = word.category?.pair { parents.append(pair) }
        } else if let folder = record as? FolderMO {
            if let category = folder.category { parents.append(category) }
            if let pair = folder.category?.pair { parents.append(pair) }
        } else if let category = record as? CategoryMO, let pair = category.pair {
            parents.append(pair)
        }
        for parent in parents where parent.deletedAt != nil {
            parent.deletedAt = nil
            parent.deletionBatch = nil
            parent.touch()
        }
    }

    func purge(_ batch: DeletedBatch) {
        records(inBatch: batch.id).forEach { context.delete($0) }
        save()
    }

    func purgeExpired() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? Date()
        deletedBatches().filter { $0.deletedAt < cutoff }.forEach(purge)
    }

    func emptyRecentlyDeleted() {
        deletedBatches().forEach(purge)
    }

    // MARK: Wiping (used by backup restore)

    func wipeAll() {
        for name in ["WordMO", "FolderMO", "CategoryMO", "LanguagePairMO", "DailyActivityMO", "AchievementMO"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            ((try? context.fetch(request)) ?? []).forEach { context.delete($0) }
        }
        save()
    }
}
