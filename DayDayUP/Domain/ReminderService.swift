import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// One local notification a day at a chosen time, only on days with reviews due, plus the due count on
/// the app icon. Permission is asked the first time Today is opened.
@MainActor
final class ReminderService: ObservableObject {
    private static let enabledKey = "reminders.enabled"
    private static let minutesKey = "reminders.minutes"
    private static let askedKey = "reminders.asked"
    private static let idPrefix = "daily-review-"
    /// How many days ahead are scheduled; refreshed whenever the app is opened or a session ends.
    private static let daysAhead = 7

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); Task { await refresh() } }
    }
    /// Minutes after midnight, local time. Default 20:00.
    @Published var minutes: Int {
        didSet { UserDefaults.standard.set(minutes, forKey: Self.minutesKey); Task { await refresh() } }
    }
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private let repository: VocabRepository
    private var center: UNUserNotificationCenter { .current() }

    init(repository: VocabRepository) {
        self.repository = repository
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        minutes = defaults.object(forKey: Self.minutesKey) as? Int ?? 20 * 60
    }

    /// The reminder time as a date today, for a time picker.
    var time: Date {
        get { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            minutes = (parts.hour ?? 20) * 60 + (parts.minute ?? 0)
        }
    }

    /// Asks once, the first time Today is opened. Later changes happen in system Settings.
    func requestPermissionIfNeeded() async {
        await updateAuthorization()
        guard !UserDefaults.standard.bool(forKey: Self.askedKey), authorization == .notDetermined else { return }
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await updateAuthorization()
        await refresh()
    }

    func updateAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Updates the icon badge and replaces the scheduled reminders with fresh due counts.
    func refresh() async {
        await updateAuthorization()
        let today = DayKey.today
        await setBadge(repository.dueCount(on: today))

        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard enabled, authorization == .authorized || authorization == .provisional else { return }

        for offset in 0..<Self.daysAhead {
            let day = DayKey.adding(offset, to: today)
            guard let date = DayKey.date(from: day),
                  let fire = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: date),
                  fire > Date() else { continue }
            // Assumes nothing is reviewed early; a review done before then makes the count a little high.
            let count = repository.dueCount(on: day)
            guard count > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Time to review"
            content.body = count == 1 ? "1 word is ready to review today." : "\(count) words are ready to review today."
            content.sound = .default
            content.badge = NSNumber(value: count)
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let request = UNNotificationRequest(identifier: Self.idPrefix + day, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }
    }

    private func setBadge(_ count: Int) async {
        #if os(macOS)
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #else
        guard authorization == .authorized || authorization == .provisional else { return }
        try? await center.setBadgeCount(count)
        #endif
    }
}
