import Foundation
import UserNotifications

/// Pulls recent delivered notifications from UNUserNotificationCenter.
/// Direct replacement for the Flutter NotificationChannel buffer.
struct NotificationSource: GlanceSource {
    let name = "notifications"
    var enabled = true
    var cacheDuration: TimeInterval = 0 // always fresh

    func fetch() async -> String? {
        let delivered = await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getDeliveredNotifications { cont.resume(returning: $0) }
        }
        let sorted = delivered.sorted { $0.date > $1.date }.prefix(3)
        if sorted.isEmpty { return nil }
        let snippets = sorted.map { n -> String in
            let c = n.request.content
            let app = c.threadIdentifier.isEmpty ? c.categoryIdentifier : c.threadIdentifier
            let body = c.body
            return app.isEmpty ? "- \(body)" : "- \(app): \(body)"
        }
        return "Notifications:\n\(snippets.joined(separator: "\n"))"
    }
}
