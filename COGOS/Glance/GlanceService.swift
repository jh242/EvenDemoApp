import Foundation

/// Context-aware glance HUD rendered as a bitmap.
///
/// Rendering policy:
///   Left column  → fixed sources (time, weather) always shown
///   Right column → one contextual source chosen by relevance/priority
///                  (calendar → transit → notifications), falling back to news
///                  if nothing contextual is relevant right now.
@MainActor
final class GlanceService: ObservableObject {
    private let proto: Proto
    private let location: NativeLocation
    private let bmpTransfer: BmpTransfer
    private weak var session: EvenAISession?
    private weak var settings: Settings?

    private var sources: [GlanceSource] = []
    private var weatherSource: WeatherSource?
    private var calendarSource: CalendarSource?
    private var sourceCache: [String: (String, Date)] = [:]
    private var refreshTimer: Task<Void, Never>?
    private var isRefreshing = false

    private var winningSource: GlanceSource?
    private var winningSourceText: String?
    private var lastDashboardSignature: String?

    private struct CandidateResult {
        let source: GlanceSource
        let relevance: Int?
        let text: String?
        var name: String { source.name }
        var tier: GlanceTier { source.tier }
    }
    private var lastCandidates: [CandidateResult] = []

    private let renderer = GlanceRenderer()

    @Published var isShowing = false

    init(proto: Proto, location: NativeLocation, session: EvenAISession,
         requestQueue: BleRequestQueue, bluetooth: BluetoothManager,
         settings: Settings) {
        self.proto = proto
        self.location = location
        self.session = session
        self.settings = settings
        self.bmpTransfer = BmpTransfer(queue: requestQueue, bluetooth: bluetooth)
        buildSources()
    }

