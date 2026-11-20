import AppKit

/// Development aid: renders Kept's own windows to PNG files so the UI can be reviewed without
/// Screen Recording permission. Inactive unless `KEPT_SNAPSHOT_DIR` is set.
///   KEPT_SNAPSHOT_SHOW = welcome | quick | settings | select   (optional)
///   KEPT_SNAPSHOT_STEP = 0...3                                  (welcome step)
///   KEPT_SNAPSHOT_IMPORT = /a.png:/b.gif                        (files to import first)
///   KEPT_SNAPSHOT_TAB = capture | connectors | appearance | …   (settings tab to open on)
///   KEPT_SNAPSHOT_SHEET = <connector id>                        (open that connector's sign-in sheet)
///   KEPT_SNAPSHOT_CONNECT = feed|url=https://…;github-stars|token=…   (connections to add first)
@MainActor
enum DebugSnapshot {
    static let environment = ProcessInfo.processInfo.environment
    static var welcomeStep: Int { Int(environment["KEPT_SNAPSHOT_STEP"] ?? "") ?? 0 }

    static func runIfRequested() {
        guard let directory = environment["KEPT_SNAPSHOT_DIR"], !directory.isEmpty else { return }
        if let name = environment["KEPT_SNAPSHOT_APPEARANCE"], ["light", "dark"].contains(name) {
            NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        }
        let services = AppServices.shared
        let show = environment["KEPT_SNAPSHOT_SHOW"] ?? ""

        // A fixed delay is not enough on a cold start (a freshly signed build can take several seconds to
        // put its window up), so wait for the library window before driving the UI, then give it time to
        // settle before capturing.
        whenLibraryWindowIsUp(deadline: Date().addingTimeInterval(15)) {
            prepare(services: services, show: show)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { capture(show: show, into: directory) }
        }
    }

    private static func whenLibraryWindowIsUp(deadline: Date, _ action: @escaping @MainActor () -> Void) {
        let ready = NSApp.windows.contains {
            $0.isVisible && $0.identifier?.rawValue.contains("library") == true && $0.frame.width > 100
        }
        if ready || Date() > deadline {
            // One more beat so the window has finished becoming key before anything is shown over it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { action() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                whenLibraryWindowIsUp(deadline: deadline, action)
            }
        }
    }

    private static func prepare(services: AppServices, show: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let path = environment["KEPT_SNAPSHOT_IMPORT"] {
            services.library.importFiles(path.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        for spec in (environment["KEPT_SNAPSHOT_CONNECT"] ?? "").split(separator: ";") {
            let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
            guard let connector = ConnectorRegistry.connector(parts[0]) else { continue }
            let pairs = (parts.count > 1 ? parts[1] : "").split(separator: "&").compactMap { pair -> (String, String)? in
                let sides = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return sides.count == 2 ? (sides[0], sides[1]) : nil
            }
            Task {
                do {
                    try await services.connectors.connect(
                        connector, name: "", values: Dictionary(pairs) { $1 })
                } catch { NSLog("Kept: snapshot connect failed: \(error)") }
            }
        }
        // Activation finishes a moment after it is asked for and makes the library window key. The quick
        // panel hides when it loses key, so anything shown over the library waits for that to be over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            switch show {
            case "welcome": services.library.showWelcome = true
            case "quick": services.quickPanel.show()
            case "settings": services.openSettingsWindow?()
            case "select": services.library.selectedID = services.library.items.first { $0.kind == .image }?.id
            default: break
            }
        }
    }

    private static func capture(show: String, into directory: String) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  view.bounds.width > 100,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = "\(show.isEmpty ? "library" : show)-\(index).png"
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        exit(0)
    }
}
