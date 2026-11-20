import AppKit
import SwiftUI

// Looping illustrations that show how Kept works. Drawn in SwiftUI rather than shipped as GIF files so
// they stay sharp at any size, follow light and dark mode, and stop for Reduce Motion.

/// Drives its content with a 0...1 progress value that repeats every `period` seconds.
struct Loop<Content: View>: View {
    let period: Double
    /// Progress shown when Reduce Motion is on: a frame where the story has finished.
    var resting = 0.85
    @ViewBuilder let content: (Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            content(resting)
        } else {
            TimelineView(.animation) { context in
                content(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
            }
        }
    }
}

/// Eased 0...1 ramp of `progress` between `start` and `end`.
private func ramp(_ progress: Double, _ start: Double, _ end: Double) -> Double {
    let x = min(max((progress - start) / (end - start), 0), 1)
    return x * x * (3 - 2 * x)
}

private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

// MARK: Snip

/// Drag over part of the screen; the snip lands on the clipboard and in the library.
struct SnipDemo: View {
    @Environment(\.keptAccent) private var accentChoice
    private var accent: Color { accentChoice.color }

    var body: some View {
        Loop(period: 5.2) { p in
            ZStack(alignment: .topLeading) {
                screen
                selection(p)
                destination(.clipboard, "Clipboard", y: 14, p: p)
                destination(.tray, "Library", y: 92, p: p)
                flyer(p, toY: 22)
                flyer(p, toY: 100)
                cursor(p)
            }
            .frame(width: 360, height: 168, alignment: .topLeading)
        }
        .accessibilityElement()
        .accessibilityLabel("Animation: dragging over part of the screen copies the snip and saves it to the library")
    }

    // The picture the demo snips, in screen coordinates.
    private let photo = CGRect(x: 22, y: 46, width: 112, height: 78)

    private var screen: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.75)).frame(width: 7, height: 7)
                }
            }
            .offset(x: 12, y: 12)
            photoTile
                .frame(width: photo.width, height: photo.height)
                .offset(x: photo.minX, y: photo.minY)
            VStack(alignment: .leading, spacing: 9) {
                ForEach([62.0, 48, 56, 34], id: \.self) { width in
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(width: width, height: 7)
                }
            }
            .offset(x: 150, y: 52)
        }
        .frame(width: 232, height: 150)
        .offset(y: 9)
    }

    private var photoTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [.orange.opacity(0.85), .pink.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            KeptIcon.mountains.image(size: 26)
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private func selection(_ p: Double) -> some View {
        let grow = ramp(p, 0.10, 0.38)
        let fade = 1 - ramp(p, 0.44, 0.52)
        let target = photo.insetBy(dx: -7, dy: -7)
        return RoundedRectangle(cornerRadius: 3)
            .fill(accent.opacity(0.14 + 0.5 * flash(p)))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            .frame(width: max(target.width * grow, 0.1), height: max(target.height * grow, 0.1))
            .offset(x: target.minX, y: target.minY + 9)
            .opacity(grow > 0 ? fade : 0)
    }

    private func flash(_ p: Double) -> Double {
        ramp(p, 0.38, 0.42) * (1 - ramp(p, 0.42, 0.48))
    }

    private func cursor(_ p: Double) -> some View {
        let grow = ramp(p, 0.10, 0.38)
        let target = photo.insetBy(dx: -7, dy: -7)
        return KeptIcon.plus.image(size: 13)
            .foregroundStyle(Color.primary)
            .offset(x: target.minX + target.width * grow - 7, y: target.minY + 9 + target.height * grow - 8)
            .opacity((1 - ramp(p, 0.40, 0.46)) * ramp(p, 0.0, 0.05))
    }

    /// A copy of the snip travelling to one of the two destinations.
    private func flyer(_ p: Double, toY: Double) -> some View {
        let t = ramp(p, 0.46, 0.70)
        let scale = mix(1, 0.3, t)
        return photoTile
            .frame(width: photo.width, height: photo.height)
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: mix(photo.minX, 286, t), y: mix(photo.minY + 9, toY, t))
            .opacity(t > 0 ? 1 - ramp(p, 0.66, 0.72) : 0)
    }

    private func destination(_ symbol: KeptIcon, _ title: String, y: Double, p: Double) -> some View {
        let landed = ramp(p, 0.68, 0.76) * (1 - ramp(p, 0.94, 1.0))
        return VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                symbol.image(size: 20)
                    .foregroundStyle(landed > 0.5 ? accent : Color.secondary)
                KeptIcon.checkCircle.image(size: 12)
                    .foregroundStyle(.green)
                    .scaleEffect(landed)
                    .offset(x: 7, y: 4)
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 84, height: 62)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(landed > 0.5 ? accent.opacity(0.6) : Color(nsColor: .separatorColor))
        }
        .offset(x: 268, y: y)
    }
}

// MARK: Shortcut

/// Key caps for a shortcut, pressed together in a loop.
struct ShortcutDemo: View {
    @Environment(\.keptAccent) private var accentChoice
    private var accent: Color { accentChoice.color }

    let shortcut: Shortcut
    let caption: String

    private var keys: [String] {
        var modifiers: [String] = []
        var rest = ""
        for character in shortcut.display {
            if "⌃⌥⇧⌘".contains(character) { modifiers.append(String(character)) } else { rest.append(character) }
        }
        return modifiers + (rest.isEmpty ? [] : [rest])
    }

