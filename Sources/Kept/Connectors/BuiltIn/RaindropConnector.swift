import Foundation

/// Bookmarks from a Raindrop.io account, saved as links.
struct RaindropConnector: Connector {
    let id = "raindrop"
    let name = "Raindrop.io"
    let icon = KeptIcon.drop
    let summary = "Bookmarks from your Raindrop.io collections, saved as links."
    let fields = [ConnectorField(key: "token", label: "Test token", placeholder: "Paste the token", isSecret: true)]
    let help: ConnectorHelp? = ConnectorHelp(
        title: "Open Raindrop.io integrations",
        url: URL(string: "https://app.raindrop.io/settings/integrations")!,
        note: "Create an app under \u{201C}For Developers\u{201D}, open it, and choose \u{201C}Create test token\u{201D}.")

    private static let api = ProcessInfo.processInfo.environment["KEPT_RAINDROP_API"] ?? "https://api.raindrop.io"
    private static let maxPages = 20

    private func headers(_ context: ConnectorContext) -> [String: String] {
        ["Authorization": "Bearer \(context.value("token"))"]
    }

    func verify(_ context: ConnectorContext) async throws -> String? {
        guard !context.value("token").isEmpty else { throw ConnectorError.message("Paste a test token.") }
        let reply = try await ConnectorHTTP.json(URL(string: Self.api + "/rest/v1/user")!, headers: headers(context))
        let user = (reply as? [String: Any])?["user"] as? [String: Any]
        return (user?["fullName"] as? String) ?? (user?["email"] as? String)
    }

    func fetch(_ context: ConnectorContext) async throws -> [RemoteItem] {
        var found: [RemoteItem] = []
        for page in 0..<Self.maxPages {
            // Collection 0 is "all bookmarks".
            let url = URL(string: Self.api + "/rest/v1/raindrops/0?perpage=50&sort=-created&page=\(page)")!
            let reply = try await ConnectorHTTP.json(url, headers: headers(context))
            guard let drops = (reply as? [String: Any])?["items"] as? [[String: Any]] else {
                throw ConnectorError.message("Raindrop.io sent a reply Kept could not read.")
            }
            let items = drops.compactMap { drop -> RemoteItem? in
                guard let link = drop["link"] as? String else { return nil }
                let title = (drop["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return RemoteItem(
                    key: (drop["_id"] as? NSNumber).map { $0.stringValue } ?? link, content: .link(link),
                    title: title?.isEmpty == false ? title : nil,
                    date: ConnectorDates.parse(drop["created"] as? String))
            }
            found += items
            if drops.count < 50 || items.allSatisfy({ context.isKnown($0.key) }) { break }
        }
        return found
    }
}
