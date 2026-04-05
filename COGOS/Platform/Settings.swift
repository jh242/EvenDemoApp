import Foundation
import Combine

/// UserDefaults-backed app settings (replaces SharedPreferences).
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var anthropicAPIKey: String { didSet { defaults.set(anthropicAPIKey, forKey: "anthropic_api_key") } }
    @Published var relayURL: String { didSet { defaults.set(relayURL, forKey: "relay_url") } }
    @Published var relaySecret: String { didSet { defaults.set(relaySecret, forKey: "relay_secret") } }
    @Published var openweatherAPIKey: String { didSet { defaults.set(openweatherAPIKey, forKey: "openweather_api_key") } }
    @Published var newsAPIKey: String { didSet { defaults.set(newsAPIKey, forKey: "news_api_key") } }
    @Published var silenceThreshold: Int { didSet { defaults.set(silenceThreshold, forKey: "silence_threshold") } }
    @Published var headUpAngle: Int { didSet { defaults.set(headUpAngle, forKey: "head_up_angle") } }

    init() {
        self.anthropicAPIKey = defaults.string(forKey: "anthropic_api_key") ?? ""
        self.relayURL = defaults.string(forKey: "relay_url") ?? "http://localhost:9090"
        self.relaySecret = defaults.string(forKey: "relay_secret") ?? ""
        self.openweatherAPIKey = defaults.string(forKey: "openweather_api_key") ?? ""
        self.newsAPIKey = defaults.string(forKey: "news_api_key") ?? ""
        self.silenceThreshold = defaults.object(forKey: "silence_threshold") as? Int ?? 2
        self.headUpAngle = defaults.object(forKey: "head_up_angle") as? Int ?? 30
    }

    /// Resolved API key: prefers compile-time env, falls back to stored value.
    var resolvedAnthropicKey: String {
        let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        return env.isEmpty ? anthropicAPIKey.trimmingCharacters(in: .whitespaces) : env
    }

    var resolvedOpenweatherKey: String {
        let env = ProcessInfo.processInfo.environment["OPENWEATHER_API_KEY"] ?? ""
        return env.isEmpty ? openweatherAPIKey.trimmingCharacters(in: .whitespaces) : env
    }

    var resolvedNewsKey: String {
        let env = ProcessInfo.processInfo.environment["NEWS_API_KEY"] ?? ""
        return env.isEmpty ? newsAPIKey.trimmingCharacters(in: .whitespaces) : env
    }

    func makeAnthropicClient() -> AnthropicClient? {
        let k = resolvedAnthropicKey
        return k.isEmpty ? nil : AnthropicClient(apiKey: k)
    }

    func makeHaikuClient() -> HaikuClient? {
        let k = resolvedAnthropicKey
        return k.isEmpty ? nil : HaikuClient(apiKey: k)
    }

    func makeRelayClient() -> CoworkRelayClient? {
        guard let url = URL(string: relayURL) else { return nil }
        return CoworkRelayClient(baseURL: url, secret: relaySecret)
    }
}
