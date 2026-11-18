// kept-mcp: read-only Model Context Protocol server over stdio.
// Lets Claude Code, Codex and other agents search the Kept library and fetch items by ID.

import Foundation
import KeptCore

let serverVersion = "0.1.0"
let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

func write(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data + Data([0x0A]))
}

func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "result": result]
}

func failure(_ id: Any, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
}

struct ToolError: Error { let message: String }

func openLibrary() throws -> Database {
    guard FileManager.default.fileExists(atPath: KeptPaths.database.path) else {
        throw ToolError(message: "The Kept library does not exist yet. Open the Kept app once to create it.")
    }
    return try Database(url: KeptPaths.database, readOnly: true)
}

let isoFormatter = ISO8601DateFormatter()

func clip(_ text: String, _ limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit)) + "…" : text
}

func describe(_ item: Item, excerpt: String = "", full: Bool) -> [String: Any] {
    let textLimit = full ? 20000 : 400
    var out: [String: Any] = [
        "id": item.id,
        "kind": item.kind.rawValue,
        "title": item.title,
        "captured_at": isoFormatter.string(from: item.createdAt),
        "capture_method": item.method.rawValue,
        "open_in_kept": item.deepLink,
    ]
    if let app = item.sourceApp { out["source_app"] = app }
    if !item.note.isEmpty { out["user_note"] = clip(item.note, textLimit) }
    if !item.aiDescription.isEmpty { out["generated_description"] = clip(item.aiDescription, textLimit) }
    switch item.kind {
    case .link: out["url"] = item.text
    case .text: out["text"] = clip(item.text, textLimit)
    case .image:
        if !item.ocrText.isEmpty { out["text_in_image"] = clip(item.ocrText, textLimit) }
        if let url = item.assetURL { out["file_path"] = url.path }
        if full { out["pixel_size"] = "\(item.width)x\(item.height)" }
    }
    if !excerpt.isEmpty { out["matching_excerpt"] = excerpt }
    return out
}

func jsonText(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

func filter(from arguments: [String: Any]) throws -> ItemFilter {
    guard let kind = arguments["kind"] as? String, !kind.isEmpty, kind != "any" else { return .all }
    switch kind {
    case "image": return .images
    case "link": return .links
    case "text": return .text
    case "snip": return .snips
    case "favorite": return .favorites
    default: throw ToolError(message: "Unknown kind '\(kind)'. Use image, link, text, snip, favorite or any.")
    }
}

func limit(from arguments: [String: Any], default fallback: Int) -> Int {
    let requested = (arguments["limit"] as? NSNumber)?.intValue ?? fallback
    return min(max(requested, 1), 50)
}

func callTool(_ name: String, _ arguments: [String: Any]) throws -> [[String: Any]] {
    switch name {
    case "search_library":
        guard let query = arguments["query"] as? String, FTSQuery.make(query) != nil else {
            throw ToolError(message: "Provide a non-empty 'query'.")
        }
        let hits = try openLibrary().hits(
            filter: try filter(from: arguments), search: query, limit: limit(from: arguments, default: 10))
        let payload: [String: Any] = [
            "query": query,
            "count": hits.count,
            "items": hits.map { describe($0.item, excerpt: $0.excerpt, full: false) },
            "hint": hits.isEmpty
                ? "No matches. All words must match; try fewer or different keywords."
                : "Call get_item with an id for full content and the image itself.",
        ]
        return [["type": "text", "text": jsonText(payload)]]

    case "list_recent":
        let hits = try openLibrary().hits(
            filter: try filter(from: arguments), search: "", limit: limit(from: arguments, default: 20))
        return [["type": "text", "text": jsonText(["count": hits.count, "items": hits.map { describe($0.item, full: false) }])]]

    case "get_item":
        guard let id = arguments["id"] as? String else { throw ToolError(message: "Provide the item 'id'.") }
        guard let item = try openLibrary().item(id: id) else {
            throw ToolError(message: "No item with id '\(id)'.")
        }
        var content: [[String: Any]] = [["type": "text", "text": jsonText(describe(item, full: true))]]
        let wantsImage = (arguments["include_image"] as? Bool) ?? true
        if wantsImage, item.kind == .image, let url = item.assetURL, let data = try? Data(contentsOf: url) {
            if data.count <= 1_200_000 {
                let mime = ImageTools.isGIF(data) ? "image/gif" : "image/png"
                content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": mime])
            } else if let jpeg = ImageTools.jpegThumbnail(from: data, maxPixel: 1568) {
                content.append(["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"])
            }
        }
        return content

    default:
        throw UnknownTool(name: name)
    }
}

struct UnknownTool: Error { let name: String }

let kindSchema: [String: Any] = [
    "type": "string",
    "enum": ["any", "image", "link", "text", "snip", "favorite"],
    "description": "Restrict results to one kind of item. Defaults to any.",
]

let tools: [[String: Any]] = [
    [
        "name": "search_library",
        "description": """
        Full-text search over the user's Kept library on this Mac: screenshots and region snips, copied images, \
        links and text. Matches titles, URLs, copied text, text recognised inside images, and the user's own notes \
        about why they saved each item. Every word must match (prefix matching), so prefer 1-3 distinctive keywords \
        and retry with different words if nothing comes back. Results include a stable id and a kept:// link that \
        opens the exact item.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Keywords to look for."],
                "kind": kindSchema,
                "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Default 10."],
            ],
            "required": ["query"],
        ],
        "annotations": ["readOnlyHint": true, "title": "Search Kept library"],
    ],
    [
        "name": "get_item",
        "description": """
        Fetch one Kept item by id: full text, the user's note, source app, capture time, and for images the picture \
        itself plus its file path on disk. Cite the item to the user with its open_in_kept link.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "Item id from search_library or list_recent."],
                "include_image": ["type": "boolean", "description": "Attach the image for image items. Default true."],
            ],
            "required": ["id"],
        ],
        "annotations": ["readOnlyHint": true, "title": "Get Kept item"],
    ],
    [
        "name": "list_recent",
        "description": "List the most recently saved Kept items, newest first.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "kind": kindSchema,
                "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Default 20."],
            ],
        ],
        "annotations": ["readOnlyHint": true, "title": "List recent Kept items"],
    ],
]

