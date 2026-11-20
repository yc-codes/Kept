// kept-mcp: read-only Model Context Protocol server over stdio.
// Lets Claude Code, Codex and other agents search the Kept library, fetch items by ID, and pick up the
// user's latest captures in one call ("Kept fix last 4" becomes get_latest with count 4).

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

/// How long ago something was captured, in words. An agent rarely knows the current time, so the age lets
/// it notice when "the last 4" reaches back further than the user probably meant.
func age(of date: Date, now: Date = Date()) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    func plural(_ count: Int, _ unit: String) -> String { "\(count) \(unit)\(count == 1 ? "" : "s") ago" }
    switch seconds {
    case ..<60: return "just now"
    case ..<3600: return plural(seconds / 60, "minute")
    case ..<86400: return plural(seconds / 3600, "hour")
    default: return plural(seconds / 86400, "day")
    }
}

func describe(_ item: Item, excerpt: String = "", full: Bool) -> [String: Any] {
    let textLimit = full ? 20000 : 400
    var out: [String: Any] = [
        "id": item.id,
        "kind": item.kind.rawValue,
        "title": item.title,
        "captured_at": isoFormatter.string(from: item.createdAt),
        "captured_ago": age(of: item.createdAt),
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

/// The picture for an image item as tool content. Originals up to `budget` bytes go as they are; larger
/// ones are sent as a JPEG no wider or taller than 1568 pixels, which keeps the text in a screenshot legible.
func picture(of item: Item, budget: Int) -> [String: Any]? {
    guard item.kind == .image, let url = item.assetURL, let data = try? Data(contentsOf: url) else { return nil }
    if data.count <= budget {
        let mime = ImageTools.isGIF(data) ? "image/gif" : "image/png"
        return ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]
    }
    guard let jpeg = ImageTools.jpegThumbnail(from: data, maxPixel: 1568) else { return nil }
    return ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]
}

/// Most items `get_latest` returns in one reply. Several screenshots add up quickly.
let latestLimit = 10

