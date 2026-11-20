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

/// The colour Kept uses for selection, primary buttons and highlights. Each choice has a light and a dark
/// value picked to stay readable as text on Kept's own backgrounds.
enum AccentChoice: String, CaseIterable, Identifiable {
    case terracotta, amber, green, teal, blue, violet, pink, graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terracotta: return "Terracotta"
        case .amber: return "Amber"
        case .green: return "Green"
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .violet: return "Violet"
        case .pink: return "Pink"
        case .graphite: return "Graphite"
        }
    }

    /// sRGB hex for light and dark appearances.
    var hex: (light: UInt32, dark: UInt32) {
        switch self {
        case .terracotta: return (0xA93820, 0xFF9A79)
        case .amber: return (0x8F5500, 0xFFC25C)
        case .green: return (0x2A7541, 0x7FD99A)
        case .teal: return (0x0B7478, 0x5CD6D0)
        case .blue: return (0x2360D1, 0x82B1FF)
        case .violet: return (0x6A43C6, 0xB9A1FF)
        case .pink: return (0xB3306B, 0xFF93BD)
        case .graphite: return (0x55555C, 0xB4B4BD)
        }
    }

    /// Fill for system controls that draw a white label on it (prominent buttons, switches). The system
    /// brightens whatever it is given, most of all in dark mode, so the warm and pale hues get deeper
    /// values here to keep the label readable.
    var controlHex: (light: UInt32, dark: UInt32) {
        switch self {
        case .amber: return (0x764600, 0x6B3F00)
        case .teal: return (0x09666A, 0x095B5E)
        case .green: return (hex.light, 0x236337)
        default: return (hex.light, hex.light)
        }
    }
}

/// How large the cards in the library grid are.
enum CardSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var minWidth: CGFloat {
        switch self {
        case .small: return 158
        case .medium: return 205
        case .large: return 280
        }
    }

    var previewHeight: CGFloat {
        switch self {
        case .small: return 112
        case .medium: return 152
        case .large: return 208
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

    private let defaults: UserDefaults

    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: "theme")
            NSApp?.appearance = theme.appearance
        }
    }

    @Published var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    @Published var cardSize: CardSize { didSet { defaults.set(cardSize.rawValue, forKey: "cardSize") } }
    /// Off shows each picture whole inside its card instead of cropping it to fill.
    @Published var cropThumbnails: Bool { didSet { defaults.set(cropThumbnails, forKey: "cropThumbnails") } }
    @Published var showSidebarCounts: Bool { didSet { defaults.set(showSidebarCounts, forKey: "showSidebarCounts") } }

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

    init(defaults: UserDefaults = KeptDefaults.store) {
        self.defaults = defaults
        theme = defaults.string(forKey: "theme").flatMap(AppTheme.init(rawValue:)) ?? .system
        accent = defaults.string(forKey: "accent").flatMap(AccentChoice.init(rawValue:)) ?? .terracotta
        cardSize = defaults.string(forKey: "cardSize").flatMap(CardSize.init(rawValue:)) ?? .medium
        // These two default to on, so an absent key must not read as false.
        cropThumbnails = defaults.object(forKey: "cropThumbnails") == nil || defaults.bool(forKey: "cropThumbnails")
        showSidebarCounts = defaults.object(forKey: "showSidebarCounts") == nil
            || defaults.bool(forKey: "showSidebarCounts")
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
