import Foundation

enum RelayError: Error {
    case offline(String)
    case auth
}

/// Streaming client for a local Claude Code relay (POST /query).
/// Ports `lib/services/cowork_relay_service.dart`.
final class CoworkRelayClient {
    private let baseURL: URL
    private let secret: String

    init(baseURL: URL, secret: String) {
        self.baseURL = baseURL
        self.secret = secret
    }

    func stream(message: String, session: ClaudeSession) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var body: [String: Any] = ["message": message]
                if let sid = session.relaySessionId { body["session_id"] = sid }
                guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                    continuation.finish(throwing: RelayError.offline("bad body"))
                    return
                }

                var req = URLRequest(url: self.baseURL.appendingPathComponent("query"))
                req.httpMethod = "POST"
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                if !self.secret.isEmpty {
                    req.setValue("Bearer \(self.secret)", forHTTPHeaderField: "Authorization")
                }
                req.httpBody = bodyData
                req.timeoutInterval = 10

                do {
                    if #available(iOS 15.0, *) {
                        let (bytes, response) = try await URLSession.shared.bytes(for: req)
                        if let http = response as? HTTPURLResponse {
                            if http.statusCode == 401 {
                                continuation.finish(throwing: RelayError.auth); return
                            }
                            if !(200...299).contains(http.statusCode) {
                                continuation.finish(throwing: RelayError.offline("HTTP \(http.statusCode)")); return
                            }
                        }
                        let parser = SSEParser()
                        var bufferData = Data()
                        for try await byte in bytes {
                            bufferData.append(byte)
                            if byte == 0x0a {
                                for event in parser.feed(bufferData) {
                                    if self.handle(event: event, session: session, continuation: continuation) {
                                        continuation.finish(); return
                                    }
                                }
                                bufferData.removeAll(keepingCapacity: true)
                            }
                        }
                        continuation.finish()
                    } else {
                        let (data, response) = try await URLSession.shared.data(for: req)
                        if let http = response as? HTTPURLResponse {
                            if http.statusCode == 401 { continuation.finish(throwing: RelayError.auth); return }
                        }
                        let parser = SSEParser()
                        for event in parser.feed(data) {
                            if self.handle(event: event, session: session, continuation: continuation) {
                                continuation.finish(); return
                            }
                        }
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: RelayError.offline((error as NSError).localizedDescription))
                }
            }
        }
    }

    /// Returns true if streaming should end (type == "done").
    private func handle(event: SSEParser.Event, session: ClaudeSession,
                        continuation: AsyncThrowingStream<String, Error>.Continuation) -> Bool {
        guard !event.data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return false }
        switch type {
        case "text":
            if let t = obj["text"] as? String, !t.isEmpty { continuation.yield(t) }
            return false
        case "done":
            if let sid = obj["session_id"] as? String { session.relaySessionId = sid }
            return true
        case "error":
            let msg = (obj["message"] as? String) ?? "relay error"
            continuation.finish(throwing: NSError(domain: "Relay", code: -1, userInfo: [NSLocalizedDescriptionKey: msg]))
            return true
        default:
            return false
        }
    }
}
