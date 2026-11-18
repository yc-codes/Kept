// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kept",
    platforms: [.macOS(.v14)],
    targets: [
        // Storage, search and image helpers shared by the app and the MCP server.
        .target(name: "KeptCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // The Mac app.
        .executableTarget(name: "Kept", dependencies: ["KeptCore"]),
        // Read-only MCP server (stdio) for Claude Code, Codex and other agents.
        .executableTarget(name: "kept-mcp", dependencies: ["KeptCore"], path: "Sources/KeptMCP"),
    ],
    swiftLanguageModes: [.v5]
)
