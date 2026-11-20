import SwiftUI

enum LibraryPalette {
    static let canvas = adaptive(0xFBFBFC, 0x161618)
    static let sidebar = adaptive(0xF2F2F4, 0x1C1C1F)
    static let surface = adaptive(0xFFFFFF, 0x242427)
    static let inset = adaptive(0xE8E8EC, 0x2B2B30)
    static let line = adaptive(0xDDDDE2, 0x39393E)
    static let selection = adaptive(0xE5E5E9, 0x343438)
    /// Backing for link tiles, dark in both appearances so the white address stays readable.
    static let linkTile = adaptive(0x2C2C30, 0x303036)

    /// The accent the user chose in Settings › Appearance. A style rather than a fixed colour: it is looked
    /// up in the environment when drawn, so every view follows a change without observing the settings.
    static let accent = KeptAccent()

    static func heading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    fileprivate static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255,
                alpha: 1
            )
        })
    }
}

extension AccentChoice {
    private static let colors: [AccentChoice: Color] = Dictionary(uniqueKeysWithValues: allCases.map {
        ($0, LibraryPalette.adaptive($0.hex.light, $0.hex.dark))
    })

    /// Light or dark variant, following the appearance it is drawn in.
    var color: Color { Self.colors[self]! }

    /// Fill for system controls (prominent buttons, switches). They draw a white label on it, so a deep
    /// value is used in both appearances; the pale dark-mode accent would wash the label out.
    var controlColor: Color { Self.controlColors[self]! }

    private static let controlColors: [AccentChoice: Color] = Dictionary(uniqueKeysWithValues: allCases.map {
        ($0, LibraryPalette.adaptive($0.controlHex.light, $0.controlHex.dark))
    })
}

private struct AccentKey: EnvironmentKey {
    static let defaultValue = AccentChoice.terracotta
}

extension EnvironmentValues {
    var keptAccent: AccentChoice {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

struct KeptAccent: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.keptAccent.color
    }
}

/// Applies the user's accent to a window's content. Every window root uses it, including the panels
/// AppKit hosts, so a change in Settings shows everywhere at once.
struct KeptTheme: ViewModifier {
    @ObservedObject private var settings = AppServices.shared.settings

    func body(content: Content) -> some View {
        content
            .environment(\.keptAccent, settings.accent)
            .tint(settings.accent.controlColor)
    }
}

extension View {
    func keptTheme() -> some View { modifier(KeptTheme()) }
}
