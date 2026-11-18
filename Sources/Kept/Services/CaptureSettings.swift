import AppKit
import Foundation

enum KeptDefaults {
    /// `KEPT_DEFAULTS_SUITE` isolates preferences for test runs.
    static let store: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["KEPT_DEFAULTS_SUITE"], !suite.isEmpty,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }()
}

enum AppTheme: String, CaseIterable {
    case system, light, dark

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct ExcludedApp: Codable, Identifiable, Hashable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// What Kept is allowed to save. Every clipboard source is off until the user turns it on.
@MainActor
final class CaptureSettings: ObservableObject {
    /// Password managers are never captured, whatever the user's list says.
    static let alwaysExcluded: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.dashlane.dashlanephonefinal", "com.lastpass.LastPass", "org.keepassxc.keepassxc",
        "in.sinew.Enpass-Desktop", "me.proton.pass.electron", "com.markmcguill.strongbox.mac",
        "com.nordpass.macos.nordpass", "com.keepersecurity.passwordmanager",
    ]

    private let defaults = KeptDefaults.store

    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: "theme")
            NSApp.appearance = theme.appearance
        }
    }

    @Published var captureImages: Bool { didSet { defaults.set(captureImages, forKey: "captureImages") } }
    @Published var captureLinks: Bool { didSet { defaults.set(captureLinks, forKey: "captureLinks") } }
    @Published var captureText: Bool { didSet { defaults.set(captureText, forKey: "captureText") } }
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused") } }
    @Published var didOnboard: Bool { didSet { defaults.set(didOnboard, forKey: "didOnboard") } }
    @Published var excludedApps: [ExcludedApp] { didSet { save(excludedApps, "excludedApps") } }
    @Published var snipShortcut: Shortcut { didSet { save(snipShortcut, "snipShortcut"); onShortcutsChanged?() } }
    @Published var quickShortcut: Shortcut { didSet { save(quickShortcut, "quickShortcut"); onShortcutsChanged?() } }

    /// Set when a global shortcut could not be registered, e.g. another app already owns it.
    @Published var shortcutWarning: String?

    var onShortcutsChanged: (() -> Void)?

    init() {
        theme = defaults.string(forKey: "theme").flatMap(AppTheme.init(rawValue:)) ?? .system
        captureImages = defaults.bool(forKey: "captureImages")
        captureLinks = defaults.bool(forKey: "captureLinks")
        captureText = defaults.bool(forKey: "captureText")
        paused = defaults.bool(forKey: "paused")
        didOnboard = defaults.bool(forKey: "didOnboard")
        excludedApps = Self.load("excludedApps", from: defaults) ?? []
        snipShortcut = Self.load("snipShortcut", from: defaults) ?? .defaultSnip
        quickShortcut = Self.load("quickShortcut", from: defaults) ?? .defaultQuickSearch
    }

    var anyClipboardCapture: Bool { captureImages || captureLinks || captureText }

    func isExcluded(_ bundleID: String) -> Bool {
        Self.alwaysExcluded.contains(bundleID) || excludedApps.contains { $0.bundleID == bundleID }
    }

    /// One-line summary shown in the sidebar and the menu bar.
    var statusLine: String {
        if paused { return "Clipboard capture paused. Snips still save." }
        var parts: [String] = []
        if captureImages { parts.append("images") }
        if captureLinks { parts.append("links") }
        if captureText { parts.append("text") }
        if parts.isEmpty { return "Saving snips only" }
        return "Saving snips and copied " + ListFormatter.localizedString(byJoining: parts)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
