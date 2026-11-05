# Cloud sync: to be implemented

DayDayUP stores everything locally today (`LocalOnlySyncService`). The code is shaped so sync can be added without touching feature code. This file lists what's left.

## What's already in place

- **One seam.** Features never talk to the cloud. `AppModel.sync` holds a `SyncService` (`Sync/SyncService.swift`). Swap `LocalOnlySyncService()` for a real implementation.
- **A CloudKit-ready model** (`Persistence/ManagedModel.swift`):
  - every attribute is optional or has a default,
  - every relationship is optional and has an inverse,
  - there are no unique constraints (CloudKit can't enforce them),
  - every record has `id`, `createdAt`, `updatedAt`, `deletedAt`, `deletionBatch`.
- **Soft deletes.** Deleting only stamps `deletedAt`/`deletionBatch`; Recently Deleted purges after 30 days. Deletions therefore sync as ordinary updates and stay restorable on every device.
- **Persistent history tracking** and remote-change notifications are already enabled on the store, which `NSPersistentCloudKitContainer` requires.
- **A settings switch** ("Sync with iCloud — Coming soon") in Settings → Data.

## Option A: iCloud (recommended, Apple devices only)

1. In Xcode, add the **iCloud** capability (CloudKit) to both targets with a container such as `iCloud.com.example.vocaquest`, plus **Background Modes → Remote notifications** on iOS.
2. In `PersistenceController.init`, replace `NSPersistentContainer` with `NSPersistentCloudKitContainer` and set
   `description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.example.vocaquest")`.
   Gate this behind the Settings switch so turning sync off falls back to the local store.
3. Implement `ICloudSyncService`:
   - `status` from `NSPersistentCloudKitContainer.eventChangedNotification`,
   - `syncNow()` can simply trigger a save; CloudKit mirroring is automatic.
4. **De-duplicate after imports.** Two devices can create the same thing offline. On `NSPersistentStoreRemoteChange`, merge:
   - words with the same `category` + `termKey` → use the rules in `VocabRepository.move` (combine senses keeping the primary first, keep the better ring, carry over Review Book status, add `timesMissed`),
   - categories with the same pair + name, folders with the same category + name → keep the oldest, re-point children,
   - language pairs with the same from/to → keep the oldest,
   - `DailyActivityMO` rows with the same `dayKey` → sum the counters into one row,
   - `AchievementMO` rows with the same `key` → keep the earliest `unlockedAt`.
5. Run `initializeCloudKitSchema()` once in a development build to create the CloudKit schema, then deploy it to production in the CloudKit console.
6. Remove the "Coming soon" label and enable the toggle.

## Option B: your own backend (accounts, sharing, non-Apple clients)

1. Implement `RemoteBackendSyncService` against a service such as Supabase or Firebase.
2. Use the record shapes in `ImportExport/ImportExport.swift` (`BackupFile.*`) as the wire format; they already carry ids and timestamps.
3. Sync algorithm: last-writer-wins keyed on `id`, using `updatedAt` as the version. Push rows changed since the last sync token, pull remote changes, apply `deletedAt` as deletes. Then run the same de-duplication pass as Option A.
4. Add sign-in UI in Settings → Data.
