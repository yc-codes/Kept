import Foundation
import KeptCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String,
           file: StaticString = #fileID, line: UInt = #line) throws {
    if try !condition() { throw CheckFailure(description: "\(file):\(line): \(message)") }
}

func checkThrows(_ message: String, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch {
        return
    }
    throw CheckFailure(description: message)
}

func scratch(_ name: String) throws -> URL {
    let directory = KeptPaths.root.appendingPathComponent(name + "-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
func eventually(_ message: String, timeout: Duration = .seconds(8),
                _ condition: () throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    repeat {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    } while clock.now < deadline
    throw CheckFailure(description: message)
}

struct TestRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func index(_ upperBound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(upperBound))
    }
}

@main
enum TestRunner {
    @MainActor
    static func main() async throws {
        if try await run() > 0 { exit(1) }
    }

    @MainActor
    private static func run() async throws -> Int {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kept-tests-" + UUID().uuidString)
        setenv("KEPT_HOME", directory.path, 1)
        try KeptPaths.ensure()
        defer { try? FileManager.default.removeItem(at: directory) }

        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("capture settings and all source combinations", { try testCaptureSettings() }),
            ("shortcut recording input and modifiers", { try testShortcuts() }),
            ("clipboard types, privacy markers and size boundaries", { try testClipboard() }),
            ("passive clipboard monitoring, exclusions and pause", testClipboardMonitor),
            ("library import, search, editing, copy, preview and delete", testLibrary),
            ("image OCR flows into the active library search", testImageOCR),
            ("deep links and search reach older items past the library limit", { try testOlderItemLink() }),
            ("SQLite search, filters, deduplication and read-only handles", { try testDatabase() }),
            ("SQLite migration retains existing data and search", { try testMigration() }),
            ("SQLite concurrent deduplication and independent readers", testConcurrentWrites),
            ("connector persistence, rollback and replay protection", { try testConnections() }),
            ("RSS, RDF, Atom and connector date parsing", { try testFeedParsing() }),
            ("HTTP connectors and settings lifecycle against a local server", testConnectors),
            ("MCP stdio tools, read-only behavior and malformed messages", { try testMCP() }),
            ("agent connections through command-line tools and settings files", testAgentConnections),
            ("seeded monkey testing of storage and search", testMonkey),
            ("seeded monkey testing of app-level library actions", testStoreMonkey),
            ("RSS GUID marked as a non-permalink is never used as a URL", { try testOpaqueGUID() }),
            ("search containing an embedded NUL", { try testNULSearch() }),
            ("editing a title or note refreshes the active search", testSearchAfterEdit),
            ("editing a paused feed connection keeps it paused", testPausedConnectorEdit),
            ("signature-only image payloads are rejected", testTruncatedImages),
            ("sideways photos import upright and unreadable files are reported", testRotatedPhotoImport),
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try await test()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name) — \(error)")
            }
        }

        print("\(tests.count) suites, \(failures) failures")
        return failures
    }
}
