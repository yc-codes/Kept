#!/bin/bash
# Uses the same Swift Command Line Tools as the app plus Python 3 for the loopback fixture.
set -euo pipefail
cd "$(dirname "$0")/.."

# Build products are kept between runs, and each is compiled again only when its command, its
# inputs or the compiler changed.
build="${KEPT_TEST_BUILD:-.build/kept-tests}"
mkdir -p "$build"
swiftc=(xcrun swiftc -swift-version 5 -wmo)
toolchain="$("${swiftc[@]}" --version 2>&1)"

# compile <output> <swiftc arguments…>
compile() {
    local output="$1" inputs=() argument key
    shift
    for argument in "$@"; do
        case "$argument" in *.swift | *.a) inputs+=("$argument") ;; esac
    done
    key="$({ echo "$toolchain" "$@"; cat "${inputs[@]}"; } | md5)"
    if [ -f "$output" ] && [ "$(cat "$output.key" 2>/dev/null)" = "$key" ]; then return; fi
    rm -f "$output.key"
    "${swiftc[@]}" "$@" -o "$output"
    echo "$key" > "$output.key"
}

# Command Line Tools omit the XCTest and Swift Testing compiler plugins. Compile the app's
# service sources into the runner so it can exercise internal APIs without launching SwiftUI.
core="$build/libKeptCore.a"
compile "$core" -emit-library -static -emit-module -module-name KeptCore \
    Sources/KeptCore/*.swift -emit-module-path "$build/KeptCore.swiftmodule"
link=(-I "$build" "$core" -lsqlite3)
compile "$build/kept-mcp" "${link[@]}" Sources/KeptMCP/main.swift &
server=$!
compile "$build/KeptTests" -parse-as-library "${link[@]}" \
    Sources/Kept/KeptIcon.swift \
    Sources/Kept/Services/{AgentConnections,CaptureSettings,Clipboard,HotKeys,LibraryStore}.swift \
    Sources/Kept/Connectors/*.swift Sources/Kept/Connectors/BuiltIn/*.swift \
    Tests/KeptTests/*.swift
wait "$server"

KEPT_TEST_MCP="$build/kept-mcp" KEPT_TEST_FIXTURE="$PWD/Tests/Fixtures/connector_server.py" "$build/KeptTests"
