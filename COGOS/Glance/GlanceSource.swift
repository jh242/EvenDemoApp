import Foundation

/// A pluggable source of contextual data for the glance HUD.
protocol GlanceSource {
    var name: String { get }
    var enabled: Bool { get }
    var cacheDuration: TimeInterval { get }
    func fetch() async -> String?
}
