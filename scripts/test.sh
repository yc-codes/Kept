#!/bin/bash
# Uses the same Swift Command Line Tools as the app plus Python 3 for the loopback fixture.
set -euo pipefail
cd "$(dirname "$0")/.."
test_build="$(mktemp -d "${TMPDIR:-/tmp}/kept-test-build.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT

# Command Line Tools omit the XCTest and Swift Testing compiler plugins. Compile the app's
# service sources into the runner so it can exercise internal APIs without launching SwiftUI.
xcrun swiftc -swift-version 5 -emit-library -static -emit-module -module-name KeptCore \
    Sources/KeptCore/*.swift -emit-module-path "$test_build/KeptCore.swiftmodule" -o "$test_build/libKeptCore.a"
link=(-I "$test_build" -L "$test_build" -lKeptCore -lsqlite3)
xcrun swiftc -swift-version 5 "${link[@]}" Sources/KeptMCP/main.swift -o "$test_build/kept-mcp"
xcrun swiftc -swift-version 5 -parse-as-library "${link[@]}" \
    Sources/Kept/KeptIcon.swift \
    Sources/Kept/Services/{AgentConnections,CaptureSettings,Clipboard,HotKeys,LibraryStore}.swift \
    Sources/Kept/Connectors/*.swift Sources/Kept/Connectors/BuiltIn/*.swift \
    Tests/KeptTests/*.swift -o "$test_build/KeptTests"

KEPT_TEST_MCP="$test_build/kept-mcp" KEPT_TEST_FIXTURE="$PWD/Tests/Fixtures/connector_server.py" "$test_build/KeptTests"
