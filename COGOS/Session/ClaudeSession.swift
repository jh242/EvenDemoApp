import Foundation

/// Persistent conversation context. Ports `lib/models/claude_session.dart`.
final class ClaudeSession {
    static let maxTurns = 20

    struct Message {
        let role: String  // "user" or "assistant"
        let content: String
    }

    var messages: [Message] = []
    var relaySessionId: String?
    var isOffline = false
    var lastQuery: String?
    var lastAnswer: String?

    func addUser(_ text: String) { messages.append(.init(role: "user", content: text)) }
    func addAssistant(_ text: String) { messages.append(.init(role: "assistant", content: text)) }

    func reset() {
        messages.removeAll()
        relaySessionId = nil
        isOffline = false
        lastQuery = nil
        lastAnswer = nil
    }
}
