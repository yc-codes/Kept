import Foundation

/// Repositories the signed-in account has starred, saved as links.
struct GitHubStarsConnector: Connector {
    let id = "github-stars"
    let name = "GitHub Stars"
    let icon = KeptIcon.githubLogo
    let summary = "Repositories you star on GitHub, saved as links."
    let fields = [ConnectorField(key: "token", label: "Access token", placeholder: "github_pat_…", isSecret: true)]
    let help: ConnectorHelp? = ConnectorHelp(
        title: "Create a token on GitHub",
        url: URL(string: "https://github.com/settings/personal-access-tokens/new")!,
        note: "A fine-grained token with read-only access to Starring is enough.")

    /// `KEPT_GITHUB_API` points the connector at another server (GitHub Enterprise, or a test double).
    private static let api = ProcessInfo.processInfo.environment["KEPT_GITHUB_API"] ?? "https://api.github.com"
    private static let maxPages = 10

    private func headers(_ context: ConnectorContext, accept: String) -> [String: String] {
        ["Authorization": "Bearer \(context.value("token"))", "Accept": accept, "X-GitHub-Api-Version": "2022-11-28"]
    }

    func verify(_ context: ConnectorContext) async throws -> String? {
        guard !context.value("token").isEmpty else { throw ConnectorError.message("Paste an access token.") }
        let user = try await ConnectorHTTP.json(
            URL(string: Self.api + "/user")!, headers: headers(context, accept: "application/vnd.github+json"))
        return ((user as? [String: Any])?["login"] as? String).map { "@" + $0 }
    }

    func fetch(_ context: ConnectorContext) async throws -> [RemoteItem] {
        var found: [RemoteItem] = []
        for page in 1...Self.maxPages {
            // The star+json media type adds `starred_at` to each entry.
            let url = URL(string: Self.api + "/user/starred?per_page=100&page=\(page)")!
            let reply = try await ConnectorHTTP.json(url, headers: headers(context, accept: "application/vnd.github.star+json"))
            guard let stars = reply as? [[String: Any]] else {
                throw ConnectorError.message("GitHub sent a reply Kept could not read.")
            }
            let items = stars.compactMap(Self.item)
            found += items
            // Newest first: once a whole page is familiar, everything after it is too.
            if stars.count < 100 || items.allSatisfy({ context.isKnown($0.key) }) { break }
        }
        return found
    }

    private static func item(_ star: [String: Any]) -> RemoteItem? {
        let repo = star["repo"] as? [String: Any] ?? star
        guard let link = repo["html_url"] as? String, let fullName = repo["full_name"] as? String else { return nil }
        let about = (repo["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = (repo["id"] as? NSNumber).map { $0.stringValue } ?? link
        return RemoteItem(
            key: key, content: .link(link), title: about.isEmpty ? fullName : "\(fullName): \(about)",
            date: ConnectorDates.parse(star["starred_at"] as? String))
    }
}
