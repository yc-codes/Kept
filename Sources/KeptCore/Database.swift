import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct DBError: Error, CustomStringConvertible {
    public let description: String
}

public enum DBValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

public struct SearchHit: Sendable {
    public let item: Item
    /// Matching excerpt with the hit wrapped in [brackets]. Empty when listing without a query.
    public let excerpt: String
}

/// SQLite store with FTS5 full-text search. Safe to call from any thread.
public final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(url: URL, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw DBError(description: "Could not open library at \(url.path): \(message)")
        }
        sqlite3_busy_timeout(db, 3000)
        if !readOnly {
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
            try migrate()
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: Schema

    private func migrate() throws {
        let version = try query("PRAGMA user_version") { sqlite3_column_int($0, 0) }.first ?? 0
        if version < 1 {
            try exec("""
            CREATE TABLE IF NOT EXISTS items (
                pk INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                method TEXT NOT NULL,
                created_at REAL NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                text TEXT NOT NULL DEFAULT '',
                asset TEXT,
                width INTEGER NOT NULL DEFAULT 0,
                height INTEGER NOT NULL DEFAULT 0,
                source_app TEXT,
                source_bundle TEXT,
                hash TEXT NOT NULL UNIQUE,
                note TEXT NOT NULL DEFAULT '',
                ocr TEXT NOT NULL DEFAULT '',
                description TEXT NOT NULL DEFAULT '',
                favorite INTEGER NOT NULL DEFAULT 0,
                ocr_done INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS items_created ON items(created_at DESC);
            CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                title, body, note, ocr, description,
                tokenize='unicode61 remove_diacritics 2', prefix='2 3'
            );
            CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
                INSERT INTO items_fts(rowid, title, body, note, ocr, description)
                VALUES (new.pk, new.title, new.text, new.note, new.ocr, new.description);
            END;
            CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
                DELETE FROM items_fts WHERE rowid = old.pk;
            END;
            CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE OF title, text, note, ocr, description ON items BEGIN
                DELETE FROM items_fts WHERE rowid = old.pk;
                INSERT INTO items_fts(rowid, title, body, note, ocr, description)
                VALUES (new.pk, new.title, new.text, new.note, new.ocr, new.description);
            END;
            PRAGMA user_version = 1;
            """)
        }
    }

    // MARK: Writes

    /// Returns false when an item with the same content hash already exists.
    @discardableResult
    public func insert(_ item: Item) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        try run("""
        INSERT OR IGNORE INTO items
            (id, kind, method, created_at, title, text, asset, width, height, source_app, source_bundle,
             hash, note, ocr, description, favorite, ocr_done)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(item.id), .text(item.kind.rawValue), .text(item.method.rawValue),
            .double(item.createdAt.timeIntervalSince1970), .text(item.title), .text(item.text),
            item.assetName.map(DBValue.text) ?? .null, .int(Int64(item.width)), .int(Int64(item.height)),
            item.sourceApp.map(DBValue.text) ?? .null, item.sourceBundleID.map(DBValue.text) ?? .null,
            .text(item.hash), .text(item.note), .text(item.ocrText), .text(item.aiDescription),
            .int(item.favorite ? 1 : 0), .int(item.ocrDone ? 1 : 0),
        ])
        return sqlite3_changes(db) > 0
    }

    public func setNote(id: String, note: String) throws {
        try run("UPDATE items SET note=? WHERE id=?", [.text(note), .text(id)])
    }

    public func setTitle(id: String, title: String) throws {
        try run("UPDATE items SET title=? WHERE id=?", [.text(title), .text(id)])
    }

    public func setFavorite(id: String, favorite: Bool) throws {
        try run("UPDATE items SET favorite=? WHERE id=?", [.int(favorite ? 1 : 0), .text(id)])
    }

    public func setOCR(id: String, text: String) throws {
        try run("UPDATE items SET ocr=?, ocr_done=1 WHERE id=?", [.text(text), .text(id)])
    }

    public func delete(id: String) throws {
        try run("DELETE FROM items WHERE id=?", [.text(id)])
    }

    // MARK: Reads

    private static let columns = """
    i.id,i.kind,i.method,i.created_at,i.title,i.text,i.asset,i.width,i.height,i.source_app,i.source_bundle,\
    i.hash,i.note,i.ocr,i.description,i.favorite,i.ocr_done
    """

    public func item(id: String) throws -> Item? {
        try query("SELECT \(Self.columns) FROM items i WHERE i.id=?", [.text(id)], map: Self.readItem).first
    }

    public func item(hash: String) throws -> Item? {
        try query("SELECT \(Self.columns) FROM items i WHERE i.hash=?", [.text(hash)], map: Self.readItem).first
    }

    public func items(filter: ItemFilter = .all, search: String = "", limit: Int = 5000) throws -> [Item] {
        try hits(filter: filter, search: search, limit: limit).map(\.item)
    }

    /// Newest first when `search` is empty, best match first otherwise.
    public func hits(filter: ItemFilter = .all, search: String = "", limit: Int = 50) throws -> [SearchHit] {
        if let match = FTSQuery.make(search) {
            // Column weights: title, body, note, ocr, description. The user's note counts most.
            return try query("""
            SELECT \(Self.columns), snippet(items_fts, -1, '[', ']', '…', 24)
            FROM items_fts JOIN items i ON i.pk = items_fts.rowid
            WHERE items_fts MATCH ? AND \(filter.whereClause)
            ORDER BY bm25(items_fts, 5.0, 1.0, 8.0, 1.0, 2.0), i.created_at DESC
            LIMIT ?
            """, [.text(match), .int(Int64(limit))]) {
                SearchHit(item: Self.readItem($0), excerpt: Self.string($0, 17))
            }
        }
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return try query("""
        SELECT \(Self.columns) FROM items i WHERE \(filter.whereClause)
        ORDER BY i.created_at DESC, i.pk DESC LIMIT ?
        """, [.int(Int64(limit))]) { SearchHit(item: Self.readItem($0), excerpt: "") }
    }

    public func counts() throws -> [ItemFilter: Int] {
        let rows = try query("""
        SELECT COUNT(*), IFNULL(SUM(method='snip'),0), IFNULL(SUM(kind='image'),0), IFNULL(SUM(kind='link'),0),
               IFNULL(SUM(kind='text'),0), IFNULL(SUM(favorite),0) FROM items
        """) { s -> [ItemFilter: Int] in
            [
                .all: Int(sqlite3_column_int64(s, 0)), .snips: Int(sqlite3_column_int64(s, 1)),
                .images: Int(sqlite3_column_int64(s, 2)), .links: Int(sqlite3_column_int64(s, 3)),
                .text: Int(sqlite3_column_int64(s, 4)), .favorites: Int(sqlite3_column_int64(s, 5)),
            ]
        }
        return rows.first ?? [:]
    }

    /// Images whose text has not been recognised yet (e.g. the app quit mid-OCR).
    public func pendingOCR() throws -> [Item] {
        try query("SELECT \(Self.columns) FROM items i WHERE i.kind='image' AND i.ocr_done=0", map: Self.readItem)
    }

    // MARK: Plumbing

    /// Reads by byte length rather than as a C string, so text containing NUL is not cut short.
    private static func string(_ s: OpaquePointer, _ i: Int32) -> String {
        guard let bytes = sqlite3_column_blob(s, i) else { return "" }
        let count = Int(sqlite3_column_bytes(s, i))
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private static func optional(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : string(s, i)
    }

    private static func readItem(_ s: OpaquePointer) -> Item {
        Item(
            id: string(s, 0),
            kind: ItemKind(rawValue: string(s, 1)) ?? .text,
            method: CaptureMethod(rawValue: string(s, 2)) ?? .manual,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
            title: string(s, 4), text: string(s, 5), assetName: optional(s, 6),
            width: Int(sqlite3_column_int64(s, 7)), height: Int(sqlite3_column_int64(s, 8)),
            sourceApp: optional(s, 9), sourceBundleID: optional(s, 10), hash: string(s, 11),
            note: string(s, 12), ocrText: string(s, 13), aiDescription: string(s, 14),
            favorite: sqlite3_column_int(s, 15) != 0, ocrDone: sqlite3_column_int(s, 16) != 0
        )
    }

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw DBError(description: message)
        }
    }

    private func prepare(_ sql: String, _ params: [DBValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DBError(description: String(cString: sqlite3_errmsg(db)))
        }
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string):
                let utf8 = Array(string.utf8)
                sqlite3_bind_text(statement, index, utf8, Int32(utf8.count), SQLITE_TRANSIENT)
            case .int(let int): sqlite3_bind_int64(statement, index, int)
            case .double(let double): sqlite3_bind_double(statement, index, double)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ params: [DBValue] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DBError(description: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(_ sql: String, _ params: [DBValue] = [], map: (OpaquePointer) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                rows.append(map(statement))
            } else if code == SQLITE_DONE {
                return rows
            } else {
                throw DBError(description: String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}

public enum FTSQuery {
    /// Turns free text into a prefix-matching FTS5 query: `onboard lay` → `"onboard"* "lay"*`.
    public static func make(_ input: String) -> String? {
        let terms = input.split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .map { "\"\($0)\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }
}
