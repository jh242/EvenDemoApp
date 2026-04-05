import Foundation

struct NewsSource: GlanceSource {
    let name = "news"
    var enabled = true
    var cacheDuration: TimeInterval = 1800

    let settings: Settings

    func fetch() async -> String? {
        let apiKey = await MainActor.run { settings.resolvedNewsKey }
        guard !apiKey.isEmpty else { return nil }

        guard let url = URL(string: "https://newsapi.org/v2/top-headlines?country=us&pageSize=3&apiKey=\(apiKey)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let articles = obj["articles"] as? [[String: Any]], !articles.isEmpty else { return nil }

        let headlines = articles.prefix(3).map { "- \($0["title"] as? String ?? "Untitled")" }
        return "News:\n\(headlines.joined(separator: "\n"))"
    }
}
