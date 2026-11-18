import Foundation
import Security

/// Tokens and passwords for connections, one Keychain entry per connection. Nothing secret is written to
/// the library database or to preferences.
enum ConnectorSecrets {
    /// Test runs (`KEPT_HOME` / `KEPT_DEFAULTS_SUITE`) get their own entries, apart from the real ones.
    private static let service: String = {
        let environment = ProcessInfo.processInfo.environment
        let isolated = ["KEPT_HOME", "KEPT_DEFAULTS_SUITE"].contains { environment[$0]?.isEmpty == false }
        return isolated ? "app.kept.Kept.connector.test" : "app.kept.Kept.connector"
    }()

    private static func query(_ connection: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: connection]
    }

    static func load(_ connection: String) throws -> [String: String] {
        var request = query(connection)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = result as? Data,
              let secrets = try? JSONDecoder().decode([String: String].self, from: data)
        else { throw ConnectorError.message("Kept could not read this connector's sign-in from the Keychain (\(message(status))).") }
        return secrets
    }

    static func save(_ secrets: [String: String], for connection: String) throws {
        if secrets.isEmpty {
            delete(connection)
            return
        }
        let data = try JSONEncoder().encode(secrets)
        var status = SecItemUpdate(query(connection) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(connection)
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Kept connector sign-in"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ConnectorError.message("Kept could not save the sign-in to the Keychain (\(message(status))).")
        }
    }

    static func delete(_ connection: String) {
        SecItemDelete(query(connection) as CFDictionary)
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
    }
}
