import SwiftUI

enum LibraryPalette {
    static let canvas = adaptive(0xFBFBFC, 0x161618)
    static let sidebar = adaptive(0xF2F2F4, 0x1C1C1F)
    static let surface = adaptive(0xFFFFFF, 0x242427)
    static let inset = adaptive(0xE8E8EC, 0x2B2B30)
    static let line = adaptive(0xDDDDE2, 0x39393E)
    static let accent = adaptive(0xA93820, 0xFF9A79)
    static let selection = adaptive(0xE5E5E9, 0x343438)

    static func heading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
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
