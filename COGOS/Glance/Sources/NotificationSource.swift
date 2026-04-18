import CoreGraphics
import CoreText
import Foundation
import UserNotifications

/// Pulls recent delivered notifications from UNUserNotificationCenter.
final class NotificationSource: GlanceSource {
    let name = "notifications"
    var enabled = true
    var cacheDuration: TimeInterval = 0 // always fresh

    private static let recentWindow: TimeInterval = 10 * 60
    private var cachedNotifications: [(app: String, body: String)] = []
    private var deliveredCache: (items: [UNNotification], at: Date)?

    func relevance(_ ctx: GlanceContext) async -> Int? {
        let delivered = await deliveredFresh(now: ctx.now)
        guard let newest = delivered.map({ $0.date }).max() else {
            trace("relevance: 0 delivered notifications")
            return nil
        }
        let ageSec = Int(ctx.now.timeIntervalSince(newest))
        if ctx.now.timeIntervalSince(newest) <= Self.recentWindow {
            trace("relevance: newest \(ageSec)s ago → eligible")
            return 2
        }
        trace("relevance: newest \(ageSec)s ago — older than \(Int(Self.recentWindow))s window")
        return nil
    }

    func fetch(context: GlanceContext) async -> String? {
        let delivered = await deliveredFresh(now: context.now)
        let sorted = delivered.sorted { $0.date > $1.date }.prefix(5)
        if sorted.isEmpty {
            trace("no delivered notifications to display")
            cachedNotifications = []
            return nil
        }
        cachedNotifications = sorted.map { n in
            let c = n.request.content
            let app = c.threadIdentifier.isEmpty ? c.categoryIdentifier : c.threadIdentifier
            return (app: app, body: c.body)
        }
        let snippets = cachedNotifications.prefix(3).map { n in
            n.app.isEmpty ? "- \(n.body)" : "- \(n.app): \(n.body)"
        }
        return "Notifications:\n\(snippets.joined(separator: "\n"))"
    }

    func quickNote() -> QuickNote? {
        guard !cachedNotifications.isEmpty else { return nil }
        let title = cachedNotifications.first?.app.isEmpty == false
            ? cachedNotifications.first!.app
            : "Notifications"
        let body = cachedNotifications.prefix(3).map { n in
            n.app.isEmpty ? n.body : "\(n.app): \(n.body)"
        }.joined(separator: "\n")
        return QuickNote(title: title, body: body)
    }

    func drawContent(in rect: CGRect, context: CGContext) -> Bool {
        guard !cachedNotifications.isEmpty else { return false }
        let font = CTFontCreateWithName("SFProDisplay-Regular" as CFString, 19, nil)
        let appFont = CTFontCreateWithName("SFProDisplay-Medium" as CFString, 19, nil)

        var y = rect.maxY - 8
        for notif in cachedNotifications {
            if !notif.app.isEmpty {
                y = GlanceDrawing.drawText(
                    notif.app, at: CGPoint(x: rect.minX, y: y),
                    font: appFont, in: context
                )
                y -= 2
            }
            let truncBody = GlanceDrawing.truncateToFit(notif.body, font: font, maxWidth: rect.width)
            y = GlanceDrawing.drawText(
                truncBody, at: CGPoint(x: rect.minX, y: y),
                font: font, in: context
            )
            y -= 8
            if y < rect.minY + 10 { break }
        }
        return true
    }

    /// Dedupes the `relevance` + `fetch` calls within a single tick so we
    /// only hit UNUserNotificationCenter once per GlanceService pass.
    private func deliveredFresh(now: Date) async -> [UNNotification] {
        if let cached = deliveredCache, now.timeIntervalSince(cached.at) < 1 {
            return cached.items
        }
        let items = await Self.getDelivered()
        deliveredCache = (items, now)
        return items
    }

    private static func getDelivered() async -> [UNNotification] {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getDeliveredNotifications { cont.resume(returning: $0) }
        }
    }
}
