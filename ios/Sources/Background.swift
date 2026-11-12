import BackgroundTasks
import Foundation
import UserNotifications

/// Refreshing while Nimbus isn't on screen. iOS decides when a background task runs, if at
/// all, so a notification before the apps expire backs it up.
enum BackgroundRefresh {
    /// Also listed in Info.plist; see scripts/build-ios.sh.
    static let taskID = "io.github.daan-25.nimbus.refresh"

    /// Has to run before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            Task { @MainActor in
                let model = PhoneModel.shared
                task.expirationHandler = {
                    Task { @MainActor in model.cancel() }
                }
                let succeeded = await model.refreshInBackground()
                task.setTaskCompleted(success: succeeded)
            }
        }
    }

    /// Asks iOS to run the refresh at `date` or later; nil cancels it.
    static func schedule(at date: Date?) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
        guard let date else { return }
        // Signing and installing takes minutes, more than the short kind of task gets.
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = max(date, Date.now.addingTimeInterval(15 * 60))
        try? BGTaskScheduler.shared.submit(request)
    }
}

enum Notifier {
    private static let expiryID = "expiry"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Warns a day before the first app expires, in case no refresh happened by then.
    static func scheduleExpiryWarning(for expiry: Date?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [expiryID])
        guard let expiry else { return }
        let warnAt = expiry.addingTimeInterval(-24 * 60 * 60)
        guard warnAt > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your apps expire tomorrow"
        content.body = "Turn on LocalDevVPN and open Nimbus to refresh them."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: warnAt.timeIntervalSinceNow, repeats: false)
        center.add(UNNotificationRequest(identifier: expiryID, content: content, trigger: trigger))
    }
}
