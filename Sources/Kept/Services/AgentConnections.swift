import Foundation
import KeptCore

// Connecting agents to Kept's MCP server without the user copying a path around.
//
// The server lives inside the app bundle, so its path differs on every Mac and changes when the app is
// moved. Kept keeps a link to it at a fixed place in the library folder and registers that link with each
// agent, so the same setup works everywhere and keeps working after the app moves.

/// The link agents run: `~/Library/Application Support/Kept/kept-mcp`.
enum AgentLauncher {
    static var url: URL { KeptPaths.root.appendingPathComponent("kept-mcp") }

    /// The server that ships beside the app's own executable.
    static var bundledServer: URL? {
        guard let server = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("kept-mcp"),
              FileManager.default.isExecutableFile(atPath: server.path) else { return nil }
        return server
    }

    /// macOS runs an app opened straight from a download out of a temporary, randomly named folder. A link
    /// into it would stop working as soon as the app quits.
    static func isTemporaryLocation(_ server: URL) -> Bool {
        server.path.contains("/AppTranslocation/")
    }

    /// Points the link at `server`. Returns whether the link is usable afterwards.
    @discardableResult
    static func refresh(server: URL? = bundledServer, at link: URL = url) -> Bool {
        let files = FileManager.default
        guard let server, !isTemporaryLocation(server) else {
            return files.isExecutableFile(atPath: link.path)
        }
        if (try? files.destinationOfSymbolicLink(atPath: link.path)) == server.path { return true }
        // Build the new link beside the old one and rename it into place, so an agent starting the server
        // at this moment finds either the old link or the new one.
        let fresh = link.deletingLastPathComponent().appendingPathComponent(".kept-mcp-" + UUID().uuidString)
        do {
            try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createSymbolicLink(at: fresh, withDestinationURL: server)
            guard rename(fresh.path, link.path) == 0 else {
                try? files.removeItem(at: fresh)
                return false
            }
            return true
        } catch {
            return false
        }
    }
}

enum AgentClient: String, CaseIterable, Identifiable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case cursor
    case claudeDesktop = "claude-desktop"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .claudeDesktop: return "Claude Desktop"
        }
    }

    /// The command-line tool that registers a server, for agents that have one.
    var tool: String? {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .cursor, .claudeDesktop: return nil
        }
    }
}

enum AgentStatus: Equatable, Sendable {
    /// Nothing on this Mac suggests the agent is installed.
    case notInstalled
    case notConnected
    case connected
    /// Registered, but with a path where there is no server any more.
    case broken
}

enum AgentError: LocalizedError, Equatable {
    case toolNotFound(String)
    case toolFailed(String)
    case unreadableSettings(String)
    case noServer

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "Kept could not find the \(tool) command. Copy the setup command and run it in your terminal."
        case .toolFailed(let output):
            return output.isEmpty ? "The agent did not accept the change." : output
        case .unreadableSettings(let path):
            return "Kept left \(path) alone because it could not read it as JSON."
        case .noServer:
            return "This copy of Kept has no server to connect. Move Kept to your Applications folder and reopen it."
        }
    }
}

/// Reads and changes each agent's list of MCP servers. Everything here blocks, so call it off the main thread.
struct AgentLinker: Sendable {
    /// The name agents know the server by.
    static let serverName = "kept"

    var home: URL
    var environment: [String: String]
    /// Folders searched, in order, for `claude` and `codex`.
    var searchPath: [String]
    var launcher: URL

    /// The linker for this Mac. Asks the user's shell for its PATH, which can take a moment.
    static func live() -> AgentLinker {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        return AgentLinker(
            home: home, environment: environment,
            searchPath: shellSearchPath(home: home, environment: environment), launcher: AgentLauncher.url)
    }

    // MARK: Where each agent keeps its settings

    func settingsFile(for client: AgentClient) -> URL {
        switch client {
        case .claudeCode:
            let folder = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home
            return folder.appendingPathComponent(".claude.json")
        case .codex:
            let folder = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            return folder.appendingPathComponent("config.toml")
        case .cursor:
            return home.appendingPathComponent(".cursor/mcp.json")
        case .claudeDesktop:
            return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        }
    }

