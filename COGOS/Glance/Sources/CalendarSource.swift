import Foundation
import EventKit

struct CalendarSource: GlanceSource {
    let name = "calendar"
    var enabled = true
    var cacheDuration: TimeInterval = 300

    func fetch() async -> String? {
        let store = EKEventStore()
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        guard granted else { return nil }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        guard let endDate = Calendar.current.date(byAdding: .day, value: 2, to: startOfDay) else { return nil }
        let predicate = store.predicateForEvents(withStart: now, end: endDate, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        let upcoming = Array(events.prefix(3))
        if upcoming.isEmpty { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        let lines = upcoming.map { ev -> String in
            let t = formatter.string(from: ev.startDate)
            let title = ev.title ?? "Untitled"
            return "- \(t) \(title)"
        }
        return "Calendar:\n\(lines.joined(separator: "\n"))"
    }
}
