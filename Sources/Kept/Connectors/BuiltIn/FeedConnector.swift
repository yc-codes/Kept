import Foundation

/// Entries from an RSS or Atom feed, saved as links. Needs no sign-in.
struct FeedConnector: Connector {
    let id = "feed"
    let name = "RSS or Atom Feed"
    let icon = KeptIcon.rss
    let summary = "New entries from a feed, saved as links. No sign-in needed."
    let fields = [ConnectorField(key: "url", label: "Feed address", placeholder: "https://example.com/feed.xml")]
    let help: ConnectorHelp? = nil

    /// A feed is best known by its own title.
    func defaultName(account: String?) -> String { account ?? name }

    private func load(_ context: ConnectorContext) async throws -> FeedParser {
        let address = context.value("url")
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else { throw ConnectorError.message("Enter the feed's full web address, starting with https://.") }
        let data = try await ConnectorHTTP.get(
            url, headers: ["Accept": "application/atom+xml, application/rss+xml, application/xml;q=0.9, */*;q=0.5"])
        let feed = FeedParser(base: url)
        guard feed.parse(data) else {
            throw ConnectorError.message("That address did not return an RSS or Atom feed.")
        }
        return feed
    }

    func verify(_ context: ConnectorContext) async throws -> String? {
        let feed = try await load(context)
        return feed.title.isEmpty ? URL(string: context.value("url"))?.host : feed.title
    }

    func fetch(_ context: ConnectorContext) async throws -> [RemoteItem] {
        try await load(context).entries
    }
}

/// Reads the handful of RSS 2.0 / RSS 1.0 / Atom elements Kept needs: feed title, and each entry's link,
/// title, identifier and date.
final class FeedParser: NSObject, XMLParserDelegate {
    private(set) var title = ""
    private(set) var entries: [RemoteItem] = []

    private let base: URL
    private var isFeed = false
    private var depth = 0
    /// Depth of the `<item>` / `<entry>` being read, or nil outside one.
    private var entryDepth: Int?
    private var text = ""
    private var fields: [String: String] = [:]
    /// RSS: false when the entry's `<guid>` says `isPermaLink="false"`, making it an identifier only.
    private var guidIsPermalink = true

    init(base: URL) { self.base = base }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // Malformed feeds are common; keep whatever was read before the error.
        parser.parse()
        return isFeed
    }

    func parser(
        _ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        depth += 1
        text = ""
        let name = element.lowercased()
        if depth == 1 { isFeed = ["rss", "feed", "rdf:rdf"].contains(name) }
        guard isFeed else { return }
        if entryDepth == nil, name == "item" || name == "entry" {
            entryDepth = depth
            fields = [:]
            guidIsPermalink = true
        } else if name == "link", let entryDepth, depth == entryDepth + 1, let href = attributes["href"] {
            // Atom: prefer the page itself over feeds, comments and enclosures.
            let relation = attributes["rel"] ?? "alternate"
            if relation == "alternate" || fields["link"] == nil { fields["link"] = href }
        } else if name == "guid", let entryDepth, depth == entryDepth + 1 {
            let flag = attributes.first { $0.key.lowercased() == "ispermalink" }?.value
            guidIsPermalink = flag?.trimmingCharacters(in: .whitespaces).lowercased() != "false"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        text += String(decoding: block, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        guard isFeed else { return }
        let name = element.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""

        guard let entryDepth else {
            // The feed's own title sits directly under <channel> (depth 3) or <feed> (depth 2).
            if name == "title", title.isEmpty, depth <= 3 { title = value }
            return
        }
        if depth == entryDepth {
            finishEntry()
            self.entryDepth = nil
        } else if depth == entryDepth + 1, !value.isEmpty {
            switch name {
            case "title", "guid", "id": fields[name] = value
            case "link": if fields["link"] == nil { fields["link"] = value }
            case "pubdate", "published", "dc:date": fields["date"] = value
            case "updated": if fields["date"] == nil { fields["date"] = value }
            default: break
            }
        }
    }

    private func finishEntry() {
        // Some feeds carry the address only in a permalink <guid>. One marked as not a permalink is an
        // opaque identifier, never an address.
        let address = fields["link"] ?? (guidIsPermalink ? fields["guid"] : nil) ?? ""
        guard let url = URL(string: address, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return }
        entries.append(RemoteItem(
            key: fields["guid"] ?? fields["id"] ?? url.absoluteString, content: .link(url.absoluteString),
            title: fields["title"], date: ConnectorDates.parse(fields["date"])))
    }
}
