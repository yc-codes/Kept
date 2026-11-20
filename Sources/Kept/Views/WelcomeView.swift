import KeptCore
import SwiftUI

/// First launch: say what Kept can save, let the user choose, then prove it with a practice snip.
struct WelcomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: CaptureSettings
    @Local private var step = DebugSnapshot.welcomeStep
    @Local private var practiceSnip: Item? = nil
    @Local private var showExclusions = false

    private let lastStep = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: intro
                case 1: sources
                case 2: shortcuts
                default: practice
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0...lastStep, id: \.self) { index in
                        Circle()
                            .fill(index == step ? AnyShapeStyle(LibraryPalette.accent) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if step < lastStep {
                    // Prominent style so the button takes Kept's accent; a plain default button is always
                    // drawn in the macOS accent colour.
                    Button("Continue") { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(practiceSnip == nil ? "Skip for Now" : "Open Library", action: finish)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 600, height: 560)
        .background(LibraryPalette.canvas)
        .keptTheme()
        .onChange(of: library.lastSnip) {
            if step == lastStep { practiceSnip = library.lastSnip }
        }
    }

    private func finish() {
        settings.didOnboard = true
        library.showWelcome = false
    }

    // MARK: Steps

    private var intro: some View {
        VStack(spacing: 22) {
            CaptureStack()
            VStack(spacing: 6) {
                Text("Welcome to Kept")
                    .font(LibraryPalette.heading(38))
                Text("A library for the things worth keeping, stored on this Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                point(.cornersOut, "Snip and keep working",
                      "Drag over part of your screen. It is on your clipboard to paste, and saved in your library.")
                point(.note, "Remember why",
                      "Add your own note to anything. Kept also reads the text inside images so you can search it.")
                point(.magnifyingGlass, "Find it again, or ask",
                      "Browse the library, search from any app, or let Claude Code and Codex look things up for you.")
            }
            .padding(.top, 4)
        }
    }

    private func point(_ icon: KeptIcon, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            icon.image(size: 22)
                .foregroundStyle(LibraryPalette.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(LibraryPalette.heading(32))
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                "Choose what Kept saves",
                "Nothing you copy is saved until you switch it on here. You can change this any time in Settings, and pause clipboard capture from the menu bar.")
            CaptureSourceList()
            DisclosureGroup(isExpanded: $showExclusions) {
                ExclusionsEditor(height: 84)
                    .padding(.top, 6)
            } label: {
                Text(exclusionSummary)
                    .font(.callout)
            }
            .opacity(settings.anyClipboardCapture ? 1 : 0.5)
            .disabled(!settings.anyClipboardCapture)
        }
    }

    private var exclusionSummary: String {
        let count = settings.excludedApps.count
        if count == 0 { return "Excluded apps: password managers" }
        return "Excluded apps: password managers and \(count) more"
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                "Pick your shortcuts",
                "These work in every app while Kept is running. Click a shortcut, then press the keys you want.")
            ShortcutRows()
            ShortcutDemos(snip: settings.snipShortcut, search: settings.quickShortcut)
                .padding(.vertical, 4)
            Label("Kept stays in the menu bar when you close its window, so the shortcuts keep working.", icon: .window)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                "Take a practice snip",
                "macOS will ask you to allow Screen Recording the first time. Kept only captures the region you drag over, and only when you press the shortcut.")

            if let snip = practiceSnip {
                VStack(spacing: 12) {
                    ThumbnailView(item: snip)
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor))
                        }
                    Label {
                        Text("Saved once to your library and copied. Press ⌘V in any app to paste it.")
                    } icon: {
                        KeptIcon.checkCircle.image().foregroundStyle(.green)
                    }
                    Button("Snip Again") { AppServices.shared.snip() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 14) {
                    SnipDemo()
                    Button("Take a Practice Snip") { AppServices.shared.snip() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Text("or press \(settings.snipShortcut.display), then drag. Press Esc to cancel; a cancelled snip saves nothing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Kept will save:")
                    .font(.callout.weight(.semibold))
                Text(settings.statusLine.replacingOccurrences(of: "Saving ", with: "").capitalizedFirst + ".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