/// Returns the response for one JSON-RPC message, or nil for notifications.
func handle(_ raw: Any) -> [String: Any]? {
    guard let message = raw as? [String: Any] else {
        return failure(NSNull(), code: -32600, message: "Invalid request")
    }
    let id: Any? = message["id"].flatMap { $0 is NSNull ? nil : $0 }
    guard let method = message["method"] as? String else {
        // A response to something we never asked, or a malformed request.
        if message["result"] != nil || message["error"] != nil { return nil }
        return failure(id ?? NSNull(), code: -32600, message: "Invalid request: missing method")
    }
    // Notifications carry no id and get no response.
    guard let id else { return nil }
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        return result(id, [
            "protocolVersion": supportedProtocols.contains(requested) ? requested : supportedProtocols[0],
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "kept", "title": "Kept", "version": serverVersion],
            "instructions": """
            Kept is the user's local library of things they saved on this Mac. Use search_library to find items, \
            get_item to read one in full, and always cite items with their open_in_kept link. Access is read-only.
            """,
        ])
    case "ping":
        return result(id, [:])
    case "tools/list":
        return result(id, ["tools": tools])
    case "tools/call":
        guard let name = params["name"] as? String else {
            return failure(id, code: -32602, message: "Missing tool name.")
        }
        do {
            let content = try callTool(name, params["arguments"] as? [String: Any] ?? [:])
            return result(id, ["content": content, "isError": false])
        } catch let error as UnknownTool {
            return failure(id, code: -32602, message: "Unknown tool: \(error.name)")
        } catch let error as ToolError {
            return result(id, ["content": [["type": "text", "text": error.message]], "isError": true])
        } catch {
            return result(id, ["content": [["type": "text", "text": "Kept error: \(error)"]], "isError": true])
        }
    default:
        return failure(id, code: -32601, message: "Method not found: \(method)")
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
        write(failure(NSNull(), code: -32700, message: "Parse error"))
        continue
    }
    if let batch = json as? [Any] {
        // JSON-RPC batch (part of the 2025-03-26 revision): answer with one array, omitting notifications.
        if batch.isEmpty {
            write(failure(NSNull(), code: -32600, message: "Invalid request: empty batch"))
        } else {
            let responses = batch.compactMap(handle)
            if !responses.isEmpty { write(responses) }
        }
    } else if let response = handle(json) {
        write(response)
    }
}
