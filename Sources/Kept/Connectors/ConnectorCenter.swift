import Foundation
import KeptCore

/// Owns the user's connections: adding and removing them, their sign-ins, and keeping them in sync.
@MainActor
final class ConnectorCenter: ObservableObject {
    @Published private(set) var connections: [Connection] = []
    /// IDs of connections with a sync in flight.
    @Published private(set) var syncing: Set<String> = []

    private let db: Database
    private let library: LibraryStore
    private var timer: Timer?
    private static let syncInterval: TimeInterval = 30 * 60

    init(db: Database, library: LibraryStore) {
        self.db = db
        self.library = library
        reload()
    }

    /// Syncs now and then every half hour while Kept is running.
    func start() {
        syncAll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncAll() }
        }
        timer?.tolerance = 60
    }

    private func reload() {
        connections = (try? db.connections()) ?? []
    }

    // MARK: Adding, editing, removing

    /// Checks the settings against the service, then saves the connection and, unless it is paused, syncs it.
    /// Pass `existing` to change a connection; secret fields left empty keep their stored value.
    func connect(
        _ connector: any Connector, name: String, values: [String: String], existing: Connection? = nil
    ) async throws {
        var config: [String: String] = [:]
        var secrets = try existing.map { try ConnectorSecrets.load($0.id) } ?? [:]
        for field in connector.fields {
            let value = (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !field.isSecret {
                config[field.key] = value
            } else if !value.isEmpty {
                secrets[field.key] = value
            }
        }

        let context = ConnectorContext(values: config.merging(secrets) { $1 }, known: [])
        let account = try await connector.verify(context)

        var connection = existing ?? Connection(typeID: connector.id, name: name)
        var chosen = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if chosen.isEmpty {
            chosen = connector.defaultName(account: account)
            // A second account on the same service: tell the two apart.
            if let account, connections.contains(where: { $0.id != connection.id && $0.name == chosen }) {
                chosen += " (\(account))"
            }
        }
        connection.name = chosen
        connection.config = config
        connection.account = account
        // Editing keeps a paused connection paused; only a new one starts out enabled.
        connection.enabled = existing?.enabled ?? true

        try ConnectorSecrets.save(secrets, for: connection.id)
        do {
            try db.saveConnection(connection)
        } catch {
            if existing == nil { ConnectorSecrets.delete(connection.id) }
            throw error
        }
        reload()
        if connection.enabled { sync(connection.id) }
    }

    func setEnabled(_ connection: Connection, _ enabled: Bool) {
        var changed = connection
        changed.enabled = enabled
        try? db.saveConnection(changed)
        reload()
        if enabled { sync(connection.id) }
    }

    /// Forgets the connection and its sign-in. Items it already saved stay in the library.
    func remove(_ connection: Connection) {
        try? db.deleteConnection(id: connection.id)
        ConnectorSecrets.delete(connection.id)
        reload()
    }

    // MARK: Syncing

    func syncAll() {
        for connection in connections where connection.enabled { sync(connection.id) }
    }

    func sync(_ id: String) {
        guard !syncing.contains(id), let connection = connections.first(where: { $0.id == id }) else { return }
        syncing.insert(id)
        Task {
            let failure = await run(connection)
            // Recorded only if the connection still exists; it may have been removed mid-sync.
            try? db.setSyncResult(connection: id, at: Date(), error: failure)
            syncing.remove(id)
            reload()
        }
    }

    /// Fetches and saves. Returns a message for the user if it failed.
    private func run(_ connection: Connection) async -> String? {
        guard let connector = ConnectorRegistry.connector(connection.typeID) else {
            return "This version of Kept does not include this connector."
        }
        let db = self.db
        do {
            let secrets = try ConnectorSecrets.load(connection.id)
            let known = try db.seenKeys(connection: connection.id)
            let context = ConnectorContext(values: connection.config.merging(secrets) { $1 }, known: known)
            let found = try await connector.fetch(context)

            let added = try await Task.detached(priority: .utility) {
                let entries = found.filter { !known.contains($0.key) }.map { remote in
                    (key: remote.key, item: Self.item(from: remote, connection: connection))
                }
                return try db.importItems(entries, connection: connection.id)
            }.value
            if added > 0 { library.reload() }
            return nil
        } catch {
            NSLog("Kept: syncing \(connection.name) failed: \(error)")
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    nonisolated private static func item(from remote: RemoteItem, connection: Connection) -> Item {
        let title = remote.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTitle = title?.isEmpty == false
        switch remote.content {
        case .link(let address):
            // Same hash as a copied or shared link, so one address is only ever saved once.
            return Item(
                kind: .link, method: .connector, createdAt: remote.date ?? Date(),
                title: hasTitle ? title! : LibraryStore.linkTitle(address), text: address,
                sourceApp: connection.name, hash: Hashing.sha256("link:" + address), ocrDone: true)
        case .text(let text):
            return Item(
                kind: .text, method: .connector, createdAt: remote.date ?? Date(),
                title: hasTitle ? title! : LibraryStore.textTitle(text), text: text,
                sourceApp: connection.name, hash: Hashing.sha256("text:" + text), ocrDone: true)
        }
    }
}

extension Connection {
    var connector: (any Connector)? { ConnectorRegistry.connector(typeID) }

    /// The service refused the stored credentials; the user has to sign in again.
    var needsSignIn: Bool { lastError == ConnectorError.signInRejected.errorDescription }
}