    func toolURL(for client: AgentClient) -> URL? {
        guard let tool = client.tool else { return nil }
        return searchPath.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func isInstalled(_ client: AgentClient) -> Bool {
        let files = FileManager.default
        switch client {
        case .claudeCode:
            return toolURL(for: client) != nil || files.fileExists(atPath: settingsFile(for: client).path)
        case .codex, .cursor, .claudeDesktop:
            return toolURL(for: client) != nil
                || files.fileExists(atPath: settingsFile(for: client).deletingLastPathComponent().path)
        }
    }

    // MARK: Status

    /// The command the agent has on record for Kept, if any.
    func registeredCommand(for client: AgentClient) -> String? {
        let file = settingsFile(for: client)
        switch client {
        case .codex:
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return Self.codexCommand(in: text)
        case .claudeCode, .cursor, .claudeDesktop:
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any],
                  let entry = servers[Self.serverName] as? [String: Any] else { return nil }
            return entry["command"] as? String
        }
    }

    func status(of client: AgentClient) -> AgentStatus {
        if let command = registeredCommand(for: client) {
            return FileManager.default.isExecutableFile(atPath: command) ? .connected : .broken
        }
        return isInstalled(client) ? .notConnected : .notInstalled
    }

    /// The command to paste into a terminal, for agents set up that way. The same on every Mac when the
    /// library is in its usual place.
    func setupCommand(for client: AgentClient) -> String? {
        var path = launcher.path
        if path.hasPrefix(home.path + "/") { path = "$HOME" + path.dropFirst(home.path.count) }
        switch client {
        case .claudeCode: return "claude mcp add --scope user \(Self.serverName) -- \"\(path)\""
        case .codex: return "codex mcp add \(Self.serverName) -- \"\(path)\""
        case .cursor, .claudeDesktop: return nil
        }
    }

    // MARK: Connecting

    func connect(_ client: AgentClient) throws {
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else { throw AgentError.noServer }
        switch client {
        case .claudeCode:
            let tool = try requireTool(client)
            // `claude mcp add` refuses to replace an entry, so drop any earlier one first.
            _ = try? run(tool, ["mcp", "remove", "--scope", "user", Self.serverName])
            try run(tool, ["mcp", "add", "--scope", "user", Self.serverName, "--", launcher.path])
        case .codex:
            try run(try requireTool(client), ["mcp", "add", Self.serverName, "--", launcher.path])
        case .cursor, .claudeDesktop:
            try editServers(in: settingsFile(for: client)) { servers in
                servers[Self.serverName] = ["command": launcher.path, "args": [String]()] as [String: Any]
            }
        }
    }

    func disconnect(_ client: AgentClient) throws {
        switch client {
        case .claudeCode:
            try run(try requireTool(client), ["mcp", "remove", "--scope", "user", Self.serverName])
        case .codex:
            try run(try requireTool(client), ["mcp", "remove", Self.serverName])
        case .cursor, .claudeDesktop:
            try editServers(in: settingsFile(for: client)) { $0[Self.serverName] = nil }
        }
    }

    private func requireTool(_ client: AgentClient) throws -> URL {
        guard let tool = toolURL(for: client) else { throw AgentError.toolNotFound(client.tool ?? client.name) }
        return tool
    }

