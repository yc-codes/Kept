import Foundation
import KeptCore

private func expect(_ expected: AgentError, _ message: String, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as AgentError {
        try check(error == expected, "\(message): got \(error)")
        return
    }
    throw CheckFailure(description: "\(message): nothing was thrown")
}

private func executable(_ url: URL, _ script: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func servers(in file: URL) throws -> [String: Any] {
    let root = try (JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]).unwrap("settings JSON")
    return try (root["mcpServers"] as? [String: Any]).unwrap("mcpServers")
}

@MainActor
func testAgentConnections() async throws {
    let files = FileManager.default
    let home = try scratch("agent-home")
    let bin = home.appendingPathComponent("bin")
    let log = home.appendingPathComponent("tools.log")

    // The link follows the app when it moves, and survives a launch from a temporary location.
    let server = home.appendingPathComponent("Downloads/Kept.app/Contents/MacOS/kept-mcp")
    let moved = home.appendingPathComponent("Applications/Kept.app/Contents/MacOS/kept-mcp")
    try executable(server, "#!/bin/sh\n")
    try executable(moved, "#!/bin/sh\n")
    let launcher = home.appendingPathComponent("Library/Application Support/Kept/kept-mcp")
    try check(!AgentLauncher.refresh(server: nil, at: launcher), "no server, no link")
    try check(AgentLauncher.refresh(server: server, at: launcher)
              && (try files.destinationOfSymbolicLink(atPath: launcher.path)) == server.path, "link created")
    try check(AgentLauncher.refresh(server: moved, at: launcher)
              && (try files.destinationOfSymbolicLink(atPath: launcher.path)) == moved.path, "link follows the app")
    let temporary = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1234/d/Kept.app/Contents/MacOS/kept-mcp")
    try check(AgentLauncher.refresh(server: temporary, at: launcher)
              && (try files.destinationOfSymbolicLink(atPath: launcher.path)) == moved.path,
              "a temporary app location never replaces a working link")
    try check(try files.contentsOfDirectory(atPath: launcher.deletingLastPathComponent().path) == ["kept-mcp"],
              "no leftovers beside the link")

    // Stand-ins for the agents' command-line tools, behaving as the real ones do.
    let claudeFile = home.appendingPathComponent(".claude.json")
    try executable(bin.appendingPathComponent("claude"), """
    #!/bin/sh
    echo "claude $*" >> "\(log.path)"
    for last; do :; done
    case "$2" in
    add)
        if grep -q '"kept"' "\(claudeFile.path)" 2>/dev/null; then
            echo "MCP server kept already exists in user config"; exit 1
        fi
        printf '{"numStartups":3,"mcpServers":{"kept":{"type":"stdio","command":"%s","args":[],"env":{}}}}' "$last" > "\(claudeFile.path)" ;;
    remove)
        if ! grep -q '"kept"' "\(claudeFile.path)" 2>/dev/null; then
            echo "warning: checking"; echo 'No MCP server named "kept" in user scope'; exit 1
        fi
        printf '{"numStartups":3,"mcpServers":{}}' > "\(claudeFile.path)" ;;
    esac
    """)
    let codexFile = home.appendingPathComponent(".codex/config.toml")
    try executable(bin.appendingPathComponent("codex"), """
    #!/bin/sh
    echo "codex $*" >> "\(log.path)"
    for last; do :; done
    mkdir -p "\(codexFile.deletingLastPathComponent().path)"
    case "$2" in
    add) printf 'model = "gpt"\\n\\n[mcp_servers.other]\\ncommand = "/bin/other"\\n\\n[mcp_servers.kept]\\ncommand = "%s"\\n' "$last" > "\(codexFile.path)" ;;
    remove) printf 'model = "gpt"\\n\\n[mcp_servers.other]\\ncommand = "/bin/other"\\n' > "\(codexFile.path)" ;;
    esac
    """)

    let linker = AgentLinker(home: home, environment: ["HOME": home.path],
                             searchPath: [bin.path, "/usr/bin", "/bin"], launcher: launcher)
    try check(AgentClient.allCases.map(linker.status) == [.notConnected, .notConnected, .notInstalled, .notInstalled],
              "tools on the search path count as installed; apps without a settings folder do not")
    try check(linker.setupCommand(for: .claudeCode)
              == "claude mcp add --scope user kept -- \"$HOME/Library/Application Support/Kept/kept-mcp\""
              && linker.setupCommand(for: .codex) == "codex mcp add kept -- \"$HOME/Library/Application Support/Kept/kept-mcp\""
              && linker.setupCommand(for: .cursor) == nil, "setup commands are the same on every Mac")

    // Claude Code: `add` refuses to replace, so connecting twice must still succeed.
    try linker.connect(.claudeCode)
    try linker.connect(.claudeCode)
    try check(linker.status(of: .claudeCode) == .connected
              && linker.registeredCommand(for: .claudeCode) == launcher.path, "Claude Code connected through the link")
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    try check(calls == [
        "claude mcp remove --scope user kept", "claude mcp add --scope user kept -- \(launcher.path)",
        "claude mcp remove --scope user kept", "claude mcp add --scope user kept -- \(launcher.path)",
    ], "claude is asked to replace the user-scope entry: \(calls)")
    try linker.disconnect(.claudeCode)
    try check(linker.status(of: .claudeCode) == .notConnected, "Claude Code disconnected")
    try expect(.toolFailed("No MCP server named \"kept\" in user scope"), "a failing tool reports its last line") {
        try linker.disconnect(.claudeCode)
    }

    try linker.connect(.codex)
    try check(linker.status(of: .codex) == .connected && linker.registeredCommand(for: .codex) == launcher.path,
              "Codex connected through the link")
    try linker.disconnect(.codex)
    try check(linker.status(of: .codex) == .notConnected, "Codex disconnected")
    try check(AgentLinker.codexCommand(in: """
    [mcp_servers.kept-old]
    command = "/old"
    [mcp_servers.kept]
    args = []
    command = 'C:\\literal "path"' # comment
    [other]
    command = "/later"
    """) == "C:\\literal \"path\""
              && AgentLinker.codexCommand(in: "[mcp_servers.kept]\ncommand = \"/a \\\"b\\\"/kept-mcp\" # x") == "/a \"b\"/kept-mcp"
              && AgentLinker.codexCommand(in: "[mcp_servers.kept.env]\ncommand = \"/x\"") == nil
              && AgentLinker.codexCommand(in: "[mcp_servers.kept]\ncommand = unterminated\"") == nil,
              "Codex table parsing")

    // Without the tools, the agents are not found and connecting says how to finish by hand.
    var bare = linker
    bare.searchPath = []
    try files.removeItem(at: claudeFile)
    try check(bare.status(of: .claudeCode) == .notInstalled && bare.status(of: .codex) == .notConnected,
              "Codex's settings folder still shows it is installed")
    try expect(.toolNotFound("claude"), "missing tool") { try bare.connect(.claudeCode) }

    // Cursor and Claude Desktop keep a JSON file: everything else in it must survive.
    let cursorFile = linker.settingsFile(for: .cursor)
    try files.createDirectory(at: cursorFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try check(linker.status(of: .cursor) == .notConnected, "Cursor's settings folder shows it is installed")
    try Data(#"{"theme": "dark", "mcpServers": {"other": {"url": "https://example.test/mcp"}, "kept": {"command": "/gone/kept-mcp"}}}"#.utf8)
        .write(to: cursorFile)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cursorFile.path)
    try check(linker.status(of: .cursor) == .broken, "an entry pointing nowhere is reported as broken")
    try linker.connect(.cursor)
    var cursor = try servers(in: cursorFile)
    try check((cursor["kept"] as? [String: Any])?["command"] as? String == launcher.path
              && (cursor["other"] as? [String: Any])?["url"] as? String == "https://example.test/mcp"
              && linker.status(of: .cursor) == .connected, "Cursor entry replaced, others kept")
    try check(try String(contentsOf: cursorFile, encoding: .utf8) == """
    {
      "mcpServers": {
        "kept": {
          "args": [],
          "command": "\(launcher.path)"
        },
        "other": {
          "url": "https://example.test/mcp"
        }
      },
      "theme": "dark"
    }

    """, "settings are written the way people write them")
    try check((try files.attributesOfItem(atPath: cursorFile.path))[.posixPermissions] as? Int == 0o600,
              "file permissions kept")
    try linker.disconnect(.cursor)
    cursor = try servers(in: cursorFile)
    try check(cursor["kept"] == nil && cursor["other"] != nil && linker.status(of: .cursor) == .notConnected,
              "only Kept's entry removed")

    let broken = Data("{ // comments are not JSON\n \"mcpServers\": {} }".utf8)
    try broken.write(to: cursorFile)
    try expect(.unreadableSettings(cursorFile.path), "unreadable settings") { try linker.connect(.cursor) }
    try check(try Data(contentsOf: cursorFile) == broken, "an unreadable settings file is left untouched")

    let desktopFile = linker.settingsFile(for: .claudeDesktop)
    try files.createDirectory(at: desktopFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("\n".utf8).write(to: desktopFile)
    try linker.connect(.claudeDesktop)
    try check(linker.status(of: .claudeDesktop) == .connected, "an empty settings file is filled in")

    var custom = linker
    custom.environment = ["CLAUDE_CONFIG_DIR": home.appendingPathComponent("cc").path,
                          "CODEX_HOME": home.appendingPathComponent("cx").path]
    try check(custom.settingsFile(for: .claudeCode).path == home.appendingPathComponent("cc/.claude.json").path
              && custom.settingsFile(for: .codex).path == home.appendingPathComponent("cx/config.toml").path,
              "relocated agent settings are honoured")

    // The settings model reports progress and failures per agent.
    let center = AgentCenter(makeLinker: { linker })
    await center.refresh()
    try check(center.statuses[.claudeDesktop] == .connected && center.statuses[.claudeCode] == .notConnected
              && center.setupCommands.keys.sorted { $0.rawValue < $1.rawValue } == [.claudeCode, .codex],
              "statuses and setup commands loaded")
    await center.connect(.claudeCode)
    try check(center.statuses[.claudeCode] == .connected && center.justConnected == [.claudeCode]
              && center.failures.isEmpty && center.working.isEmpty, "connected from settings")
    await center.connect(.cursor)
    try check(center.statuses[.cursor] == .notConnected && center.failures[.cursor]?.contains("could not read") == true
              && !center.justConnected.contains(.cursor), "a failure is shown and nothing claims to be connected")
    await center.disconnect(.claudeCode)
    try check(center.statuses[.claudeCode] == .notConnected && center.justConnected.isEmpty, "disconnected from settings")

    try files.removeItem(at: launcher)
    try expect(.noServer, "nothing is registered without a server") { try linker.connect(.claudeDesktop) }
}
