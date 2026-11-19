import Foundation
import KeptCore

private typealias JSON = [String: Any]

private func conversation(_ lines: [String], home: URL) throws -> [Any] {
    let executable = try ProcessInfo.processInfo.environment["KEPT_TEST_MCP"].unwrap("Run scripts/test.sh")
    let inputURL = try scratch("stdio").appendingPathComponent("requests.jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: inputURL)
    let input = try FileHandle(forReadingFrom: inputURL)
    defer { try? input.close() }
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    var environment = ProcessInfo.processInfo.environment
    environment["KEPT_HOME"] = home.path
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try check(process.terminationStatus == 0, "kept-mcp exited with \(process.terminationStatus)")
    return try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8))
    }
}

private func jsonLine(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func rpc(_ id: Int, _ method: String, params: JSON = [:]) -> JSON {
    ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
}

private func tool(_ id: Int, _ name: String, _ arguments: JSON = [:]) -> JSON {
    rpc(id, "tools/call", params: ["name": name, "arguments": arguments])
}

private func result(_ message: JSON?) throws -> JSON {
    try (message?["result"] as? JSON).unwrap("expected JSON-RPC result")
}

private func errorCode(_ message: JSON?) -> Int? { (message?["error"] as? JSON)?["code"] as? Int }

private func contents(_ message: JSON?) throws -> [JSON] {
    try (result(message)["content"] as? [JSON]).unwrap("content array")
}

private func payload(_ message: JSON?) throws -> JSON {
    let text = try (contents(message).first?["text"] as? String).unwrap("tool JSON text")
    return try (JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON).unwrap("tool payload")
}

func testMCP() throws {
    let missing = try scratch("missing-library")
    let missingReply = try (conversation([jsonLine(tool(0, "list_recent"))], home: missing).first as? JSON)
        .unwrap("missing library response")
    try check(try result(missingReply)["isError"] as? Bool == true, "missing library error")
    try check(!FileManager.default.fileExists(atPath: missing.appendingPathComponent("kept.sqlite").path),
              "MCP must not create a database")

    let db = try Database(url: KeptPaths.database)
    let assetName = "mcp-fixture.gif"
    try onePixelGIF.write(to: KeptPaths.assets.appendingPathComponent(assetName))
    let image = Item(kind: .image, method: .snip, createdAt: Date(timeIntervalSince1970: 200),
                     title: "Mountain ridge", assetName: assetName, width: 1, height: 1, hash: "image",
                     note: "An alpine note", ocrText: "Dashboard", favorite: true, ocrDone: true)
    let item = Item(kind: .text, method: .manual, createdAt: Date(timeIntervalSince1970: 100),
                    title: "Meeting notes", text: String(repeating: "meeting ", count: 100), hash: "text", ocrDone: true)
    try db.insert(image)
    try db.insert(item)
    let commands = [
        rpc(1, "initialize", params: ["protocolVersion": "2025-03-26"]),
        rpc(2, "initialize", params: ["protocolVersion": "unsupported"]),
        rpc(3, "tools/list"), tool(4, "search_library", ["query": "dash alp", "kind": "snip"]),
        tool(5, "list_recent", ["limit": 0]), tool(6, "list_recent", ["kind": "text", "limit": 200]),
        tool(7, "get_item", ["id": image.id]), tool(8, "get_item", ["id": image.id, "include_image": false]),
        tool(9, "search_library", ["query": "***"]), tool(10, "get_item", ["id": "missing"]),
        tool(11, "list_recent", ["kind": "nonsense"]), tool(12, "delete_item", ["id": image.id]),
        rpc(13, "unknown"), rpc(14, "tools/call"), ["jsonrpc": "2.0", "method": "notifications/initialized"],
    ]
    let batch: [JSON] = [rpc(15, "ping"), ["jsonrpc": "2.0", "method": "notifications/initialized"]]
    let responses = try conversation(commands.map(jsonLine) + [jsonLine(batch), "[]", "{broken"], home: KeptPaths.root)
    try check(responses.count == 17, "one reply per request and no notification replies")
    var replies: [Int: JSON] = [:]
    for value in responses {
        if let message = value as? JSON, let id = message["id"] as? Int { replies[id] = message }
    }
    try check(try result(replies[1])["protocolVersion"] as? String == "2025-03-26", "protocol negotiation")
    try check(try result(replies[2])["protocolVersion"] as? String == "2025-06-18", "protocol fallback")
    let tools = try (result(replies[3])["tools"] as? [JSON]).unwrap("declared tools")
    try check(Set(tools.compactMap { $0["name"] as? String }) == ["search_library", "get_item", "list_recent"]
              && tools.allSatisfy { ($0["annotations"] as? JSON)?["readOnlyHint"] as? Bool == true },
              "only read-only tools advertised")
    let matches = try (payload(replies[4])["items"] as? [JSON]).unwrap("search results")
    try check(matches.count == 1 && matches.first?["open_in_kept"] as? String == image.deepLink
              && matches.first?["matching_excerpt"] != nil, "search uses OCR and notes, with a stable link")
    try check(try payload(replies[5])["count"] as? Int == 1, "out-of-range limit clamped")
    let textItems = try (payload(replies[6])["items"] as? [JSON]).unwrap("text results")
    try check(textItems.count == 1 && textItems.first?["id"] as? String == item.id
              && (textItems.first?["text"] as? String)?.count == 401, "list filter and excerpt limit")
    let imageReply = try contents(replies[7])
    try check(imageReply.count == 2 && imageReply.last?["mimeType"] as? String == "image/gif"
              && imageReply.last?["data"] as? String == onePixelGIF.base64EncodedString(), "original image attachment")
    try check(try contents(replies[8]).count == 1 && payload(replies[8])["pixel_size"] as? String == "1x1",
              "exclude image bytes while retaining metadata")
    for id in 9...11 {
        try check(try result(replies[id])["isError"] as? Bool == true, "tool error request \(id)")
    }
    try check(errorCode(replies[12]) == -32602 && errorCode(replies[13]) == -32601
              && errorCode(replies[14]) == -32602, "unknown tool/method and missing tool name")
    let batchReply = responses[14] as? [JSON]
    try check(batchReply?.count == 1 && batchReply?.first?["id"] as? Int == 15, "batch omits notification")
    try check(errorCode(responses[15] as? JSON) == -32600 && errorCode(responses[16] as? JSON) == -32700,
              "empty batch and malformed JSON errors")
    try check(try db.items() == [image, item], "tool calls left stored items intact")

    var rng = TestRandom(seed: 8401)
    let queries: [Any] = [NSNull(), true, 42, [], ["nested": 1], "", "😀", " NEAR ( \"* ", "dash", "meeting"]
    let random = try (0..<128).map { iteration -> String in
        let query = queries[rng.index(queries.count)]
        let limit = queries[rng.index(queries.count)]
        let names = ["search_library", "list_recent", "get_item", "missing_tool"]
        let name = names[rng.index(names.count)]
        return try jsonLine(tool(iteration, name, ["query": query, "limit": limit, "id": query]))
    }
    let fuzzed = try conversation(random, home: KeptPaths.root)
    try check(fuzzed.count == random.count, "all 128 randomized tool calls receive a reply")
    for (index, value) in fuzzed.enumerated() {
        let response = try (value as? JSON).unwrap("randomized JSON-RPC result at \(index)")
        try check(response["id"] as? Int == index && (response["result"] != nil || response["error"] != nil),
                  "valid reply at randomized request \(index)")
    }
}
