import KeptCore
import SwiftUI

/// Settings › Agents: connect Claude Code, Codex and others to Kept's MCP server with one click.
struct AgentSettingsTab: View {
    @EnvironmentObject private var agents: AgentCenter

    /// Nil when this copy of Kept has no server it can hand to agents, with the reason to show instead.
    private static let serverProblem: String? = {
        guard let server = AgentLauncher.bundledServer else {
            return "This copy of Kept was built without its agent server. Build it with scripts/build-app.sh."
        }
        return AgentLauncher.isTemporaryLocation(server)
            ? "Move Kept to your Applications folder and reopen it before you connect an agent." : nil
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hand your captures to your coding agent").font(.headline)
                Text("Snip a few bugs, then tell a connected agent “Kept fix last 4”. Agents can read your latest captures and search your library. They cannot add, change or delete anything.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AgentDemo()

            if let problem = Self.serverProblem {
                Label(problem, icon: .warning)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(AgentClient.allCases) { client in
                    if client != AgentClient.allCases.first { Divider().padding(.leading, 46) }
                    AgentRow(client: client)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Any other MCP client").font(.callout.weight(.medium))
                HStack(alignment: .top, spacing: 8) {
                    Text(AgentLauncher.url.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor))
                        }
                    CopyButton(text: AgentLauncher.url.path)
                }
                Text("Run this as a stdio command. It stays the same when Kept moves or updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label {
                Text("Your library stays on this Mac, but an agent that runs its model in the cloud sends whatever it reads from Kept to that provider.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                KeptIcon.shieldWarning.image()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .task { await agents.refresh() }
        // Coming back from a terminal or from the agent itself: show what changed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await agents.refresh() }
        }
    }
}

private struct AgentRow: View {
    @EnvironmentObject private var agents: AgentCenter
    let client: AgentClient

    private var status: AgentStatus? { agents.statuses[client] }
    private var isWorking: Bool { agents.working.contains(client) }
    private var failure: String? { isWorking ? nil : agents.failures[client] }
    private var setupCommand: String? { agents.setupCommands[client] }

    private var caption: String {
        if isWorking { return "Working…" }
        if let failure { return failure }
        switch status {
        case nil: return "Checking…"
        case .connected:
            return agents.justConnected.contains(client) ? "Connected. Start a new session to use it." : "Connected"
        case .broken: return "Connected to a copy of Kept that is no longer there"
        case .notConnected: return "Not connected"
        case .notInstalled: return client.tool == nil ? "Not installed" : "Not found on this Mac"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            mark
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.name)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(failure != nil || status == .broken ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                actions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var mark: some View {
        switch status {
        case .connected: KeptIcon.checkCircle.image().foregroundStyle(.green)
        case .broken: KeptIcon.warning.image().foregroundStyle(.orange)
        default: KeptIcon.plugsConnected.image().foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        switch status {
        case .notConnected:
            Button("Connect") { Task { await agents.connect(client) } }
                .controlSize(.small)
                .accessibilityLabel("Connect \(client.name)")
        case .broken:
            Button("Reconnect") { Task { await agents.connect(client) } }
                .controlSize(.small)
                .accessibilityLabel("Reconnect \(client.name)")
        case .notInstalled:
            // The tool may still be somewhere Kept did not look: the command works from the user's terminal.
            if let setupCommand { CopyButton(text: setupCommand, title: "Copy Command") }
        case .connected, nil:
            EmptyView()
        }
        let hasEntry = status == .connected || status == .broken
        if hasEntry || (setupCommand != nil && status == .notConnected) {
            Menu {
                if status == .connected {
                    Button("Connect Again") { Task { await agents.connect(client) } }
                }
                if let setupCommand {
                    Button("Copy Setup Command") { copyToPasteboard(setupCommand) }
                }
                if hasEntry {
                    if status == .connected || setupCommand != nil { Divider() }
                    Button("Disconnect", role: .destructive) { Task { await agents.disconnect(client) } }
                }
            } label: {
                KeptIcon.dotsThreeCircle.image()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(client.name)")
        }
    }
}

@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    AppServices.shared.clipboard.markOwnWrite()
}

/// Copies `text`, confirming with a check mark. Shows an icon alone, or `title` when given.
private struct CopyButton: View {
    let text: String
    var title: String?
    @Local private var copied = false

    var body: some View {
        Button {
            copyToPasteboard(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            if let title {
                Text(copied ? "Copied" : title)
            } else {
                (copied ? KeptIcon.check : .copy).image()
            }
        }
        .controlSize(title == nil ? .regular : .small)
        .accessibilityLabel(copied ? "Copied" : title ?? "Copy")
        .help(title ?? "Copy")
    }
}
