import Foundation
import Combine

/// Session orchestrator: mic on/off, STT, silence detect, Claude stream, pagination, glasses display.
/// Ports `lib/services/evenai.dart`.
@MainActor
final class EvenAISession: ObservableObject {
    // MARK: - Published

    @Published var isRunning = false
    @Published var isReceivingAudio = false
    @Published var isSyncing = false
    @Published var dynamicText: String = "Press and hold left TouchBar to engage Even AI."
    @Published var mode: SessionMode = .chat

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
    private var pagingTimerTask: Task<Void, Never>?

    // Pagination state
    private var currentLine: Int = 0
    private var lines: [String] = []
    private var isManual = false

    private var lastStartMs: Int = 0
    private var lastStopMs: Int = 0
    private let startTimeGap = 500
    private let stopTimeGap = 500
    private let maxRecordingDuration = 30
    private static let maxRetry = 10

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
        currentLine = 0
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
            await startSendReply("No Speech Recognized")
            return
        }

        let query = combinedText
        var fullAnswer = ""

        // Try cowork relay first; fall back to direct API on offline.
        do {
            if let relay = settings.makeRelayClient() {
                session.isOffline = false
                fullAnswer = try await collect(stream: relay.stream(message: query, session: session))
            } else {
                throw RelayError.offline("no relay configured")
            }
        } catch RelayError.auth {
            isSyncing = false
            await startSendReply("Relay auth failed. Check secret token in settings.")
            return
        } catch {
            // Offline or no relay -- use direct API
            session.isOffline = true
            if let client = settings.makeAnthropicClient() {
                do {
                    fullAnswer = try await collect(stream: client.stream(message: query, session: session))
                } catch {
                    isSyncing = false
                    await startSendReply("API error: \(error.localizedDescription)")
                    return
                }
            } else {
                isSyncing = false
                await startSendReply("No API key set. Add key in Settings.")
                return
            }
        }

        isSyncing = false
        session.addUser(query)
        session.addAssistant(fullAnswer)
        session.lastQuery = query
        session.lastAnswer = fullAnswer
        historyStore?.addItem(title: query, content: fullAnswer)
        dynamicText = "\(query)\n\n\(fullAnswer)"
    }

    private func collect(stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var acc = ""
        await sendHudText("Thinking...")
        for try await chunk in stream {
            if !isRunning { break }
            acc.append(chunk)
        }
        let prefix = session.isOffline ? "[OFFLINE] " : ""
        let finalText = prefix + acc
        await startSendReply(finalText)
        return acc
    }

    // MARK: - Display / Pagination

    private func sendHudText(_ text: String) async {
        let l = TextPaginator.measureStringList(text)
        let first5 = Array(l.prefix(5))
        let screen = first5.map { $0 + "\n" }.joined()
        await sendReply(screen, type: 0x01, status: 0x70, pos: 0)
    }

    func startSendReply(_ text: String) async {
        currentLine = 0
        lines = TextPaginator.measureStringList(text)
        if lines.isEmpty { return }

        if lines.count <= 5 {
            let pad = Array(repeating: " \n", count: 5 - lines.count)
            let content = lines.map { $0 + "\n" }
            let screen = (pad + content).joined()
            _ = await sendReply(screen, type: 0x01, status: 0x30, pos: 0)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if isManual { return }
            _ = await sendReply(screen, type: 0x01, status: 0x40, pos: 0)
            return
        }

        let firstScreen = lines.prefix(5).map { $0 + "\n" }.joined()
        if await sendReply(firstScreen, type: 0x01, status: 0x30, pos: 0) {
            currentLine = 0
            startPagingTimer()
        } else {
            clear()
        }
    }

    private func startPagingTimer() {
        pagingTimerTask?.cancel()
        pagingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self = self else { return }
                if self.isManual { return }
                self.currentLine = min(self.currentLine + 5, self.lines.count - 1)
                let tail = Array(self.lines[self.currentLine...])
                if self.currentLine > self.lines.count - 1 { return }
                let take = min(5, tail.count)
                let merged = tail.prefix(take).map { $0 + "\n" }.joined()
                if self.currentLine >= self.lines.count - 5 {
                    _ = await self.sendReply(merged, type: 0x01, status: 0x40, pos: 0)
                    return
                } else {
                    _ = await self.sendReply(merged, type: 0x01, status: 0x30, pos: 0)
                }
            }
        }
    }

    func nextPageByTouchpad() {
        guard isRunning else { return }
        isManual = true
        pagingTimerTask?.cancel(); pagingTimerTask = nil
        if totalPages() < 2 { Task { await manualForJustOnePage() }; return }
        if currentLine + 5 > lines.count - 1 { return }
        currentLine += 5
        Task { await updateManual() }
    }

    func lastPageByTouchpad() {
        guard isRunning else { return }
        isManual = true
        pagingTimerTask?.cancel(); pagingTimerTask = nil
        if totalPages() < 2 { Task { await manualForJustOnePage() }; return }
        currentLine = max(0, currentLine - 5)
        Task { await updateManual() }
    }

    private func updateManual() async {
        guard currentLine >= 0, currentLine <= lines.count - 1 else { return }
        let tail = Array(lines[currentLine...])
        let take = min(5, tail.count)
        let merged = tail.prefix(take).map { $0 + "\n" }.joined()
        _ = await sendReply(merged, type: 0x01, status: 0x50, pos: 0)
    }

    private func manualForJustOnePage() async {
        if lines.count <= 5 {
            let pad = Array(repeating: " \n", count: 5 - lines.count)
            let content = lines.map { $0 + "\n" }
            _ = await sendReply((pad + content).joined(), type: 0x01, status: 0x50, pos: 0)
        }
    }

    func resetSession() {
        session.reset()
        Task { await startSendReply("Session reset") }
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
        isManual = false
        currentLine = 0
        lines = []
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        pagingTimerTask?.cancel(); pagingTimerTask = nil
        silenceTask?.cancel(); silenceTask = nil
        retryCount = 0
    }

    // MARK: - Send helper with retry

    private var retryCount = 0
    @discardableResult
    private func sendReply(_ text: String, type: Int, status: Int, pos: Int) async -> Bool {
        guard isRunning else { return false }
        let newScreen = status | type
        let ok = await proto.sendEvenAIData(text, newScreen: newScreen, pos: pos,
                                             currentPageNum: currentPage(), maxPageNum: totalPages())
        if !ok {
            if retryCount < Self.maxRetry {
                retryCount += 1
                return await sendReply(text, type: type, status: status, pos: pos)
            }
            retryCount = 0
            return false
        }
        retryCount = 0
        return true
    }

    // MARK: - Pagination math

    func totalPages() -> Int {
        if lines.isEmpty { return 0 }
        return (lines.count + 4) / 5
    }

    func currentPage() -> Int {
        return (currentLine / 5) + 1
    }
}
