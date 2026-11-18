import KeptCore
import SwiftUI

/// Settings › Connectors: the user's connections, and the sheet that signs in to a new one.
struct ConnectorSettingsTab: View {
    @EnvironmentObject private var center: ConnectorCenter
    @Local private var draft: ConnectionDraft? = DebugSnapshot.environment["KEPT_SNAPSHOT_SHEET"]
        .flatMap(ConnectorRegistry.connector).map { ConnectionDraft(connector: $0, existing: nil) }
    @Local private var removing: Connection?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bring in what you save elsewhere").font(.headline)
                Text("A connector signs in to a service and keeps adding what you save there. Kept only reads from the service and never changes anything on it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                if center.connections.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text("No connectors yet")
                        Text("Add one to start saving from it. You can add the same service more than once, for example with two accounts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 22)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(center.connections) { connection in
                                if connection.id != center.connections.first?.id { Divider().padding(.leading, 46) }
                                ConnectionRow(
                                    connection: connection,
                                    onEdit: {
                                        if let connector = connection.connector {
                                            draft = ConnectionDraft(connector: connector, existing: connection)
                                        }
                                    },
                                    onRemove: { removing = connection })
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor))
            }

            HStack {
                Menu("Add Connector") {
                    ForEach(ConnectorRegistry.all, id: \.id) { connector in
                        Button {
                            draft = ConnectionDraft(connector: connector, existing: nil)
                        } label: {
                            Label(connector.name, systemImage: connector.symbol)
                        }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Sync All Now") { center.syncAll() }
                    .disabled(!center.connections.contains { $0.enabled })
            }

            Label {
                Text("Sign-ins are stored in your Mac's Keychain. Kept contacts only the services you connect, about every half hour while it is running.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .sheet(item: $draft) { draft in
            ConnectSheet(draft: draft)
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "this connector")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { connection in
            Button("Remove Connector", role: .destructive) { center.remove(connection) }
        } message: { _ in
            Text("Kept forgets the sign-in and stops syncing. Items it already saved stay in your library.")
        }
    }
}

struct ConnectionDraft: Identifiable {
    let connector: any Connector
    let existing: Connection?
    var id: String { existing?.id ?? connector.id }
}

private struct ConnectionRow: View {
    @EnvironmentObject private var center: ConnectorCenter
    let connection: Connection
    let onEdit: () -> Void
    let onRemove: () -> Void

    private var isSyncing: Bool { center.syncing.contains(connection.id) }

    private var status: String {
        if isSyncing { return "Syncing…" }
        if let error = connection.lastError { return error }
        var parts: [String] = []
        if let account = connection.account, account != connection.name { parts.append(account) }
        parts.append(connection.imported == 1 ? "1 item saved" : "\(connection.imported) items saved")
        if !connection.enabled {
            parts.append("paused")
        } else if let date = connection.lastSync {
            let recent = Date().timeIntervalSince(date) < 60
            parts.append(recent ? "synced just now" : "synced " + date.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: connection.connector?.symbol ?? "questionmark.circle")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(connection.lastError != nil && !isSyncing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if connection.needsSignIn, !isSyncing {
                Button("Sign In Again…", action: onEdit)
                    .controlSize(.small)
            }
            Toggle("Sync \(connection.name)", isOn: Binding(
                get: { connection.enabled },
                set: { center.setEnabled(connection, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Menu {
                Button("Sync Now") { center.sync(connection.id) }
                    .disabled(isSyncing || !connection.enabled)
                Button("Edit…", action: onEdit)
                    .disabled(connection.connector == nil)
                Divider()
                Button("Remove…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(connection.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// Sign-in sheet, built from the fields the connector declares.
private struct ConnectSheet: View {
    @EnvironmentObject private var center: ConnectorCenter
    @Environment(\.dismiss) private var dismiss
    let draft: ConnectionDraft

    @Local private var name: String
    @Local private var values: [String: String]
    @Local private var working = false
    @Local private var failure: String?

    init(draft: ConnectionDraft) {
        self.draft = draft
        _name = Local(wrappedValue: draft.existing?.name ?? "")
        _values = Local(wrappedValue: draft.existing?.config ?? [:])
    }

    private var connector: any Connector { draft.connector }

    /// Secrets may stay empty when editing: the stored one is kept.
    private var isComplete: Bool {
        connector.fields.allSatisfy { field in
            (field.isSecret && draft.existing != nil)
                || !(values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: connector.symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.existing == nil ? "Connect \(connector.name)" : "Edit \(draft.existing!.name)")
                        .font(.headline)
                    Text(connector.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(connector.fields) { field in
                    GridRow {
                        Text(field.label).gridColumnAlignment(.trailing)
                        let text = Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 })
                        if field.isSecret {
                            SecureField(
                                field.label,
                                text: text,
                                prompt: Text(draft.existing == nil ? field.placeholder : "Leave empty to keep the current one"))
                                .labelsHidden()
                        } else {
                            TextField(field.label, text: text, prompt: Text(field.placeholder))
                                .labelsHidden()
                        }
                    }
                }
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Name", text: $name, prompt: Text("Optional"))
                        .labelsHidden()
                }
            }
            .textFieldStyle(.roundedBorder)

            if let help = connector.help {
                VStack(alignment: .leading, spacing: 3) {
                    if let note = help.note {
                        Text(note)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Link(destination: help.url) {
                        Label(help.title, systemImage: "arrow.up.forward.square")
                    }
                }
                .font(.callout)
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.existing == nil ? "Connect" : "Save") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !isComplete)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func connect() {
        working = true
        failure = nil
        Task {
            do {
                try await center.connect(connector, name: name, values: values, existing: draft.existing)
                dismiss()
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            working = false
        }
    }
}
