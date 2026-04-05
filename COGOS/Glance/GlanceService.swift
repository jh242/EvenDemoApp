import Foundation

/// Context-aware glance HUD. Ports `lib/services/glance_service.dart`.
@MainActor
final class GlanceService: ObservableObject {
    private let proto: Proto
    private let settings: Settings
    private let location: NativeLocation
    private weak var session: EvenAISession?

    private var sources: [GlanceSource] = []
    private var cachedLines: [String] = []
    private var sourceCache: [String: (String, Date)] = [:]
    private var refreshTimer: Task<Void, Never>?
    private var dismissTimer: Task<Void, Never>?
    private var isRefreshing = false

    @Published var isShowing = false

    init(proto: Proto, settings: Settings, location: NativeLocation, session: EvenAISession) {
        self.proto = proto
        self.settings = settings
        self.location = location
        self.session = session
        buildSources()
    }

    private func buildSources() {
        sources = [
            LocationSource(location: location),
            CalendarSource(),
            WeatherSource(settings: settings, location: location),
            TransitSource(),
            NotificationSource(),
            NewsSource(settings: settings)
        ]
    }

    // MARK: - Timer

    func startTimer() {
        stopTimer()
        Task { await refresh() }
        refreshTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    func stopTimer() {
        refreshTimer?.cancel(); refreshTimer = nil
    }

    // MARK: - Refresh

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        var cachedSnippets: [String] = []
        var staleSources: [GlanceSource] = []
        for s in sources {
            if !s.enabled { continue }
            if let (data, at) = sourceCache[s.name],
               s.cacheDuration > 0, now.timeIntervalSince(at) < s.cacheDuration {
                cachedSnippets.append(data)
            } else {
                staleSources.append(s)
            }
        }

        var freshSnippets: [String] = []
        await withTaskGroup(of: (String, String?).self) { group in
            for src in staleSources {
                group.addTask { (src.name, await src.fetch()) }
            }
            for await (name, data) in group {
                if let d = data, !d.isEmpty {
                    sourceCache[name] = (d, now)
                    freshSnippets.append(d)
                }
            }
        }

        if freshSnippets.isEmpty && !cachedLines.isEmpty { return }

        let snippets = cachedSnippets + freshSnippets
        if snippets.isEmpty { cachedLines = ["No data available"]; return }

        if let client = settings.makeHaikuClient() {
            do {
                let lines = try await client.summarize(
                    context: snippets.joined(separator: "\n"),
                    systemPrompt: "You are a smart glasses HUD. Output exactly 5 lines, max 23 chars each. " +
                                  "Show the most relevant info right now. Prioritize urgent/time-sensitive " +
                                  "items, then contextual info, then notifications. Be terse. No markdown.",
                    maxTokens: 100
                )
                cachedLines = lines.isEmpty ? ["No response"] : lines
            } catch {
                cachedLines = ["Glance unavailable"]
            }
        } else {
            cachedLines = ["No API key set", "Add key in Settings"]
        }
    }

    // MARK: - Show / dismiss

    func showGlance() async {
        guard !(session?.isRunning ?? false) else { return }
        let lines = cachedLines.isEmpty ? ["Glance loading..."] : cachedLines
        await sendToGlasses(lines)
        isShowing = true
        startDismissTimer()
    }

    func forceRefreshAndShow() async {
        guard !(session?.isRunning ?? false) else { return }
        await sendToGlasses(["Refreshing..."])
        isShowing = true
        sourceCache.removeAll()
        await refresh()
        let lines = cachedLines.isEmpty ? ["No data available"] : cachedLines
        await sendToGlasses(lines)
        startDismissTimer()
    }

    func dismiss() {
        guard isShowing else { return }
        dismissTimer?.cancel(); dismissTimer = nil
        isShowing = false
        Task { _ = await proto.exit() }
    }

    private func startDismissTimer() {
        dismissTimer?.cancel()
        dismissTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run { self?.dismiss() }
        }
    }

    private func sendToGlasses(_ lines: [String]) async {
        var measured: [String] = []
        for line in lines { measured.append(contentsOf: TextPaginator.measureStringList(line)) }
        let first5 = Array(measured.prefix(5))
        let padCount = max(0, 5 - first5.count)
        let pad = Array(repeating: " \n", count: padCount)
        let content = first5.map { $0 + "\n" }
        let screen = (pad + content).joined()
        _ = await proto.sendEvenAIData(screen, newScreen: 0x01 | 0x70,
                                       pos: 0, currentPageNum: 1, maxPageNum: 1)
    }
}
