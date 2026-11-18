import AppKit
import ScreenCaptureKit

/// Region snip: drag a rectangle, the image lands on the clipboard and in the library exactly once.
@MainActor
final class SnipService: NSObject, SCContentSharingPickerObserver {
    private var pickerSource: NSRunningApplication?
    private let library: LibraryStore
    private var running = false

    init(library: LibraryStore) {
        self.library = library
    }

    func snip() {
        guard !running else { return }

        let source = NSWorkspace.shared.frontmostApplication
        if !CGPreflightScreenCaptureAccess() {
            running = true
            pickerSource = source
            let picker = SCContentSharingPicker.shared
            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = [.singleDisplay]
            picker.defaultConfiguration = configuration
            picker.add(self)
            picker.isActive = true
            picker.present(using: .display)
            return
        }

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
            save(data, source: source)
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

    private func save(_ png: Data, source: NSRunningApplication?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        library.onOwnPasteboardWrite?()
        library.ingest(.image(png), method: .snip, source: source, select: true)
    }

    private func closePicker() {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
        pickerSource = nil
        running = false
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in closePicker() }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            closePicker()
            report(error)
        }
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.userDeclined.rawValue {
            // macOS refused the capture. If Kept already shows as enabled in System Settings, the grant
            // belongs to a differently signed copy of Kept and has to be given again to this one.
            library.errorMessage = """
            macOS is not allowing Kept to capture the screen. Open System Settings › Privacy & Security › \
            Screen & System Audio Recording, turn Kept off and on again (or remove it with − and add this \
            copy of Kept), then quit and reopen Kept.
            """
        } else {
            library.errorMessage = "Kept could not take a snip. " + error.localizedDescription
        }
        AppServices.shared.showLibrary()
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            defer { closePicker() }
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int((filter.contentRect.width * scale).rounded())
            config.height = Int((filter.contentRect.height * scale).rounded())
            config.showsCursor = false
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                if let crop = SnipCropView.select(in: image),
                   let data = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
                    save(data, source: pickerSource)
                }
            } catch {
                report(error)
            }
        }
    }
}
