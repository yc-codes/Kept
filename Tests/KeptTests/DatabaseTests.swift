import Foundation
import KeptCore

func testDatabase() throws {
    let url = try scratch("db").appendingPathComponent("library.sqlite")
    let db = try Database(url: url)
    let earlier = Date(timeIntervalSince1970: 100)
    let later = Date(timeIntervalSince1970: 200)
    let snip = Item(kind: .image, method: .snip, createdAt: earlier, title: "Café menu",
                    assetName: "sample.png", width: 20, height: 10, hash: "snip", aiDescription: "chalkboard")
    let link = Item(kind: .link, method: .connector, createdAt: later, title: "A link",
                    text: "https://example.test/kiln", sourceApp: "Fixture", hash: "link", favorite: true, ocrDone: true)
    let text = Item(kind: .text, method: .clipboard, createdAt: later, title: "Text",
                    text: "保存\0résumé", sourceBundleID: "app.example", hash: "text", ocrDone: true)
    try check(try db.items().isEmpty && db.counts().values.allSatisfy { $0 == 0 }, "empty library")
    for item in [snip, link, text] {
        try check(try db.insert(item) && db.item(id: item.id) == item && db.item(hash: item.hash) == item,
                  "round-trip \(item.kind)")
    }
    var duplicate = snip
    duplicate.id = Item.newID()
    try check(try !db.insert(duplicate), "duplicate content under a different ID")
    try check(try db.items(limit: 2).map(\.id) == [text.id, link.id], "newest first and stable tie order")
    let filters: [(ItemFilter, [Item])] = [
        (.all, [text, link, snip]), (.snips, [snip]), (.images, [snip]),
        (.links, [link]), (.text, [text]), (.favorites, [link]),
    ]
    for (filter, expected) in filters {
        try check(try db.items(filter: filter) == expected && db.counts()[filter] == expected.count,
                  "filter and count for \(filter)")
    }
    for (query, expected) in [("CAFE men", snip), ("chalk", snip), ("kiln", link), ("保存", text), ("resume", text)] {
        let hits = try db.hits(search: query)
        try check(hits.map(\.item) == [expected] && hits[0].excerpt.contains("["), "FTS match for \(query)")
    }
    for query in ["***", "🙃", "cafe kiln", "\" OR * NEAR("] {
        try check(try db.items(search: query).isEmpty, "search handles \(query)")
    }
    try check(try db.items(search: " \n ").count == 3, "blank search lists items")
    try check(try db.pendingOCR() == [snip], "pending OCR")
    try db.setTitle(id: snip.id, title: "Coffee poster")
    try db.setNote(id: snip.id, note: "Morning special")
    try db.setOCR(id: snip.id, text: "Espresso and pastry")
    try db.setFavorite(id: snip.id, favorite: true)
    let readOnly = try Database(url: url, readOnly: true)
    try check(try readOnly.items(search: "cafe").isEmpty && readOnly.pendingOCR().isEmpty,
              "FTS removed previous title and OCR marked complete")
    let combined = try readOnly.items(filter: .favorites, search: "coff morn espr")
    try check(combined.map(\.id) == [snip.id] && combined.first?.ocrDone == true, "FTS joins updated fields")
    try checkThrows("read-only handle unexpectedly mutated a row") { try readOnly.delete(id: snip.id) }
    try db.delete(id: snip.id)
    try check(try readOnly.items(search: "espresso").isEmpty && readOnly.item(id: snip.id) == nil, "delete updates FTS")
    try checkThrows("read-only open unexpectedly created a library") {
        _ = try Database(url: url.deletingLastPathComponent().appendingPathComponent("missing"), readOnly: true)
    }
}

func testConcurrentWrites() async throws {
    let url = try scratch("concurrent").appendingPathComponent("test.sqlite")
    let writer = try Database(url: url)
    let second = try Database(url: url)
    let reader = try Database(url: url, readOnly: true)
    let inserted = try await withThrowingTaskGroup(of: Bool.self, returning: Int.self) { group in
        for index in 0..<128 {
            let db = index.isMultiple(of: 2) ? writer : second
            group.addTask {
                let hash = "collision-\(index % 13)"
                let item = Item(kind: .text, method: .manual, title: "concurrent", hash: hash)
                let added = try db.insert(item)
                _ = try reader.hits(search: "concur")
                return added
            }
        }
        var inserted = 0
        for try await added in group where added { inserted += 1 }
        return inserted
    }
    try check(inserted == 13, "each unique hash inserted once across writers")
    try check(try reader.items(search: "concur").count == 13 && reader.counts()[.all] == 13, "index agrees with rows")
}

