import Foundation
import Combine

/// Session orchestrator: mic on/off, STT, silence detect, LLM stream,
/// glasses display.
///
/// Display path uses the firmware-native 0x54 streaming TEXT command —
/// phone emits a `prepare` packet at the start of a reply, then cumulative
/// text updates as tokens arrive. Firmware owns pagination and scroll.
@MainActor
final class EvenAISession: ObservableObject {
    // MARK: - Published

    @Published var isRunning = false
    @Published var isReceivingAudio = false
    @Published var isSyncing = false
    @Published var dynamicText: String = "Press and hold left TouchBar to engage Even AI."
    @Published var mode: SessionMode = .chat
    @Published var isScrollViewerActive = false

    // MARK: - Collaborators

    private let proto: Proto
    private let speech: SpeechStreamRecognizer
    private let settings: Settings
    weak var historyStore: HistoryStore?

    // MARK: - State

    private let session = ClaudeSession()
    private var combinedText: String = ""
    private var lastTranscriptChange: Date = Date()
    private var silenceTask: Task<Void, Never>?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var sttTask: Task<Void, Never>?

    private var lastStartMs: Int = 0
    private var lastStopMs: Int = 0
    private let startTimeGap = 500
    private let stopTimeGap = 500
    private let maxRecordingDuration = 30

    // MARK: - Scroll viewer state

    private struct ScrollPage {
        let percent: UInt8
        let window: String
    }

    /// One display page = up to 3 lines (firmware shows 3). Each tap
    /// advances by this many logical lines.
    private let scrollLinesPerPage = 3

    /// Auto-scroll phase cadence — roughly matches the 150-300 ms we
    /// observed between consecutive 0x64 re-sends in the OEM capture.
    private let autoScrollTickNanos: UInt64 = 150_000_000

    private var scrollPages: [ScrollPage] = []
    private var currentPageIndex: Int = 0
    private var autoScrollTask: Task<Void, Never>?
    private var scrollTapTask: Task<Void, Never>?

    init(proto: Proto, speech: SpeechStreamRecognizer, settings: Settings) {
        self.proto = proto
        self.speech = speech
        self.settings = settings
    }

    // MARK: - Lifecycle

    func toStartEvenAIByOS() async {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if now - lastStartMs < startTimeGap { return }
        lastStartMs = now

        combinedText = ""
        lastTranscriptChange = Date()
        startSTT()

        clear()
        isReceivingAudio = true
        isRunning = true
        isSyncing = true

        _ = await proto.micOn(lr: "R")
        startSilenceTimer()
        startRecordingTimer()
    }

    private func startSTT() {
        sttTask?.cancel()
        let stream = speech.startRecognition()
        sttTask = Task { [weak self] in
            for await text in stream {
                guard let self = self else { return }
                if text != self.combinedText {
                    self.combinedText = text
                    self.lastTranscriptChange = Date()
                }
            }
        }
    }

