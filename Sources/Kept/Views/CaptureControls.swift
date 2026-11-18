import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The capture switches. Used on first launch and in Settings so both always show the same thing.
struct CaptureSourceList: View {
    @EnvironmentObject private var settings: CaptureSettings

    var body: some View {
        VStack(spacing: 0) {
            row(
                symbol: "camera.viewfinder", title: "Region snips",
                detail: "Only when you press \(settings.snipShortcut.display) and drag over part of the screen."
            ) {
                Text("On demand")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.leading, 46)
            row(symbol: "photo", title: "Copied images", detail: "Pictures and screenshots you copy in any app.") {
                Toggle("Copied images", isOn: $settings.captureImages).labelsHidden()
            }
            Divider().padding(.leading, 46)
            row(symbol: "link", title: "Copied links", detail: "Web addresses you copy, such as from the address bar.") {
                Toggle("Copied links", isOn: $settings.captureLinks).labelsHidden()
            }
            Divider().padding(.leading, 46)
            row(symbol: "text.alignleft", title: "Copied text", detail: "Any other text you copy. The broadest option.") {
                Toggle("Copied text", isOn: $settings.captureText).labelsHidden()
            }
        }
        .toggleStyle(.switch)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor))
        }
    }

    private func row<Control: View>(
        symbol: String, title: String, detail: String, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct ExclusionsEditor: View {
    @EnvironmentObject private var settings: CaptureSettings
    @Local private var selection: String? = nil
    var height: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selection) {
                ForEach(settings.excludedApps) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: icon(for: app.bundleID))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(app.name)
                    }
                    .tag(app.bundleID)
                }
            }
            .listStyle(.bordered)
            .frame(height: height)
            .overlay {
                if settings.excludedApps.isEmpty {
                    Text("No extra apps excluded")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                Button("Add App…", action: addApp)
                Button("Remove") {
                    settings.excludedApps.removeAll { $0.bundleID == selection }
                    selection = nil
                }
                .disabled(selection == nil)
                Spacer()
            }
            .controlSize(.small)
            Text("Nothing copied in these apps is saved. Password managers and items apps mark as private are always skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !settings.excludedApps.contains(where: { $0.bundleID == bundleID })
            else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            settings.excludedApps.append(ExcludedApp(bundleID: bundleID, name: name))
        }
    }
}

/// Click, then press the new key combination. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    /// The other Kept shortcut, which this one must not duplicate.
    let other: Shortcut
    @Local private var recording = false
    @Local private var monitor: Any? = nil
    @Local private var rejected = false

    /// Stops whichever recorder is currently listening, so only one ever is.
    @MainActor private static var stopActive: (() -> Void)?

    var body: some View {
        Button(action: { recording ? stop() : start() }) {
            Text(recording ? (rejected ? "Already used" : "Press shortcut…") : shortcut.display)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 118)
        }
        .help("Click, then press a key combination that includes ⌘, ⌥ or ⌃")
        .onDisappear(perform: stop)
        // Recording must not outlive the window's focus, or shortcuts would stay switched off.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func start() {
        Self.stopActive?()
        recording = true
        rejected = false
        Self.stopActive = stop
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
            } else if let new = Shortcut(event: event) {
                if new.keyCode == other.keyCode, new.modifiers == other.modifiers {
                    rejected = true
                    NSSound.beep()
                } else {
                    shortcut = new
                    stop()
                }
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        rejected = false
        Self.stopActive = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeyCenter.shared.resume()
    }
}

struct ShortcutRows: View {
    @EnvironmentObject private var settings: CaptureSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                row("Take a snip", "Drag over part of the screen. It is copied and saved.",
                    $settings.snipShortcut, other: settings.quickShortcut)
                Divider().padding(.leading, 12)
                row("Quick search", "Find and copy a saved item from any app.",
                    $settings.quickShortcut, other: settings.snipShortcut)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor))
            }
            if let warning = settings.shortcutWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ title: String, _ detail: String, _ binding: Binding<Shortcut>, other: Shortcut) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ShortcutRecorder(shortcut: binding, other: other)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