func testConnections() throws {
    let db = try Database(url: scratch("connections").appendingPathComponent("test.sqlite"))
    var first = Connection(typeID: "feed", name: "Feed", config: ["url": "https://example.test/feed"],
                           createdAt: Date(timeIntervalSince1970: 1))
    let second = Connection(typeID: "feed", name: "Second", createdAt: Date(timeIntervalSince1970: 2))
    try db.saveConnection(first)
    try db.saveConnection(second)
    try check(try db.connections() == [first, second], "connections round-trip")
    let manual = Item(kind: .link, method: .manual, createdAt: Date(timeIntervalSince1970: 10),
                      title: "Manual", hash: "existing")
    let imported = Item(kind: .link, method: .connector, title: "External", hash: "external")
    try db.insert(manual)
    let entries = [(key: "existing", item: manual), (key: "remote", item: imported)]
    try check(try db.importItems(entries + entries, connection: first.id) == 1, "hash and key deduplication")
    try check(try db.seenKeys(connection: first.id) == Set(["existing", "remote"]), "seen remembers duplicates too")
    try check(try db.importItems(entries, connection: second.id) == 0, "dedupe across connections")
    let date = Date(timeIntervalSince1970: 1234)
    try db.setSyncResult(connection: first.id, at: date, error: "Temporary failure")
    first.name = "Renamed feed"
    first.enabled = false
    try db.saveConnection(first)
    let edited = try db.connections().first.unwrap("first connection")
    try check(edited.name == first.name && !edited.enabled && edited.imported == 1
              && edited.lastSync == date && edited.lastError == "Temporary failure", "edit preserves sync metadata")
    try db.delete(id: imported.id)
    try check(try db.importItems(entries, connection: first.id) == 0 && db.item(id: imported.id) == nil,
              "deleting a synced item does not re-import it")
    try db.deleteConnection(id: first.id)
    try check(try db.seenKeys(connection: first.id).isEmpty && db.item(id: manual.id) == manual,
              "remove forgets sync keys and keeps library")
    let late = Item(kind: .link, method: .connector, title: "Late", hash: "late")
    try checkThrows("in-flight sync unexpectedly imported after removal") {
        try db.importItems([(key: "late", item: late)], connection: first.id)
    }
    try check(try db.item(id: late.id) == nil && db.seenKeys(connection: first.id).isEmpty,
              "invalid connection rolls back")
    try check(try db.importItems([(key: "late", item: late)], connection: second.id) == 1,
              "subsequent import can commit")
}