    private func buildSources() {
        let weather = WeatherSource(location: location)
        let calendar = CalendarSource()
        weatherSource = weather
        calendarSource = calendar
        sources = [
            TimeSource(),
            weather,
            calendar,
            TransitSource(location: location),
            NotificationSource(),
            NewsSource()
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
        // Kick the iOS permission prompt on first run — weather/transit both
        // short-circuit to nil if this never resolves to .granted.
        if location.checkPermission() == .notDetermined {
            location.requestPermission()
        }
        var userLoc = location.lastKnownLocation()
        if userLoc == nil { userLoc = await location.requestLocation() }
        let ctx = GlanceContext(now: now, userLocation: userLoc)

        // Fetch every enabled source every tick so diagnostic logging can show
        // all candidates, not just the winner. Per-source cacheDuration keeps
        // this cheap — fresh fetches happen at most once per cache window.
        var candidates: [CandidateResult] = []
        for s in sources where s.enabled {
            let rel = s.tier == .contextual ? await s.relevance(ctx) : nil
            let text = await fetchCached(s, now: now, context: ctx)
            candidates.append(CandidateResult(source: s, relevance: rel, text: text))
        }
        lastCandidates = candidates

        // Contextual winner = lowest-relevance source whose fetch produced
        // text. Fall back to the first fallback source with text if none.
        winningSource = nil
        winningSourceText = nil
        let contextualHit = candidates
            .filter { $0.tier == .contextual }
            .compactMap { c -> (GlanceSource, Int, String)? in
                guard let rel = c.relevance, let text = c.text else { return nil }
                return (c.source, rel, text)
            }
            .min { $0.1 < $1.1 }
        if let hit = contextualHit {
            winningSource = hit.0
            winningSourceText = hit.2
        } else if let fallback = candidates.first(where: { $0.tier == .fallback && $0.text != nil }) {
            winningSource = fallback.source
            winningSourceText = fallback.text
        }

        if settings?.useFirmwareDashboard == true {
            await pushFirmwareDashboard(now: now)
        }
    }

    private func pushFirmwareDashboard(now: Date) async {
        // Always push time+weather so the clock ticks even when weather fetch
        // has yet to succeed (location denied, wttr.in down). Firmware renders
        // `icon=.none` with no weather icon, which is the correct empty state.
        let info = weatherSource?.lastWeatherInfo ?? WeatherInfo(
            icon: .none, temperatureCelsius: 0, displayFahrenheit: false, hour24: true
        )
        _ = await proto.setDashboardTimeAndWeather(now: now, weather: info)

        let note = winningSource?.quickNote()
        let signature = noteSignature(note)
        let noteChanged = signature != lastDashboardSignature
        if noteChanged {
            // Replace-all-4-slots — slots 2..4 stay empty.
            _ = await proto.setQuickNoteSlots([note, nil, nil, nil])
            lastDashboardSignature = signature
        }

        logPush(now: now, weather: info, note: note, noteChanged: noteChanged)

        // Right-arm commit — without this firmware accepts the writes but
        // doesn't redraw. See G1 reference `0x22 0x05`.
        if noteChanged {
            _ = await proto.commitDashboard()
        }
    }

    private func noteSignature(_ note: QuickNote?) -> String {
        guard let n = note else { return "∅" }
        return "\(n.title)\u{1F}\(n.body)"
    }

    private func logPush(now: Date, weather: WeatherInfo, note: QuickNote?, noteChanged: Bool) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let timeStr = fmt.string(from: now)
        let weatherStr = "\(weather.icon) \(weather.temperatureCelsius)°C"
        let winnerStr = winningSource?.name ?? "—"
        let noteTag = noteChanged ? "slot1*" : "slot1"
        print("[dashboard] \(timeStr) | weather=\(weatherStr) | winner=\(winnerStr)")
        for c in lastCandidates {
            let rel = c.relevance.map(String.init) ?? "—"
            let preview = c.text?
                .replacingOccurrences(of: "\n", with: " ⏎ ")
                .prefix(120) ?? "nil"
            print("[dashboard]   [\(c.tier)] \(c.name) rel=\(rel) → \(preview)")
        }
        if let n = note {
            print("[dashboard]   \(noteTag).title=\(n.title)")
            for line in n.body.split(separator: "\n", omittingEmptySubsequences: false) {
                print("[dashboard]     \(line)")
            }
        } else {
            print("[dashboard]   \(noteTag)=nil")
        }
    }

    /// Fetch a source, honoring its cacheDuration.
    private func fetchCached(_ s: GlanceSource, now: Date, context: GlanceContext) async -> String? {
        if let (data, at) = sourceCache[s.name],
           s.cacheDuration > 0, now.timeIntervalSince(at) < s.cacheDuration {
            return data
        }
        guard let data = await s.fetch(context: context), !data.isEmpty else { return nil }
        sourceCache[s.name] = (data, now)
        return data
    }

    // MARK: - Show / dismiss

    func showGlance() async {
        guard !(session?.isRunning ?? false) else { return }
        // Firmware mode: head-up is handled entirely by firmware (it shows
        // whatever dashboard the `0x08 HEAD_UP_ACTION_SET` binding specifies,
        // which defaults to FULL). Triggering our own refresh here races with
        // firmware's auto-show and caused a visible DUAL↔FULL flip. The 60s
        // timer keeps data fresh in the background.
        if settings?.useFirmwareDashboard == true { return }
        await sendBitmap()
        isShowing = true
    }

    func forceRefreshAndShow() async {
        guard !(session?.isRunning ?? false) else { return }
        sourceCache.removeAll()
        await refresh()
        if settings?.useFirmwareDashboard == true { return }
        isShowing = true
        await sendBitmap()
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        Task { _ = await proto.exit() }
    }

    private func sendBitmap() async {
        guard let bmp = renderer.render(
            time: Date(),
            weather: weatherSource?.lastWeather,
            contextualSource: winningSource,
            contextualFallbackText: winningSourceText
        ) else { return }
        _ = await bmpTransfer.sendToBoth(bmp)
    }
}
