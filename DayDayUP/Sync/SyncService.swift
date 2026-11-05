import Foundation

/// The seam where cloud sync plugs in. The app only talks to `SyncService`, so switching from
/// local-only storage to iCloud (or a custom backend) doesn't touch any feature code.
///
/// Status: `LocalOnlySyncService` is active. The other two are TO BE IMPLEMENTED; see CLOUD_SYNC_TODO.md.
protocol SyncService: AnyObject {
    var displayName: String { get }
    var isAvailable: Bool { get }
    var status: SyncStatus { get }

    /// Called once at launch after the local store has loaded.
    func start() async
    /// Push local changes and pull remote ones.
    func syncNow() async throws
    /// Stop syncing; local data stays on the device.
    func stop()
}

enum SyncStatus: Equatable {
    case localOnly
    case notImplemented
    case idle(lastSync: Date?)
    case syncing
    case failed(String)

    var label: String {
        switch self {
        case .localOnly: return "Stored on this device"
        case .notImplemented: return "Coming soon"
        case .idle(let date):
            if let date { return "Synced \(date.formatted(date: .abbreviated, time: .shortened))" }
            return "Ready"
        case .syncing: return "Syncing…"
        case .failed(let message): return message
        }
    }
}

enum SyncError: LocalizedError {
    case notImplemented
    var errorDescription: String? { "Cloud sync isn't available yet." }
}

/// Active today: everything stays in the local Core Data store. Use backup files to move data.
final class LocalOnlySyncService: SyncService {
    let displayName = "This device only"
    let isAvailable = true
    let status = SyncStatus.localOnly
    func start() async {}
    func syncNow() async throws {}
    func stop() {}
}

/// TO BE IMPLEMENTED: iCloud sync between the user's own iPhone and Mac.
///
/// Plan (details in CLOUD_SYNC_TODO.md):
/// 1. Add the iCloud capability with CloudKit and a container, e.g. `iCloud.com.example.vocaquest`.
/// 2. In `PersistenceController`, use `NSPersistentCloudKitContainer` and set
///    `description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier:)`.
/// 3. The model already meets CloudKit's rules (optional attributes, inverse relationships,
///    no unique constraints, soft deletes), so no migration is needed.
/// 4. After remote imports, run a de-duplication pass: words in the same category with the same
///    `termKey` merge with `VocabRepository.move`'s rules; DailyActivity rows with the same `dayKey`
///    are summed; Achievement rows with the same `key` keep the earliest `unlockedAt`.
/// 5. Observe `NSPersistentCloudKitContainer.eventChangedNotification` to drive `status`.
final class ICloudSyncService: SyncService {
    let displayName = "iCloud"
    let isAvailable = false
    let status = SyncStatus.notImplemented
    func start() async {}
    func syncNow() async throws { throw SyncError.notImplemented }
    func stop() {}
}

/// TO BE IMPLEMENTED: sync with a custom backend (e.g. Supabase or Firebase), which would allow
/// accounts, sharing word lists, or non-Apple clients later.
///
/// Plan: every record already carries `id`, `createdAt`, `updatedAt`, `deletedAt` and
/// `deletionBatch`, which is enough for last-writer-wins sync keyed on `id` with `updatedAt`
/// as the version. Upload rows changed since the last sync token, download rows changed
/// remotely, and apply deletes from `deletedAt`. The JSON shapes in `BackupService` can be
/// reused as the wire format.
final class RemoteBackendSyncService: SyncService {
    let displayName = "DayDayUP Cloud"
    let isAvailable = false
    let status = SyncStatus.notImplemented
    func start() async {}
    func syncNow() async throws { throw SyncError.notImplemented }
    func stop() {}
}