func testMonkey() async throws {
    let environment = ProcessInfo.processInfo.environment
    let defaultSeeds: [UInt64] = [1, 42, 7741, 93827, 123456789, 4294967295]
    let seeds = if let override = environment["KEPT_TEST_SEED"] {
        [try UInt64(override).unwrap("KEPT_TEST_SEED must be an unsigned integer")]
    } else { defaultSeeds }
    let steps = 600
    let words = ["aurora", "beacon", "cobalt", "dune", "ember", "fern", "granite"]
    let weird = ["", " \\ ", "😀", "*()\" NEAR", "保存", "Café", "🧑🏽‍🚀"]
    let methods: [CaptureMethod] = [.manual, .clipboard, .snip, .connector]

    for seed in seeds {
        let url = try scratch("seed-\(seed)").appendingPathComponent("monkey.sqlite")
        var db = try Database(url: url)
        var rng = TestRandom(seed: seed)
        var model: [Item] = []
        for step in 0..<steps {
            let index = model.isEmpty ? 0 : rng.index(model.count)
            let word = words[rng.index(words.count)]
            let description = "seed \(seed) step \(step)"
            switch rng.index(10) {
            case 0...2:
                let kind = ItemKind.allCases[rng.index(ItemKind.allCases.count)]
                let hash = "hash-\(rng.index(40))"
                let item = Item(id: "test-\(step)", kind: kind, method: methods[rng.index(methods.count)],
                                createdAt: Date(timeIntervalSince1970: Double(step)), title: word, hash: hash)
                let shouldInsert = !model.contains { $0.hash == hash }
                try check(try db.insert(item) == shouldInsert, "insert/dedupe \(description)")
                if shouldInsert { model.insert(item, at: 0) }
            case 3 where !model.isEmpty:
                try db.delete(id: model.remove(at: index).id)
            case 4 where !model.isEmpty:
                model[index].favorite.toggle()
                try db.setFavorite(id: model[index].id, favorite: model[index].favorite)
            case 5 where !model.isEmpty:
                model[index].title = word
                try db.setTitle(id: model[index].id, title: word)
            case 6 where !model.isEmpty:
                model[index].note = word
                try db.setNote(id: model[index].id, note: word)
            case 7 where !model.isEmpty:
                model[index].ocrText = word
                model[index].ocrDone = true
                try db.setOCR(id: model[index].id, text: word)
            case 8:
                db = try Database(url: url)
            default:
                _ = try db.items(search: weird[rng.index(weird.count)])
            }
            let expected: (ItemFilter) -> [Item] = { filter in
                switch filter {
                case .all: return model
                case .snips: return model.filter { $0.method == .snip }
                case .images: return model.filter { $0.kind == .image }
                case .links: return model.filter { $0.kind == .link }
                case .text: return model.filter { $0.kind == .text }
                case .favorites: return model.filter(\.favorite)
                }
            }
            let filter = ItemFilter.allCases[rng.index(ItemFilter.allCases.count)]
            let filtered = expected(filter)
            let counts = try db.counts()
            for kind in ItemFilter.allCases {
                try check(counts[kind] == expected(kind).count, "counts \(kind) \(description)")
            }
            try check(try db.items(filter: filter) == filtered, "rows \(filter) \(description)")
            let expectedIDs = Set(filtered.filter { [$0.title, $0.note, $0.ocrText].contains(word) }.map(\.id))
            let observedIDs = Set(try db.items(filter: filter, search: String(word.prefix(3))).map(\.id))
            try check(observedIDs == expectedIDs, "FTS \(filter), \(word), \(description)")
        }
    }
    print("  \(seeds.count * steps) operations across seeds \(seeds)")
}

func testNULSearch() throws {
    let db = try Database(url: scratch("nul-search").appendingPathComponent("test.sqlite"))
    let item = Item(kind: .text, method: .manual, title: "nul byte", hash: "nul-byte")
    try db.insert(item)
    try check(try db.items(search: "nul\0byte").map(\.id) == [item.id], "NUL separates search terms")
    try check(try db.items(search: "nul\0").map(\.id) == [item.id], "trailing NUL is ignored")
    try check(try db.items(search: "\0").isEmpty, "a query of only NUL matches nothing")
}

func testMigration() throws {
    let url = try scratch("migration").appendingPathComponent("version-one.sqlite")
    let item = Item(kind: .text, method: .manual, createdAt: Date(timeIntervalSince1970: 100),
                    title: "Existing fixture", hash: "v1-fixture", note: "Archive")
    let db = try Database(url: url)
    try db.insert(item)

    // Recreate a v1 library by removing the tables added in v2.
    let sqlite = Process()
    sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    sqlite.arguments = [url.path, "DROP TABLE connection_seen; DROP TABLE connections; PRAGMA user_version=1;"]
    try sqlite.run()
    sqlite.waitUntilExit()
    try check(sqlite.terminationStatus == 0, "construct v1 fixture")
    let migrated = try Database(url: url)
    try check(try migrated.items(search: "archive") == [item], "existing data and index survive migration")
    try check(try migrated.connections().isEmpty, "v2 connector table starts empty")
    let connector = Connection(typeID: "feed", name: "After migration")
    try migrated.saveConnection(connector)
    try check(try migrated.connections().map(\.id) == [connector.id], "migrated library supports connectors")
}
