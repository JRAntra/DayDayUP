import CoreData

/// The Core Data model, built in code so it stays reviewable in plain Swift.
///
/// It already follows the rules NSPersistentCloudKitContainer requires, so iCloud sync can be
/// switched on later without a migration (see CLOUD_SYNC_TODO.md):
/// * every attribute is optional or has a default value,
/// * every relationship is optional and has an inverse,
/// * no unique constraints (duplicate checks live in VocabRepository instead),
/// * soft deletes via `deletedAt` + `deletionBatch`, so deletions can sync and be restored.
enum ManagedModel {
    /// Version 2 added the review schedule (word step, due day, started day, and the streak flag per day).
    /// Version 3 added the per-day answer counts per language pair, for the Progress charts.
    /// Older versions are kept so a store created by an older build can be migrated (see PersistenceController).
    static let currentVersion = 3
    static let shared: NSManagedObjectModel = build(version: currentVersion)

    private static func attribute(_ name: String, _ type: NSAttributeType, default value: Any? = nil) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = true
        a.defaultValue = value
        return a
    }

    /// Fields shared by every synced record.
    private static func syncFields() -> [NSPropertyDescription] {
        [
            attribute("id", .UUIDAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
            attribute("deletedAt", .dateAttributeType),
            attribute("deletionBatch", .UUIDAttributeType),
        ]
    }

    private static func relationship(_ name: String, to entity: NSEntityDescription, toMany: Bool,
                                     deleteRule: NSDeleteRule) -> NSRelationshipDescription {
        let r = NSRelationshipDescription()
        r.name = name
        r.destinationEntity = entity
        r.isOptional = true
        r.minCount = 0
        r.maxCount = toMany ? 0 : 1
        r.deleteRule = deleteRule
        return r
    }

    private static func link(_ a: NSRelationshipDescription, _ b: NSRelationshipDescription) {
        a.inverseRelationship = b
        b.inverseRelationship = a
    }

    static func build(version: Int) -> NSManagedObjectModel {
        let pair = NSEntityDescription()
        pair.name = "LanguagePairMO"
        pair.managedObjectClassName = "LanguagePairMO"

        let category = NSEntityDescription()
        category.name = "CategoryMO"
        category.managedObjectClassName = "CategoryMO"

        let folder = NSEntityDescription()
        folder.name = "FolderMO"
        folder.managedObjectClassName = "FolderMO"

        let word = NSEntityDescription()
        word.name = "WordMO"
        word.managedObjectClassName = "WordMO"

        let activity = NSEntityDescription()
        activity.name = "DailyActivityMO"
        activity.managedObjectClassName = "DailyActivityMO"

        let achievement = NSEntityDescription()
        achievement.name = "AchievementMO"
        achievement.managedObjectClassName = "AchievementMO"

        // Relationships
        let pairCategories = relationship("categories", to: category, toMany: true, deleteRule: .cascadeDeleteRule)
        let categoryPair = relationship("pair", to: pair, toMany: false, deleteRule: .nullifyDeleteRule)
        link(pairCategories, categoryPair)

        let categoryFolders = relationship("folders", to: folder, toMany: true, deleteRule: .cascadeDeleteRule)
        let folderCategory = relationship("category", to: category, toMany: false, deleteRule: .nullifyDeleteRule)
        link(categoryFolders, folderCategory)

        let categoryWords = relationship("words", to: word, toMany: true, deleteRule: .cascadeDeleteRule)
        let wordCategory = relationship("category", to: category, toMany: false, deleteRule: .nullifyDeleteRule)
        link(categoryWords, wordCategory)

        let folderWords = relationship("words", to: word, toMany: true, deleteRule: .nullifyDeleteRule)
        let wordFolder = relationship("folder", to: folder, toMany: false, deleteRule: .nullifyDeleteRule)
        link(folderWords, wordFolder)

        pair.properties = syncFields() + [
            attribute("fromCode", .stringAttributeType, default: "en"),
            attribute("toCode", .stringAttributeType, default: "zh"),
            attribute("script", .stringAttributeType, default: ChineseScript.simplified.rawValue),
            attribute("accentHex", .stringAttributeType, default: "1FA2FF"),
            attribute("sortIndex", .integer64AttributeType, default: 0),
            pairCategories,
        ]

        category.properties = syncFields() + [
            attribute("name", .stringAttributeType, default: ""),
            attribute("sortIndex", .integer64AttributeType, default: 0),
            categoryPair, categoryFolders, categoryWords,
        ]

        folder.properties = syncFields() + [
            attribute("name", .stringAttributeType, default: ""),
            attribute("sortIndex", .integer64AttributeType, default: 0),
            folderCategory, folderWords,
        ]

        word.properties = syncFields() + [
            attribute("term", .stringAttributeType, default: ""),
            attribute("termKey", .stringAttributeType, default: ""),
            attribute("reading", .stringAttributeType, default: ""),
            attribute("sensesJSON", .stringAttributeType, default: "[]"),
            attribute("example", .stringAttributeType, default: ""),
            attribute("notes", .stringAttributeType, default: ""),
            attribute("ring", .integer16AttributeType, default: 0),
            attribute("lastCorrectDay", .stringAttributeType),
            attribute("inReview", .booleanAttributeType, default: false),
            attribute("timesMissed", .integer32AttributeType, default: 0),
            attribute("rememberedAt", .dateAttributeType),
            wordCategory, wordFolder,
        ]
        if version >= 2 {
            // `ring` and `lastCorrectDay` are kept only so old data and backups can be mapped onto the ladder.
            word.properties += [
                attribute("step", .integer16AttributeType, default: 0),
                attribute("dueDay", .stringAttributeType),
                attribute("startedDay", .stringAttributeType),
            ]
        }

        activity.properties = syncFields() + [
            attribute("dayKey", .stringAttributeType, default: ""),
            attribute("quizzesCompleted", .integer32AttributeType, default: 0),
            attribute("wordsRemembered", .integer32AttributeType, default: 0),
            attribute("wordsAdded", .integer32AttributeType, default: 0),
        ]
        if version >= 2 {
            activity.properties += [attribute("streakEarned", .booleanAttributeType, default: false)]
        }
        if version >= 3 {
            // {"<pair id>": [correct, missed]} for answers given that day.
            activity.properties += [attribute("answersJSON", .stringAttributeType, default: "{}")]
        }

        achievement.properties = syncFields() + [
            attribute("key", .stringAttributeType, default: ""),
            attribute("unlockedAt", .dateAttributeType),
        ]

        let model = NSManagedObjectModel()
        model.entities = [pair, category, folder, word, activity, achievement]
        return model
    }
}
