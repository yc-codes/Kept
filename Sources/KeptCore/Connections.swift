import Foundation
import SQLite3

/// One configured source the user added, e.g. "GitHub Stars" signed in as a particular account.
/// Several connections can share a connector type. Secrets are never stored here; they live in the Keychain.
public struct Connection: Identifiable, Hashable, Sendable {
    public var id: String
    /// Which connector this is an instance of (`Connector.id`).
    public var typeID: String
    public var name: String
    /// Non-secret settings, keyed by `ConnectorField.key`.
    public var config: [String: String]
    public var enabled: Bool
    /// Who the connector says is signed in, shown in Settings.
    public var account: String?
    public var createdAt: Date
    public var lastSync: Date?
    public var lastError: String?
    /// Items this connection has added to the library.
    public var imported: Int

    public init(
        id: String = "c" + Item.newID(), typeID: String, name: String, config: [String: String] = [:],
        enabled: Bool = true, account: String? = nil, createdAt: Date = Date(), lastSync: Date? = nil,
        lastError: String? = nil, imported: Int = 0
    ) {
        self.id = id
        self.typeID = typeID
        self.name = name
        self.config = config
        self.enabled = enabled
        self.account = account
        self.createdAt = createdAt
        self.lastSync = lastSync
        self.lastError = lastError
        self.imported = imported
    }
}

extension Database {
    public func connections() throws -> [Connection] {
        try query("""
        SELECT id,type,name,config,enabled,account,created_at,last_sync,last_error,imported
        FROM connections ORDER BY created_at
        """) { s in
            let config = (try? JSONDecoder().decode([String: String].self, from: Data(Self.string(s, 3).utf8))) ?? [:]
            return Connection(
                id: Self.string(s, 0), typeID: Self.string(s, 1), name: Self.string(s, 2), config: config,
                enabled: sqlite3_column_int(s, 4) != 0, account: Self.optional(s, 5),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 6)),
                lastSync: sqlite3_column_type(s, 7) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 7)),
                lastError: Self.optional(s, 8), imported: Int(sqlite3_column_int64(s, 9)))
        }
    }

    /// Inserts the connection, or updates its name, settings, account and switch if it already exists.
    public func saveConnection(_ connection: Connection) throws {
        let config = String(decoding: try JSONEncoder().encode(connection.config), as: UTF8.self)
        try run("""
        INSERT INTO connections (id,type,name,config,enabled,account,created_at) VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name, config=excluded.config, enabled=excluded.enabled, account=excluded.account
        """, [
            .text(connection.id), .text(connection.typeID), .text(connection.name), .text(config),
            .int(connection.enabled ? 1 : 0), connection.account.map(DBValue.text) ?? .null,
            .double(connection.createdAt.timeIntervalSince1970),
        ])
    }

    /// Removes the connection and its sync memory. Items it already added stay in the library.
    public func deleteConnection(id: String) throws {
        try run("DELETE FROM connections WHERE id=?", [.text(id)])
    }

    public func setSyncResult(connection: String, at date: Date, error: String?) throws {
        try run(
            "UPDATE connections SET last_sync=?, last_error=? WHERE id=?",
            [.double(date.timeIntervalSince1970), error.map(DBValue.text) ?? .null, .text(connection)])
    }

    /// Keys of everything this connection has delivered before, including items since deleted.
    public func seenKeys(connection: String) throws -> Set<String> {
        Set(try query("SELECT key FROM connection_seen WHERE connection=?", [.text(connection)]) { Self.string($0, 0) })
    }

    /// Saves what a sync returned, in one transaction. An entry is skipped when this connection delivered it
    /// before, or when the library already holds the same content. Returns how many items were added.
    @discardableResult
    public func importItems(_ entries: [(key: String, item: Item)], connection: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            var added = 0
            for entry in entries {
                try run(
                    "INSERT OR IGNORE INTO connection_seen (connection, key) VALUES (?,?)",
                    [.text(connection), .text(entry.key)])
                guard sqlite3_changes(db) > 0 else { continue }
                if try insert(entry.item) { added += 1 }
            }
            if added > 0 {
                try run(
                    "UPDATE connections SET imported = imported + ? WHERE id=?",
                    [.int(Int64(added)), .text(connection)])
            }
            try exec("COMMIT")
            return added
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
