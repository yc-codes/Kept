import AppKit

/// Region snip: drag a rectangle, the image lands on the clipboard and in the library exactly once.
@MainActor
final class SnipService {
    private let library: LibraryStore
    private var running = false

    init(library: LibraryStore) {
        self.library = library
    }

    func snip() {
        guard !running else { return }
        guard ensureScreenRecordingAccess() else { return }

        let source = NSWorkspace.shared.frontmostApplication
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kept-snip-\(UUID().uuidString).png")
        let clipboardBefore = NSPasteboard.general.changeCount
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: interactive selection (Space switches to window mode, Esc cancels). -x: no shutter sound.
        process.arguments = ["-i", "-x", "-t", "png", file.path]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.finish(file: file, source: source, clipboardBefore: clipboardBefore) }
        }
        do {
            try process.run()
            running = true
        } catch {
            NSLog("Kept: could not start screencapture: \(error)")
        }
    }

    private func finish(file: URL, source: NSRunningApplication?, clipboardBefore: Int) {
        running = false
        defer { try? FileManager.default.removeItem(at: file) }
        let pasteboard = NSPasteboard.general

        if let data = try? Data(contentsOf: file), !data.isEmpty {
            // Clipboard first, so pasting works before the library has finished saving.
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            library.onOwnPasteboardWrite?()
            library.ingest(.image(data), method: .snip, source: source, select: true)
            return
        }

        // No file. Usually that is a cancelled snip, which saves nothing. But holding Control while
        // selecting makes screencapture put the image on the clipboard instead of in the file, which is
        // easy to do with a ⌃ shortcut. That case is recognisable: the clipboard changed during the
        // capture and now holds only an image.
        guard pasteboard.changeCount != clipboardBefore else { return }
        let types = pasteboard.types ?? []
        guard !types.contains(.string), !types.contains(.fileURL),
              let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        else { return }
        library.onOwnPasteboardWrite?()
        library.ingest(.image(data), method: .snip, source: source, select: true)
    }

    private func ensureScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }

        let defaults = KeptDefaults.store
        if !defaults.bool(forKey: "askedScreenRecording") {
            // First time: let the system prompt explain itself.
            defaults.set(true, forKey: "askedScreenRecording")
            if CGRequestScreenCaptureAccess() { return true }
            return false
        }

        let alert = NSAlert()
        alert.messageText = "Kept needs Screen Recording access to take snips"
        alert.informativeText = """
        Turn on Kept under System Settings › Privacy & Security › Screen & System Audio Recording, \
        then reopen Kept. Kept only captures the region you drag over, when you press the snip shortcut.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Reopen Kept")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
        return false
    }

    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}
