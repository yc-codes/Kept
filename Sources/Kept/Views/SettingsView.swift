import KeptCore
import SwiftUI

struct SettingsView: View {
    @Local private var tab = DebugSnapshot.environment["KEPT_SNAPSHOT_TAB"] ?? "capture"
    @FocusState private var stripFocused: Bool

    private static let tabs: [(id: String, title: String, icon: KeptIcon)] = [
        ("capture", "Capture", .archiveTray), ("connectors", "Connectors", .plugsConnected),
        ("appearance", "Appearance", .sun), ("shortcuts", "Shortcuts", .keyboard), ("agents", "Agents", .sparkle),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Kept's own tab strip: the system one always marks the selected tab in the macOS accent
            // colour, whatever accent the user picked for Kept.
            HStack(spacing: 4) {
                ForEach(Self.tabs, id: \.id) { entry in
                    SettingsTabButton(title: entry.title, icon: entry.icon, selected: tab == entry.id) {
                        tab = entry.id
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            // One Tab stop for the whole strip, as with system tabs: Tab reaches it, the arrow keys move
            // between sections.
            .focusable(true, interactions: .edit)
            .focused($stripFocused)
            .onKeyPress(.leftArrow) { move(-1) }
            .onKeyPress(.rightArrow) { move(1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Settings sections")

            Divider()

            Group {
                switch tab {
                case "connectors": ConnectorSettingsTab()
                case "appearance": AppearanceSettingsTab()
                case "shortcuts": ShortcutSettingsTab()
                case "agents": AgentSettingsTab()
                default: CaptureSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .keptTheme()
    }
}

private extension SettingsView {
    func move(_ delta: Int) -> KeyPress.Result {
        let ids = Self.tabs.map(\.id)
        guard let index = ids.firstIndex(of: tab) else { return .ignored }
        tab = ids[min(max(index + delta, 0), ids.count - 1)]
        return .handled
    }
}

private struct SettingsTabButton: View {
    let title: String
    let icon: KeptIcon
    let selected: Bool
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                icon.image(size: 22)
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(selected ? AnyShapeStyle(LibraryPalette.accent) : AnyShapeStyle(.secondary))
            .frame(width: 84, height: 48)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(LibraryPalette.accent.opacity(0.14)) }
        return AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0))
    }
}

private struct CaptureSettingsTab: View {
    @EnvironmentObject private var settings: CaptureSettings
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What Kept saves on this Mac").font(.headline)
                CaptureSourceList()
                Toggle("Pause clipboard capture (snips and manual saves still work)", isOn: $settings.paused)
                    .toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Excluded apps").font(.headline)
                ExclusionsEditor()
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Library location")
                    Text(KeptPaths.root.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(KeptPaths.root) }
                Button("Show Welcome…") {
                    AppServices.shared.showLibrary()
                    library.showWelcome = true
                }
            }
        }
        .padding(20)
    }
}

private struct ShortcutSettingsTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Global shortcuts").font(.headline)
            ShortcutRows()
            Text("In the library: Space previews, Return opens the original, ⌘C copies, Delete removes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