    private func startSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, self.isReceivingAudio else { return }
                let elapsed = Date().timeIntervalSince(self.lastTranscriptChange)
                if elapsed >= Double(self.settings.silenceThreshold) && !self.combinedText.isEmpty {
                    await self.recordOverByOS()
                    return
                }
            }
        }
    }

    private func startRecordingTimer() {
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.maxRecordingDuration ?? 30) * 1_000_000_000)
            guard let self = self else { return }
            if self.isReceivingAudio {
                await self.shutdownMic()
                self.clear()
            }
        }
    }

    private func shutdownMic() async {
        _ = speech.stopRecognition()
        _ = await proto.micOff(lr: "R")
    }

    func recordOverByOS() async {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if now - lastStopMs < stopTimeGap { return }
        lastStopMs = now

        isReceivingAudio = false
        silenceTask?.cancel(); silenceTask = nil
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil

        await shutdownMic()
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        if combinedText.isEmpty {
            dynamicText = "No Speech Recognized"
            isSyncing = false
            await pushReply("No Speech Recognized")
            return
        }

        let query = combinedText
        var fullAnswer = ""

        guard let client = settings.makeChatClient() else {
            isSyncing = false
            await pushReply("No API key set. Add key in Settings.")
            return
        }

        do {
            fullAnswer = try await streamAndDisplay(client.stream(message: query, session: session))
        } catch {
            isSyncing = false
            await pushReply("API error: \(error.localizedDescription)")
            return
        }

        isSyncing = false
        session.addUser(query)
        session.addAssistant(fullAnswer)
        session.lastQuery = query
        session.lastAnswer = fullAnswer
        historyStore?.addItem(title: query, content: fullAnswer)
        dynamicText = "\(query)\n\n\(fullAnswer)"
    }

    // MARK: - Streaming display

    /// Prepare + cumulative 0x54 updates. Firmware owns pagination, so we
    /// just feed it the full answer-so-far on every tick. Backpressure is
    /// natural: each `sendEvenAIText` awaits L+R C9 before returning.
    private func streamAndDisplay(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        _ = await proto.sendEvenAITextPrepare()
        _ = await proto.sendEvenAIText(format("Thinking"))

        let keepalive = Task { [proto] in
            let frames = ["Thinking.", "Thinking..", "Thinking..."]
            var i = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { return }
                _ = await proto.sendEvenAIText("\n\n" + frames[i % frames.count])
                i += 1
            }
        }

        var accumulated = ""
        var lastSent = ""
        do {
            for try await chunk in stream {
                if !isRunning { break }
                if keepalive.isCancelled == false { keepalive.cancel() }
                accumulated += chunk
                if accumulated != lastSent {
                    _ = await proto.sendEvenAIText(format(accumulated))
                    lastSent = accumulated
                }
            }
        } catch {
            keepalive.cancel()
            throw error
        }
        keepalive.cancel()
        if accumulated != lastSent && isRunning {
            _ = await proto.sendEvenAIText(format(accumulated))
        }
        if isRunning && !accumulated.isEmpty {
            await runScrollViewerIfNeeded(answer: accumulated)
        }
        return accumulated
    }

    // MARK: - Scroll viewer

    /// After the last streaming update, decide whether the reply needs a
    /// scroll viewer (firmware only tails the last ~3 lines; anything
    /// longer would be invisible otherwise).
    ///
    /// Short replies → send close. Long replies → OEM-style flow:
    /// 1. auto-scroll: re-send text with status=0x64 (passive), trimming
    ///    a word from the front every ~150 ms until the remaining text
    ///    fits on screen
    /// 2. interactive entry: one packet with scroll=0x01, status=0x64
    ///    pointing at the last page
    /// 3. wait for `F5 0x01` taps (routed via `advanceScrollPage`)
    private func runScrollViewerIfNeeded(answer: String) async {
        let formatted = format(answer)
        scrollPages = computePages(text: formatted)
        guard scrollPages.count > 1, needsScroll(formatted) else {
            _ = await proto.sendEvenAIClose()
            return
        }

        // Phase 1: auto-scroll. Cancellable via `cancelAutoScroll()` if
        // the user taps or exits early.
        autoScrollTask?.cancel()
        let tickNanos = autoScrollTickNanos
        let startText = formatted
        autoScrollTask = Task { [weak self, proto] in
            var current = startText
            while !Task.isCancelled {
                let next = Self.trimLeadingWord(current)
                if next.isEmpty || next == current { break }
                current = next
                guard let self = self else { return }
                if self.fitsOnScreen(current) { break }
                _ = await proto.sendEvenAIText(
                    current,
                    status: EvenAIText54.Status.complete,
                    scrollFlag: EvenAIText54.ScrollFlag.passive
                )
                try? await Task.sleep(nanoseconds: tickNanos)
            }
        }
        await autoScrollTask?.value
        autoScrollTask = nil
        guard isRunning else { return }

        // Phase 2: enter interactive viewer. OEM pins the entry packet at
        // byte11=0x64 (100 %) regardless of which page the payload shows.
        currentPageIndex = scrollPages.count - 1
        let entryWindow = scrollPages[currentPageIndex].window
        _ = await proto.sendEvenAIText(
            entryWindow,
            status: EvenAIText54.Status.complete,
            scrollFlag: EvenAIText54.ScrollFlag.interactive
        )
        isScrollViewerActive = true
    }

    /// Called from `GestureRouter` on `F5 0x01` (single tap). Direction
    /// matches the arm: `"L"` = previous page, `"R"` = next page.
    func advanceScrollPage(direction: String) {
        // A tap during the auto-scroll phase bails us out early and lets
        // the user drive manually.
        if autoScrollTask != nil {
            autoScrollTask?.cancel()
            autoScrollTask = nil
        }
        guard isScrollViewerActive, !scrollPages.isEmpty else { return }

        var next = currentPageIndex
        if direction == "L" {
            next = max(0, currentPageIndex - 1)
        } else {
            next = min(scrollPages.count - 1, currentPageIndex + 1)
        }
        if next == currentPageIndex { return }
        currentPageIndex = next
        let page = scrollPages[currentPageIndex]
        scrollTapTask?.cancel()
        scrollTapTask = Task { [proto] in
            _ = await proto.sendEvenAIText(
                page.window,
                status: page.percent,
                scrollFlag: EvenAIText54.ScrollFlag.interactive
            )
        }
    }

    /// Called from `GestureRouter` on `F5 0x00` — exits the scroll viewer
    /// by sending the sub=0x01 close packet. Safe to call when not
    /// scrolling.
    func exitScrollViewer() {
        cancelAutoScroll()
        guard isScrollViewerActive else { return }
        isScrollViewerActive = false
        scrollPages = []
        currentPageIndex = 0
        scrollTapTask?.cancel(); scrollTapTask = nil
        Task { [proto] in _ = await proto.sendEvenAIClose() }
    }

    private func cancelAutoScroll() {
        autoScrollTask?.cancel(); autoScrollTask = nil
    }

    /// True when the formatted reply exceeds the firmware's 3-line tail
    /// view. Chars-per-line on the G1 waveguide is ~20–24 depending on
    /// font; 60 is a safe ceiling for "definitely needs scroll".
    private func needsScroll(_ text: String) -> Bool {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return lineCount > scrollLinesPerPage || text.count > 60
    }

    private func fitsOnScreen(_ text: String) -> Bool {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return lineCount <= scrollLinesPerPage && text.count <= 60
    }

    private static func trimLeadingWord(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var idx = text.startIndex
        while idx < text.endIndex, text[idx].isWhitespace { idx = text.index(after: idx) }
        if idx == text.endIndex { return "" }
        while idx < text.endIndex, !text[idx].isWhitespace { idx = text.index(after: idx) }
        while idx < text.endIndex, text[idx].isWhitespace { idx = text.index(after: idx) }
        return String(text[idx...])
    }

    /// Break `text` into pages of `scrollLinesPerPage` lines each. Each
    /// page's `window` is the text from the top of the page to the end
    /// of the answer — firmware renders the top 3 lines of what we send,
    /// so trailing content just preloads the next page visually.
    /// `percent` = bytes skipped / total bytes × 100 (0 at page 1,
    /// approaches 100 on the last page).
    private func computePages(text: String) -> [ScrollPage] {
        let totalBytes = text.utf8.count
        guard totalBytes > 0 else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1 else {
            return [ScrollPage(percent: 0, window: text)]
        }
        var pages: [ScrollPage] = []
        var i = 0
        while i < lines.count {
            let window = lines[i...].joined(separator: "\n")
            let skipped = totalBytes - window.utf8.count
            let percent = UInt8(min(100, (skipped * 100) / max(1, totalBytes)))
            pages.append(ScrollPage(percent: percent, window: window))
            i += scrollLinesPerPage
        }
        return pages
    }

    /// One-shot reply (errors, "no speech", reset messages). Uses the same
    /// prepare+text pair so the firmware accepts it as a fresh message.
    private func pushReply(_ text: String) async {
        _ = await proto.sendEvenAITextPrepare()
        _ = await proto.sendEvenAIText(format(text))
    }

    /// Two leading newlines push the first line below the dashboard header,
    /// matching the official app's framing. Trailing newline mirrors the
    /// Even app's per-update terminator — without it, firmware renders the
    /// first ~3 lines and stops advancing the viewport as new tokens arrive.
    private func format(_ text: String) -> String { "\n\n\(text)\n" }

    func resetSession() {
        session.reset()
        Task { await pushReply("Session reset") }
    }

    func stopEvenAIByOS() async {
        isRunning = false
        clear()
        await shutdownMic()
    }

    func exitAll() {
        Task { await stopEvenAIByOS() }
    }

    func clear() {
        isReceivingAudio = false
        isRunning = false
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        silenceTask?.cancel(); silenceTask = nil
        cancelAutoScroll()
        scrollTapTask?.cancel(); scrollTapTask = nil
        if isScrollViewerActive {
            isScrollViewerActive = false
            scrollPages = []
            currentPageIndex = 0
        }
    }
}