    var body: some View {
        Loop(period: 2.8, resting: 0) { p in
            let down = ramp(p, 0.18, 0.26) * (1 - ramp(p, 0.46, 0.56))
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(keys, id: \.self) { key in
                        Text(key)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .frame(minWidth: 30, minHeight: 30)
                            .padding(.horizontal, key.count > 1 ? 8 : 0)
                            .background {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.25), radius: 0, y: 2 - 2 * down)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(down > 0.5 ? accent : Color(nsColor: .separatorColor))
                            }
                            .offset(y: 2 * down)
                    }
                }
                KeptIcon.arrowRight.image(size: 13)
                    .foregroundStyle(.tertiary)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(down > 0.5 ? Color.primary : Color.secondary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(shortcut.display): \(caption)")
    }
}

/// A small stack of saved media, shared by onboarding and the empty library.
struct CaptureStack: View {
    @Environment(\.keptAccent) private var accentChoice

    var body: some View {
        ZStack {
            tile(.textAlignLeft, background: LibraryPalette.surface, ink: .secondary)
                .rotationEffect(.degrees(-14))
                .offset(x: -48, y: 7)
            tile(.link, background: LibraryPalette.selection, ink: .primary)
                .rotationEffect(.degrees(15))
                .offset(x: 48, y: 4)
            tile(.cornersOut, background: accentChoice.color, ink: LibraryPalette.surface)
                .rotationEffect(.degrees(-5))
        }
        .frame(width: 210, height: 110)
        .accessibilityHidden(true)
    }

    private func tile(_ symbol: KeptIcon, background: Color, ink: Color) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(background)
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(LibraryPalette.line)
            }
            .overlay {
                symbol.image(size: 30).foregroundStyle(ink)
            }
            .frame(width: 78, height: 80)
    }
}

// MARK: Agent

/// "Kept fix last 4": an agent picks up the latest snips and fixes what each one shows.
struct AgentDemo: View {
    @Environment(\.keptAccent) private var accentChoice
    private var accent: Color { accentChoice.color }

    private let request = "Kept fix last 4"
    private let snips: [(title: String, colors: [Color])] = [
        ("Clipped title", [.orange.opacity(0.85), .pink.opacity(0.8)]),
        ("Button overlap", [.blue.opacity(0.75), .purple.opacity(0.75)]),
        ("Wrong total", [.teal.opacity(0.8), .green.opacity(0.7)]),
        ("Dead link", [.indigo.opacity(0.75), .pink.opacity(0.7)]),
    ]

    // The story, as fractions of one loop: type the request, the snips arrive, each gets fixed, hold, fade.
    private func arrived(_ index: Int, _ p: Double) -> Double {
        ramp(p, 0.22 + 0.03 * Double(index), 0.27 + 0.03 * Double(index))
    }

    private func fixed(_ index: Int, _ p: Double) -> Double {
        ramp(p, 0.42 + 0.11 * Double(index), 0.46 + 0.11 * Double(index))
    }

    var body: some View {
        Loop(period: 9, resting: 0.9) { p in
            let typed = Int((Double(request.count) * ramp(p, 0.03, 0.16)).rounded())
            let fixedCount = snips.indices.filter { fixed($0, p) > 0.5 }.count
            let fade = 1 - ramp(p, 0.96, 1.0)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer(minLength: 40)
                    Text(String(request.prefix(max(typed, 1))))
                        .font(.callout)
                        .foregroundStyle(LibraryPalette.surface)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                HStack(alignment: .top, spacing: 8) {
                    ForEach(snips.indices, id: \.self) { index in
                        snip(index, arrived: arrived(index, p) * fade, fixed: fixed(index, p))
                    }
                }
                HStack(spacing: 5) {
                    if fixedCount == snips.count {
                        KeptIcon.checkCircle.image(size: 13)
                            .foregroundStyle(.green)
                        Text("Fixed \(snips.count) of \(snips.count)")
                    } else {
                        KeptIcon.sparkle.image(size: 13)
                        Text(p < 0.40 ? "Reading your last \(snips.count) captures from Kept…"
                             : "Fixing \(fixedCount + 1) of \(snips.count)…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(ramp(p, 0.18, 0.22) * fade)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Animation: telling an agent “Kept fix last 4” brings in the four latest snips, and it fixes what each one shows")
    }

    /// One snip: a problem badge until the agent has dealt with it, a check mark after.
    private func snip(_ index: Int, arrived: Double, fixed: Double) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: snips[index].colors, startPoint: .top, endPoint: .bottom))
                .frame(height: 40)
                .overlay {
                    KeptIcon.window.image()
                        .foregroundStyle(.white.opacity(0.9))
                }
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        Circle().fill(Color(nsColor: .textBackgroundColor))
                        KeptIcon.warning.image(size: 11)
                            .foregroundStyle(.orange)
                            .opacity(1 - fixed)
                        KeptIcon.checkCircle.image(size: 13)
                            .foregroundStyle(.green)
                            .scaleEffect(fixed)
                    }
                    .frame(width: 17, height: 17)
                    .offset(x: 5, y: -5)
                }
            Text(snips[index].title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .opacity(arrived)
        .offset(y: 6 * (1 - arrived))
    }
}

// MARK: Animated GIFs

/// Plays an animated GIF from disk. SwiftUI's `Image` only shows the first frame.
struct AnimatedImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            view.image = NSImage(contentsOf: url)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var url: URL?
    }
}
