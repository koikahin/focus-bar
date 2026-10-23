import AppKit
import UserNotifications

/// Exercises a real target deadline and system delivery in an isolated profile.
@MainActor
final class FocusNotificationProbe: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    private let suiteName = "FocusBarNotificationProbe.\(UUID().uuidString)"
    private let identifier = "focusbar.test.\(UUID().uuidString)"

    static func run() {
        let probe = FocusNotificationProbe()
        probe.checkDelivery()
    }

    private func checkDelivery() {
        _ = NSApplication.shared
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = FocusStore(defaults: defaults, backups: nil)
        store.addTask(name: "Notification Test", targetSeconds: 30 * 60)
        let task = store.tasks.last!
        store.setElapsed(for: task, to: 30 * 60 - 1)
        let notifications = FocusNotifications(center: center) { message in
            self.finish(message: message, success: false)
        }
        notifications.start()
        store.onTaskCompleted = { [self] task, dayKey in
            notifications.deliver(identifier: identifier, title: "Daily target complete",
                                  body: store.completionNotificationBody(for: task, dayKey: dayKey) + "\nThis is a test.")
        }
        let scheduler = FocusScheduler(store: store, onRefresh: {})
        store.start(taskID: task.id)
        scheduler.refresh()
        let deliveryCheck = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in self.checkDeliveredNotifications() }
        }
        let timeout = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            Task { @MainActor in
                self.finish(message: "FAIL: timed out waiting for notification permission or delivery.", success: false)
            }
        }
        withExtendedLifetime((self, scheduler, notifications, timeout, deliveryCheck)) { RunLoop.main.run() }
    }

    private func checkDeliveredNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            if let notification = delivered.first(where: { $0.request.identifier == self.identifier }) {
                let body = notification.request.content.body
                let hasStreaks = body.contains("1-day streak") && body.contains("1-day (30 min) streak")
                Task { @MainActor in
                    self.finish(message: hasStreaks
                                ? "PASS: test focus area reached its target and macOS delivered the notification with both streaks."
                                : "FAIL: the delivered notification did not contain both expected streaks.", success: hasStreaks)
                }
            }
        }
    }

    private func finish(message: String, success: Bool) -> Never {
        UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName)
        print(message)
        exit(success ? 0 : 1)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
