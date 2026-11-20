import Foundation
import KeptCore

private let base = URL(string: "https://example.test/news/feed.xml")!

private func address(_ item: RemoteItem) -> String? {
    if case .link(let value) = item.content { return value }
    return nil
}

func testFeedParsing() throws {
    let rss = FeedParser(base: base)
    let rssData = Data("""
        <rss version="2.0"><channel><title> Test &amp; News </title>
        <item><title><![CDATA[First <and> second]]></title><guid>stable-1</guid>
        <link>../article</link><pubDate>02 Jan 2024 12:30:00 +0000</pubDate></item>
        <item><guid>https://example.test/permalink</guid></item>
        <item><link>mailto:fixture@example.test</link></item>
        </channel></rss>
        """.utf8)
    try check(rss.parse(rssData) && rss.title == "Test & News", "RSS title and entity decode")
    try check(rss.entries.map(\.key) == ["stable-1", "https://example.test/permalink"], "RSS ID fallback and scheme check")
    try check(rss.entries.first?.title == "First <and> second" && rss.entries.first?.date != nil, "CDATA and RFC date")
    try check(rss.entries.map(address) == ["https://example.test/article", "https://example.test/permalink"],
              "relative URLs and permalink GUID")

    let atom = FeedParser(base: base)
    try check(atom.parse(Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Atom title</title>
        <entry><id>tag:example.test,2024:1</id><title>First</title>
        <link href="audio.mp3" rel="enclosure"/><link href="post" rel="alternate"/><link href="/self" rel="self"/>
        <updated>2024-01-04T12:30:00Z</updated><published>2024-01-02T12:30:00.100Z</published></entry></feed>
        """.utf8)), "Atom feed parsed")
    let entry = try atom.entries.first.unwrap("Atom entry")
    try check(atom.title == "Atom title" && entry.key == "tag:example.test,2024:1", "Atom title and ID")
    try check(address(entry) == "https://example.test/news/post", "Atom prefers alternate URL")
    let timestamp = try entry.date.unwrap("published date").timeIntervalSince1970
    try check(abs(timestamp - 1_704_198_600.1) < 0.001, "fractional published date takes precedence")
    let rdf = FeedParser(base: base)
    try check(rdf.parse(Data("""
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <channel><title>RSS 1</title></channel><item><link>/post</link></item></rdf:RDF>
        """.utf8)) && rdf.entries.count == 1, "RSS 1.0 RDF")
    let partial = FeedParser(base: base)
    try check(partial.parse(Data("<rss><channel><item><link>/valid</link></item><item>".utf8))
              && partial.entries.count == 1, "valid entries retained from malformed feed")
    for invalid in ["", "random", "<html><title>Site</title></html>"] {
        try check(!FeedParser(base: base).parse(Data(invalid.utf8)), "non-feed rejected")
    }
    try check(ConnectorDates.parse("nonsense") == nil && ConnectorDates.parse(" ") == nil, "unparseable dates")
}

func testOpaqueGUID() throws {
    let rss = FeedParser(base: base)
    try check(rss.parse(Data("""
        <rss><channel><item><guid isPermaLink="false">opaque-id</guid></item>
        <item><guid isPermaLink="false">opaque-with-link</guid><link>/linked</link></item>
        <item><guid isPermaLink="true">https://example.test/explicit</guid></item></channel></rss>
        """.utf8)), "RSS feed parsed")
    try check(rss.entries.map(\.key) == ["opaque-with-link", "https://example.test/explicit"],
              "an entry with only a non-permalink GUID is skipped; the GUID still identifies a linked entry")
    try check(rss.entries.map(address) == ["https://example.test/linked", "https://example.test/explicit"],
              "non-permalink GUID is never used as the address")
}

private final class ConnectorServer {
    let baseURL: String
    private let process: Process

    init() throws {
        let script = try ProcessInfo.processInfo.environment["KEPT_TEST_FIXTURE"].unwrap("Run scripts/test.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        var port = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
            port.append(byte)
        }
        guard let number = UInt16(String(decoding: port, as: UTF8.self)), number > 0 else {
            if process.isRunning { process.terminate() }
            throw CheckFailure(description: "Connector fixture did not start")
        }
        self.process = process
        baseURL = "http://127.0.0.1:\(number)"
    }

    deinit {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    var feedValues: [String: String] { ["url": baseURL + "/feed"] }
}

private func expectConnectorError(_ expected: String, _ action: () async throws -> Void) async throws {
    do {
        try await action()
    } catch let error as ConnectorError {
        try check(error.localizedDescription.contains(expected), "expected '\(expected)', got '\(error.localizedDescription)'")
        return
    }
    throw CheckFailure(description: "Expected connector error containing \(expected)")
}

@MainActor
func testConnectors() async throws {
    let server = try ConnectorServer()
    setenv("KEPT_GITHUB_API", server.baseURL, 1)
    setenv("KEPT_RAINDROP_API", server.baseURL, 1)
    let github = GitHubStarsConnector()
    let raindrop = RaindropConnector()
    let feed = FeedConnector()
    try check(ConnectorRegistry.all.map(\.id) == [github.id, raindrop.id, feed.id], "all connectors in settings")
    try check(github.fields.allSatisfy(\.isSecret) && raindrop.fields.allSatisfy(\.isSecret)
              && feed.fields.allSatisfy { !$0.isSecret }, "settings credentials classified correctly")
    let context = ConnectorContext(values: ["token": " fixture-token "], known: [])
    let githubAccount = try await github.verify(context)
    let raindropAccount = try await raindrop.verify(context)
    try check(githubAccount == "@fixture-user" && raindropAccount == "Fixture Account", "account verification")
    let stars = try await github.fetch(context)
    try check(stars.count == 101 && stars.last?.key == "100" && stars.first?.title == "fixture/repo-0: Test star",
              "GitHub pagination and skipped malformed row")
    let bookmarks = try await raindrop.fetch(context)
    try check(bookmarks.count == 51 && bookmarks.last?.key == "50" && bookmarks.first?.title == "Bookmark"
              && bookmarks.last?.title == nil && bookmarks.first?.date != nil, "Raindrop pagination and fallbacks")
    let known = ConnectorContext(values: context.values, known: Set((0..<100).map(String.init)))
    let knownStars = try await github.fetch(known)
    let knownBookmarks = try await raindrop.fetch(known)
    try check(knownStars.count == 100 && knownBookmarks.count == 50, "fully known pages stop pagination")
    for (token, expected) in [("", "Paste"), ("rejected", "rejected"), ("rate-limited", "rate limiting"),
                              ("malformed", "could not read")] {
        let invalid = ConnectorContext(values: ["token": token], known: [])
        try await expectConnectorError(expected) { _ = try await github.verify(invalid) }
        try await expectConnectorError(expected) { _ = try await raindrop.verify(invalid) }
    }
    for (input, expected) in [("file:///tmp/feed", "full web address"), (server.baseURL + "/missing", "Nothing was found"),
                              (server.baseURL + "/unavailable", "503"), (server.baseURL + "/not-feed", "RSS or Atom")] {
        try await expectConnectorError(expected) {
            _ = try await feed.verify(.init(values: ["url": input], known: []))
        }
    }

    let db = try Database(url: scratch("connector-center").appendingPathComponent("test.sqlite"))
    let library = LibraryStore(db: db)
    let center = ConnectorCenter(db: db, library: library)
    try await center.connect(feed, name: "", values: server.feedValues)
    try await eventually("initial feed sync completes") { center.syncing.isEmpty && center.connections.first?.imported == 1 }
    let connection = try center.connections.first.unwrap("stored connection")
    let item = try library.items.first.unwrap("imported article")
    try check(connection.name == "Fixture Feed" && connection.config == server.feedValues
              && connection.lastSync != nil && connection.lastError == nil, "settings and successful sync stored")
    try check(item.text == "https://example.test/article" && item.method == .connector, "article saved")
    center.setEnabled(connection, false)
    center.syncAll()
    try check(center.syncing.isEmpty && center.connections.first?.enabled == false, "paused feed skipped")
    center.setEnabled(try center.connections.first.unwrap("paused connection"), true)
    try await eventually("resumed feed sync completes") { center.syncing.isEmpty }
    try check(library.items.count == 1, "resume does not duplicate article")
    try await center.connect(feed, name: "  New name  ", values: server.feedValues,
                             existing: try center.connections.first.unwrap("connection to edit"))
    try await eventually("edited feed sync completes") { center.syncing.isEmpty }
    try check(center.connections.first?.name == "New name", "name change")
    center.remove(try center.connections.first.unwrap("connection to remove"))
    try check(center.connections.isEmpty && library.items.map(\.id) == [item.id], "removal keeps imported item")

    for connector in [github as any Connector, raindrop as any Connector] {
        try await center.connect(connector, name: "Credential test", values: context.values)
        let added = try center.connections.first.unwrap("token connector added")
        defer { ConnectorSecrets.delete(added.id) }
        try await eventually("token-backed sync \(connector.id)") { center.syncing.isEmpty }
        let synced = try center.connections.first.unwrap("token connector synced")
        try check(synced.lastError == nil && synced.imported > 0 && synced.config.isEmpty,
                  "token sync succeeds without putting the token in SQLite")
        try check(try ConnectorSecrets.load(added.id) == ["token": "fixture-token"], "synthetic token saved in Keychain")

        try await center.connect(connector, name: "Edited token connection", values: [:], existing: synced)
        try await eventually("edited token connection completes") { center.syncing.isEmpty }
        let edited = try center.connections.first.unwrap("edited token connector")
        try check(edited.lastError == nil && edited.imported == synced.imported, "blank token retains sign-in")
        center.remove(edited)
        try check(try ConnectorSecrets.load(edited.id).isEmpty, "removing connector clears its saved sign-in")
    }
}

@MainActor
func testPausedConnectorEdit() async throws {
    let server = try ConnectorServer()
    let db = try Database(url: scratch("paused-connector").appendingPathComponent("test.sqlite"))
    let center = ConnectorCenter(db: db, library: LibraryStore(db: db))
    let feed = FeedConnector()
    try await center.connect(feed, name: "", values: server.feedValues)
    try await eventually("initial sync completes") { center.syncing.isEmpty }
    center.setEnabled(try center.connections.first.unwrap("connection"), false)
    let paused = try center.connections.first.unwrap("paused connection")
    try check(!paused.enabled, "precondition: connector is paused")
    try await center.connect(feed, name: "Renamed", values: server.feedValues, existing: paused)
    try check(center.syncing.isEmpty, "editing a paused connection does not start a sync")
    let edited = try center.connections.first.unwrap("edited connection")
    try check(!edited.enabled && edited.name == "Renamed", "edit is saved and the connection stays paused")
    center.setEnabled(edited, true)
    try await eventually("resumed sync completes") { center.syncing.isEmpty }
    try check(center.connections.first?.enabled == true, "explicit resume still works")
}