/// A count that may arrive as a number or, from a prompt argument, as text.
func wholeNumber(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
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
        let payload: [String: Any] = [
            "count": hits.count,
            "items": hits.map { describe($0.item, full: false) },
            "hint": "This is a summary. To act on the newest items, call get_latest with a count: it returns them in full with the images attached.",
        ]
        return [["type": "text", "text": jsonText(payload)]]

    case "get_latest":
        guard let requested = wholeNumber(arguments["count"]), requested >= 1 else {
            throw ToolError(message: "Provide 'count': how many of the latest items to return, from 1 to \(latestLimit).")
        }
        let items = try openLibrary()
            .hits(filter: try filter(from: arguments), search: "", limit: min(requested, latestLimit)).map(\.item)
        // One reply carries everything needed to act on the items: full text first, then each picture
        // behind a line that says which item it belongs to.
        var pictures: [[String: Any]] = []
        for (index, item) in items.enumerated() {
            guard let image = picture(of: item, budget: 300_000) else { continue }
            pictures.append(["type": "text", "text": "Image for item \(item.id) (\(index + 1) of \(items.count), newest first):"])
            pictures.append(image)
        }
        var hint = "Items are newest first. A user_note says why the user saved an item or what they want done with it."
        if items.count < requested {
            hint += items.count == latestLimit
                ? " Only the \(latestLimit) newest come back at once; use list_recent and get_item for older ones."
                : " The library holds only \(items.count) matching \(items.count == 1 ? "item" : "items")."
        }
        let payload: [String: Any] = [
            "count": items.count,
            "attached_images": pictures.count / 2,
            "items": items.map { describe($0, full: true) },
            "hint": hint,
        ]
        return [["type": "text", "text": jsonText(payload)]] + pictures

    case "get_item":
        guard let id = arguments["id"] as? String else { throw ToolError(message: "Provide the item 'id'.") }
        guard let item = try openLibrary().item(id: id) else {
            throw ToolError(message: "No item with id '\(id)'.")
        }
        var content: [[String: Any]] = [["type": "text", "text": jsonText(describe(item, full: true))]]
        let wantsImage = (arguments["include_image"] as? Bool) ?? true
        if wantsImage, let image = picture(of: item, budget: 1_200_000) { content.append(image) }
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
        "name": "get_latest",
        "description": """
        Get the user's latest Kept items in full, newest first: complete text, their notes, and for screenshots \
        and other images the pictures themselves, all in one call. Use this whenever the user points at what \
        they just captured: "Kept fix last 4" means count 4, and so do requests like "use my last two \
        screenshots", "look at what I just saved" or "fix the bug I just snipped" (count 1).
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "count": [
                    "type": "integer", "minimum": 1, "maximum": latestLimit,
                    "description": "How many of the latest items to return, for example 4 for \"last 4\".",
                ],
                "kind": kindSchema,
            ],
            "required": ["count"],
        ],
        "annotations": ["readOnlyHint": true, "title": "Get latest Kept items"],
    ],
    [
        "name": "list_recent",
        "description": """
        Browse recently saved Kept items as a summary, newest first, without their images. For acting on the \
        newest few, use get_latest instead.
        """,
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

// MARK: Prompts

// Clients show these as commands the user can run, for example /mcp__kept__fix 4 in Claude Code.
let prompts: [[String: Any]] = [
    [
        "name": "fix",
        "title": "Fix what I just captured",
        "description": "Fix the problems shown in your latest Kept captures. Give a number to use that many; the default is the last one.",
        "arguments": [
            ["name": "count", "description": "How many of your latest items to fix. Default 1.", "required": false],
        ],
    ],
    [
        "name": "last",
        "title": "Use my latest captures",
        "description": "Bring your latest Kept captures into the conversation. Give a number to use that many; the default is the last one.",
        "arguments": [
            ["name": "count", "description": "How many of your latest items to bring in. Default 1.", "required": false],
        ],
    ],
]

struct UnknownPrompt: Error { let name: String }

/// The message a prompt expands to. Arguments arrive as strings; anything that is not a number counts as 1.
func promptText(_ name: String, _ arguments: [String: Any]) throws -> String {
    let count = min(max(wholeNumber(arguments["count"]) ?? 1, 1), latestLimit)
    let items = count == 1 ? "my latest Kept item" : "my last \(count) Kept items"
    let fetch = "Call Kept's get_latest tool with count \(count)."
    switch name {
    case "fix":
        return """
        Fix what \(items) \(count == 1 ? "shows" : "show").

        1. \(fetch)
        2. Each item is something I captured to show you a problem: a screenshot or snip of a bug, an error \
        message, a link, or copied text. My note on an item (user_note) says what I want done. Without a note, \
        work the problem out from the picture and the text in it.
        3. Find the code responsible in this project and fix each one. If an item is unclear, or has nothing to \
        do with this project, say so rather than guessing.
        4. Finish with one line per item: what it showed, what you changed, and its open_in_kept link.
        """
    case "last":
        return """
        \(fetch) Look closely at what \(items) \(count == 1 ? "shows" : "show"), including my notes \
        (user_note), then tell me in a line or two per item what you see, with its open_in_kept link. I will \
        say what to do with \(count == 1 ? "it" : "them") next.
        """
    default:
        throw UnknownPrompt(name: name)
    }
}

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
            "capabilities": ["tools": [String: Any](), "prompts": [String: Any]()],
            "serverInfo": ["name": "kept", "title": "Kept", "version": serverVersion],
            "instructions": """
            Kept is the user's local library of things they saved on this Mac: screenshots and snips, copied \
            images, links and text. When the user points at their latest captures ("Kept fix last 4", "use my \
            last two screenshots", "what did I just save"), call get_latest with that count: it returns those \
            items in full with the images attached. Then do what they asked with what the items show; a \
            user_note on an item says what the user wants. Use search_library to find older items and get_item \
            to read one in full. Always cite items with their open_in_kept link. Access is read-only.
            """,
        ])
    case "ping":
        return result(id, [:])
    case "tools/list":
        return result(id, ["tools": tools])
    case "prompts/list":
        return result(id, ["prompts": prompts])
    case "prompts/get":
        guard let name = params["name"] as? String else {
            return failure(id, code: -32602, message: "Missing prompt name.")
        }
        do {
            let text = try promptText(name, params["arguments"] as? [String: Any] ?? [:])
            let description = prompts.first { $0["name"] as? String == name }?["description"] as? String ?? ""
            return result(id, [
                "description": description,
                "messages": [["role": "user", "content": ["type": "text", "text": text]]],
            ])
        } catch {
            return failure(id, code: -32602, message: "Unknown prompt: \(name)")
        }
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
