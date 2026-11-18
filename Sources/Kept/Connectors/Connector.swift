import Foundation

/// A source Kept can sign in to and pull saved things from.
///
/// To add one: write a type that conforms to `Connector` (see `Sources/Kept/Connectors/BuiltIn`) and list it
/// in `ConnectorRegistry.all`. The Settings UI, sign-in sheet, Keychain storage, scheduling and de-duplication
/// are all driven by what the connector declares here.
protocol Connector: Sendable {
    /// Stable identifier stored with each connection. Never change it once shipped.
    var id: String { get }
    var name: String { get }
    /// SF Symbol name.
    var symbol: String { get }
    /// One line for the "Add Connector" menu and sheet: what gets saved.
    var summary: String { get }
    /// What the user fills in to connect. Fields marked `isSecret` are kept in the Keychain.
    var fields: [ConnectorField] { get }
    /// Where to create a token or find the address, linked from the sign-in sheet.
    var help: ConnectorHelp? { get }

    /// Checks that the settings and credentials work. Returns who is signed in (or what was connected to),
    /// shown next to the connection. Throw `ConnectorError` with a message the user can act on.
    func verify(_ context: ConnectorContext) async throws -> String?

    /// What to call a new connection when the user leaves the name empty.
    func defaultName(account: String?) -> String

    /// Returns what the source currently holds, newest first where the service allows. Kept skips anything
    /// this connection delivered before, so returning old entries again is harmless; use `context.isKnown`
    /// to stop paging early.
    func fetch(_ context: ConnectorContext) async throws -> [RemoteItem]
}

extension Connector {
    func defaultName(account: String?) -> String { name }
}

struct ConnectorField: Identifiable, Sendable {
    let key: String
    let label: String
    var placeholder = ""
    /// Passwords, tokens and keys. Stored in the Keychain and never shown again.
    var isSecret = false

    var id: String { key }
}

struct ConnectorHelp: Sendable {
    let title: String
    let url: URL
    /// Short instruction shown above the link.
    var note: String?
}

/// One thing a connector found. `key` identifies it within the source (an ID or the URL).
struct RemoteItem: Sendable {
    enum Content: Sendable {
        case link(String)
        case text(String)
    }

    let key: String
    let content: Content
    var title: String?
    /// When it was saved at the source. Used as the item's date so synced items sort where they belong.
    var date: Date?
}

/// What a connector gets to work with for one verify or fetch.
struct ConnectorContext: Sendable {
    /// Settings and secrets together, keyed by `ConnectorField.key`.
    let values: [String: String]
    /// Keys this connection has already delivered.
    let known: Set<String>

    func value(_ key: String) -> String {
        (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isKnown(_ key: String) -> Bool { known.contains(key) }
}

enum ConnectorError: LocalizedError {
    /// The service refused the credentials (expired, revoked or mistyped).
    case signInRejected
    case message(String)

    var errorDescription: String? {
        switch self {
        case .signInRejected: return "Sign-in was rejected. Check the token and connect again."
        case .message(let text): return text
        }
    }
}

enum ConnectorRegistry {
    /// Every connector Kept offers, in menu order.
    static let all: [any Connector] = [
        GitHubStarsConnector(),
        RaindropConnector(),
        FeedConnector(),
    ]

    static func connector(_ id: String) -> (any Connector)? { all.first { $0.id == id } }
}

/// Shared HTTP for connectors: no cookies or cache, short timeouts, and errors worded for the user.
enum ConnectorHTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.httpAdditionalHeaders = ["User-Agent": "Kept"]
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ConnectorError.message("Could not reach \(url.host ?? "the service"): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw ConnectorError.signInRejected
        case 403 where http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0", 429:
            throw ConnectorError.message("\(url.host ?? "The service") is rate limiting Kept. It will try again later.")
        case 403: throw ConnectorError.signInRejected
        case 404: throw ConnectorError.message("Nothing was found at \(url.absoluteString).")
        default: throw ConnectorError.message("\(url.host ?? "The service") answered with an error (\(http.statusCode)).")
        }
    }

    static func json(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        let data = try await get(url, headers: headers)
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConnectorError.message("\(url.host ?? "The service") sent a reply Kept could not read.")
        }
    }
}

enum ConnectorDates {
    private static let internet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let internetFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let rfc822: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z",
                                                   "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm Z"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = $0
        return formatter
    }

    /// Parses the timestamp styles APIs and feeds use: ISO 8601 (with or without fractions) and RFC 822.
    static func parse(_ string: String?) -> Date? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        if let date = internet.date(from: string) ?? internetFractional.date(from: string) { return date }
        for formatter in rfc822 {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
