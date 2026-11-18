import AppKit
import UniformTypeIdentifiers

@objc(KeptShareViewController)
final class ShareViewController: NSViewController {
    private var started = false

    override func loadView() {
        view = NSTextField(labelWithString: "Sharing to Kept…")
        preferredContentSize = NSSize(width: 220, height: 60)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started, let context = extensionContext else { return }
        started = true
        Task {
            do {
                let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
                let providers = items.flatMap { $0.attachments ?? [] }
                let payload: Data
                let suffix: String
                if let provider = providers.first, providers.count == 1 {
                    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        payload = try await withCheckedThrowingContinuation { continuation in
                            _ = provider.loadDataRepresentation(for: .image) { data, error in
                                if let data { continuation.resume(returning: data) }
                                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
                            }
                        }
                        suffix = "keptimage"
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                              let url = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                        if url.isFileURL {
                            guard try url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image) == true else {
                                throw CocoaError(.fileReadUnsupportedScheme)
                            }
                            payload = try Data(contentsOf: url, options: .mappedIfSafe)
                            suffix = "keptimage"
                        } else {
                            payload = Data(url.absoluteString.utf8)
                            suffix = "kepttext"
                        }
                    } else {
                        let value = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
                        guard let text = value as? String else { throw CocoaError(.fileReadCorruptFile) }
                        payload = Data(text.utf8)
                        suffix = "kepttext"
                    }
                } else if providers.isEmpty, let text = items.first?.attributedContentText?.string {
                    payload = Data(text.utf8)
                    suffix = "kepttext"
                } else { throw CocoaError(.fileReadCorruptFile) }

                guard !payload.isEmpty, payload.count < 60_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let manager = FileManager.default
                let directory = manager.temporaryDirectory.appendingPathComponent("KeptShares", isDirectory: true)
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                // Launch Services can finish opening the app before the library reads its document.
                let cutoff = Date().addingTimeInterval(-86400)
                for old in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
                    if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                        try? manager.removeItem(at: old)
                    }
                }
                let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
                try payload.write(to: file, options: .atomic)
                let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                do {
                    _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: .init())
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
                context.completeRequest(returningItems: nil)
            } catch {
                context.cancelRequest(withError: error)
            }
        }
    }
}