    /// Runs an agent's command-line tool and throws its last line of output when it fails.
    @discardableResult
    private func run(_ tool: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        var environment = environment
        // Tools installed through Node find `node` on the same PATH they were found on.
        environment["PATH"] = searchPath.joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw AgentError.toolFailed("\(tool.lastPathComponent) could not be started.")
        }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let lastLine = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw AgentError.toolFailed(lastLine)
        }
        return text
    }

    /// Changes the `mcpServers` object in a JSON settings file, leaving everything else as it was. A file
    /// that exists but is not a JSON object is left untouched.
    private func editServers(in file: URL, _ change: (inout [String: Any]) -> Void) throws {
        let files = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
           !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentError.unreadableSettings(file.path)
            }
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        change(&servers)
        root["mcpServers"] = servers

        let permissions = (try? files.attributesOfItem(atPath: file.path))?[.posixPermissions]
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((Self.json(root) + "\n").utf8).write(to: file, options: .atomic)
        if let permissions { try? files.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
    }

    // MARK: Formats

    /// JSON laid out the way these settings files are written by hand: two-space indent, `"key": value`.
    static func json(_ value: Any, indent: String = "") -> String {
        let inner = indent + "  "
        if let object = value as? [String: Any] {
            if object.isEmpty { return "{}" }
            let lines = object.keys.sorted().map { "\(inner)\(json($0)): \(json(object[$0]!, indent: inner))" }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(indent)}"
        }
        if let array = value as? [Any] {
            if array.isEmpty { return "[]" }
            return "[\n" + array.map { inner + json($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        }
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// The `command` of `[mcp_servers.kept]` in Codex's config.toml, as `codex mcp add` writes it.
    static func codexCommand(in toml: String) -> String? {
        var inTable = false
        for raw in toml.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inTable = line.hasPrefix("[mcp_servers.\(serverName)]") || line.hasPrefix("[mcp_servers.\"\(serverName)\"]")
                continue
            }
            guard inTable, let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == "command" else { continue }
            return tomlString(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// A TOML string at the start of `text`: "basic" with escapes, or 'literal'.
    private static func tomlString(_ text: String) -> String? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        var end = text.index(after: text.startIndex)
        while end < text.endIndex, text[end] != quote {
            // A backslash escapes the next character in a basic string.
            if quote == "\"", text[end] == "\\" { end = text.index(after: end) }
            if end < text.endIndex { end = text.index(after: end) }
        }
        guard end < text.endIndex else { return nil }
        let body = String(text[text.index(after: text.startIndex)..<end])
        if quote == "'" { return body }
        // Basic strings use the same escapes as JSON.
        return (try? JSONSerialization.jsonObject(with: Data("\"\(body)\"".utf8), options: .fragmentsAllowed)) as? String
    }

    // MARK: Finding command-line tools

    /// Apps started from Finder get a bare PATH, so ask the user's shell for the one their terminal uses and
    /// add the places agent tools are usually installed.
    static func shellSearchPath(home: URL, environment: [String: String]) -> [String] {
        let usual = [".local/bin", ".claude/local", ".bun/bin", ".volta/bin", ".npm-global/bin", ".cargo/bin", "Library/pnpm"]
            .map { home.appendingPathComponent($0).path }
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (shellPath(environment: environment) + inherited + usual).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func shellPath(environment: [String: String]) -> [String] {
        let marker = "__KEPT_PATH__"
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // A login, interactive shell reads the same startup files a terminal window does.
        process.arguments = ["-ilc", "printf '\\n\(marker)%s\\n' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        guard (try? process.run()) != nil else { return [] }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last { $0.hasPrefix(marker) }
        return line.map { $0.dropFirst(marker.count).split(separator: ":").map(String.init) } ?? []
    }
}

/// What Settings › Agents shows: each agent's status, and the Connect and Disconnect actions.
@MainActor
final class AgentCenter: ObservableObject {
    @Published private(set) var statuses: [AgentClient: AgentStatus] = [:]
    @Published private(set) var working: Set<AgentClient> = []
    /// Why the last change to an agent failed.
    @Published private(set) var failures: [AgentClient: String] = [:]
    /// Agents connected since the window opened; they pick the server up in their next session.
    @Published private(set) var justConnected: Set<AgentClient> = []
    /// Setup commands for the agents that have one, filled in once the linker is ready.
    @Published private(set) var setupCommands: [AgentClient: String] = [:]

    private var linker: AgentLinker?
    private let makeLinker: @Sendable () -> AgentLinker

    init(makeLinker: @escaping @Sendable () -> AgentLinker = { AgentLinker.live() }) {
        self.makeLinker = makeLinker
    }

    func refresh() async {
        let linker = await ready()
        statuses = await Task.detached {
            Dictionary(uniqueKeysWithValues: AgentClient.allCases.map { ($0, linker.status(of: $0)) })
        }.value
    }

    func connect(_ client: AgentClient) async {
        await change(client) { try $0.connect(client) }
        if failures[client] == nil { justConnected.insert(client) }
    }

    func disconnect(_ client: AgentClient) async {
        await change(client) { try $0.disconnect(client) }
        justConnected.remove(client)
    }

    private func ready() async -> AgentLinker {
        if let linker { return linker }
        let make = makeLinker
        let made = await Task.detached { make() }.value
        linker = made
        setupCommands = Dictionary(uniqueKeysWithValues: AgentClient.allCases.compactMap { client in
            made.setupCommand(for: client).map { (client, $0) }
        })
        return made
    }

    private func change(_ client: AgentClient, _ action: @escaping @Sendable (AgentLinker) throws -> Void) async {
        guard !working.contains(client) else { return }
        working.insert(client)
        failures[client] = nil
        let linker = await ready()
        let failure = await Task.detached { () -> String? in
            do {
                try action(linker)
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }.value
        failures[client] = failure
        working.remove(client)
        await refresh()
    }
}
