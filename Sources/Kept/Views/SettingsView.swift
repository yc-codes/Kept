import KeptCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: CaptureSettings

    var body: some View {
        TabView {
            CaptureSettingsTab()
                .tabItem { Label("Capture", systemImage: "tray.and.arrow.down") }
            Picker("Theme", selection: $settings.theme) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.rawValue.capitalized).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .padding(24)
            .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            ShortcutSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AgentSettingsTab()
                .tabItem { Label("Agents", systemImage: "sparkles") }
        }
        .frame(width: 560)
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

private struct AgentSettingsTab: View {
    private var serverPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/kept-mcp").path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask Claude Code or Codex about your library").font(.headline)
                Text("Kept includes a read-only MCP server. Connected agents can search your library and open items by ID. They cannot add, change or delete anything.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AgentDemo()
            command("Claude Code", "claude mcp add --scope user kept -- \"\(serverPath)\"")
            command("Codex", "codex mcp add kept -- \"\(serverPath)\"")
            command("Other MCP clients (stdio command)", serverPath)
            Label {
                Text("Your library stays on this Mac, but an agent that runs its model in the cloud sends whatever it reads from Kept to that provider.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.shield")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func command(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            HStack(alignment: .top, spacing: 8) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor))
                    }
                CopyButton(text: text)
            }
        }
    }
}

private struct CopyButton: View {
    let text: String
    @Local private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            AppServices.shared.clipboard.markOwnWrite()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .frame(width: 16)
        }
        .help("Copy")
    }
}
