import AppKit
import KeptCore
import SwiftUI

/// Long-lived objects shared by the windows, the menu bar and the global shortcuts.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let settings = CaptureSettings()
    let library: LibraryStore
    let connectors: ConnectorCenter
    let clipboard: ClipboardMonitor
    let snipper: SnipService
    let quickPanel: QuickPanelController

    /// Captured from SwiftUI so non-SwiftUI code can reopen the library window.
    var openLibraryWindow: (() -> Void)?
    var openSettingsWindow: (() -> Void)?

    private init() {
        do {
            try KeptPaths.ensure()
            let db = try Database(url: KeptPaths.database)
            library = LibraryStore(db: db)
            connectors = ConnectorCenter(db: db, library: library)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Kept could not open its library"
            alert.informativeText = "\(error)"
            alert.runModal()
            exit(1)
        }
        clipboard = ClipboardMonitor(library: library, settings: settings)
        snipper = SnipService(library: library)
        quickPanel = QuickPanelController(library: library)
        library.onOwnPasteboardWrite = { [clipboard] in clipboard.markOwnWrite() }
        library.onSnipSaved = { item in
            // The welcome flow and the library already show the result when Kept is in front.
            if !NSApp.isActive { SaveHUD.shared.show(item) }
        }
        HotKeyCenter.shared.onStatusChange = { [settings] in
            let center = HotKeyCenter.shared
            guard !center.suspended else { return }
            let names: [UInt32: String] = [1: "snip", 2: "quick search"]
            let broken = center.failed.sorted().compactMap { id in
                center.shortcut(for: id).map { "\($0.display) for \(names[id] ?? "Kept")" }
            }
            let warning = broken.isEmpty ? nil
                : "macOS would not register \(broken.joined(separator: " or ")). Another app may be using it; pick a different shortcut."
            if settings.shortcutWarning != warning { settings.shortcutWarning = warning }
        }
    }

    func start() {
        NSApp.appearance = settings.theme.appearance
        clipboard.start()
        library.resumePendingOCR()
        connectors.start()
        registerShortcuts()
        settings.onShortcutsChanged = { [weak self] in self?.registerShortcuts() }
        if !settings.didOnboard { library.showWelcome = true }
        DebugSnapshot.runIfRequested()
    }

    private func registerShortcuts() {
        HotKeyCenter.shared.set(id: 1, shortcut: settings.snipShortcut) { [weak self] in self?.snip() }
        HotKeyCenter.shared.set(id: 2, shortcut: settings.quickShortcut) { [weak self] in self?.quickPanel.toggle() }
    }

    func snip() {
        quickPanel.hide()
        snipper.snip()
    }

    func showLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("library") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openLibraryWindow?()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.shared.start()
    }

    /// Kept keeps running in the menu bar so shortcuts and capture work with the window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct KeptApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var settings = AppServices.shared.settings
    private let services = AppServices.shared

    var body: some Scene {
        Window("Kept", id: "library") {
            LibraryView()
                .environmentObject(services.library)
                .environmentObject(services.settings)
                .defaultAppStorage(KeptDefaults.store)
                .frame(minWidth: 780, minHeight: 480)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1160, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Take Snip") { services.snip() }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Save Clipboard to Library") { services.library.saveClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Import Images…") {
                    services.showLibrary()
                    services.library.showImportPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])
                Divider()
                Button("Quick Search…") { services.quickPanel.toggle() }
                    .keyboardShortcut("k", modifiers: [.command])
            }
            CommandGroup(replacing: .help) {
                Button("Show Welcome…") {
                    services.showLibrary()
                    services.library.showWelcome = true
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(services.library)
                .environmentObject(services.connectors)
                .environmentObject(services.settings)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(services.settings)
        } label: {
            MenuBarLabel(paused: settings.paused)
        }
    }
}

private struct MenuBarLabel: View {
    let paused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private static let mark: NSImage = {
        let image = Bundle.main.image(forResource: "KeptMenu") ?? NSApp.applicationIconImage!
        let mark = image.copy() as! NSImage
        mark.size = NSSize(width: 18, height: 18)
        mark.isTemplate = true
        return mark
    }()

    var body: some View {
        Image(nsImage: Self.mark)
            .opacity(paused ? 0.6 : 1)
            .accessibilityLabel(paused ? "Kept, clipboard capture paused" : "Kept")
            .onAppear {
                AppServices.shared.openLibraryWindow = { openWindow(id: "library") }
                AppServices.shared.openSettingsWindow = { openSettings() }
            }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var settings: CaptureSettings
    private let services = AppServices.shared

    var body: some View {
        Text(settings.statusLine)
        Divider()
        Button("Take Snip  \(settings.snipShortcut.display)") { services.snip() }
        Button("Quick Search  \(settings.quickShortcut.display)") { services.quickPanel.show() }
        Button("Save Clipboard to Library") { services.library.saveClipboard() }
        Divider()
        Button("Open Library") { services.showLibrary() }
        Toggle("Pause Clipboard Capture", isOn: $settings.paused)
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Kept") { NSApp.terminate(nil) }
    }
}
