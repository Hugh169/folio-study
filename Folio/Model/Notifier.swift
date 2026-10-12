import Foundation
import UserNotifications

/// Tells the student what Folio sorted in the background, with Undo, and,
/// when they ask for it, reminds them on Sunday evening to look back on their
/// week. Files they drop themselves never cause a notification.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let filedCategory = "filed"
    private nonisolated static let needsALookCategory = "needsALook"
    private nonisolated static let weeklyReviewCategory = "weeklyReview"
    private nonisolated static let weeklyReviewID = "weeklyReview"
    private nonisolated static let undoAction = "undo"
    private nonisolated static let idsKey = "ids"

    /// Called with the filed items to put back when the student taps Undo.
    var onUndo: (([UUID]) -> Void)?
    /// Called with the screen to show when the student clicks a notification.
    var onOpen: ((Destination) -> Void)?
    /// Called when the student clicks the weekly review reminder.
    var onWeeklyReview: (() -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func register() {
        center.delegate = self
        let undo = UNNotificationAction(identifier: Self.undoAction, title: String(localized: "Undo"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.filedCategory, actions: [undo], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.needsALookCategory, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.weeklyReviewCategory, actions: [], intentIdentifiers: []),
        ])
    }

    /// Asks once; macOS remembers the answer.
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAllowed() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// One notification for files filed close together.
    func filed(_ files: [(id: UUID, name: String, location: String)]) {
        guard let first = files.first else { return }
        let content = UNMutableNotificationContent()
        if files.count == 1 {
            content.title = String(localized: "Filed in \(first.location)")
            content.body = first.name
        } else {
            content.title = String(localized: "Folio filed \(files.count) files")
            let locations = Array(Set(files.map(\.location))).sorted()
            content.body = locations.count <= 3
                ? locations.formatted(.list(type: .and))
                : (Array(locations.prefix(2)) + [String(localized: "\(locations.count - 2) more")]).formatted(.list(type: .and))
        }
        content.categoryIdentifier = Self.filedCategory
        content.threadIdentifier = "filed"
        content.userInfo = [Self.idsKey: files.map(\.id.uuidString)]
        post(content)
    }

    func needsALook(_ name: String, question: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(name) needs a look")
        content.body = question
        content.categoryIdentifier = Self.needsALookCategory
        content.threadIdentifier = "needsALook"
        post(content)
    }

    /// The study timer ran out while Folio was in the background.
    func timeIsUp(_ subject: String, title: String?) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time's up")
        content.body = [subject, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        content.threadIdentifier = "timer"
        content.sound = .default
        post(content)
    }

    /// Every Sunday at 6 pm: a reminder to look back on the week and plan the next.
    func scheduleWeeklyReview() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your week in review")
        content.body = String(localized: "See how this week went, and plan the next one.")
        content.categoryIdentifier = Self.weeklyReviewCategory
        content.threadIdentifier = "weeklyReview"
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 18, minute: 0, weekday: 1), repeats: true)
        center.add(UNNotificationRequest(identifier: Self.weeklyReviewID, content: content, trigger: trigger))
    }

    func cancelWeeklyReview() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.weeklyReviewID])
    }

    private func post(_ content: UNMutableNotificationContent) {
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let ids = (response.notification.request.content.userInfo[Self.idsKey] as? [String] ?? []).compactMap(UUID.init(uuidString:))
        await MainActor.run {
            if action == Self.undoAction {
                onUndo?(ids)
            } else if action == UNNotificationDefaultActionIdentifier {
                switch category {
                case Self.needsALookCategory: onOpen?(.inbox)
                case Self.weeklyReviewCategory: onWeeklyReview?()
                default: onOpen?(.library)
                }
            }
        }
    }
}
