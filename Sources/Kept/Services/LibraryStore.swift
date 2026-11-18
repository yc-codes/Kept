import AppKit
import KeptCore
import UniformTypeIdentifiers
import Vision

/// The library as the UI sees it: the current list, selection, and every mutation.
@MainActor
final class LibraryStore: ObservableObject {
    let db: Database

    @Published private(set) var items: [Item] = []
    @Published private(set) var counts: [ItemFilter: Int] = [:]
    @Published var filter: ItemFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            revealed = nil
            reload()
        }
    }
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            revealed = nil
            reload()
        }
    }
    @Published var selectedID: String?
    /// Most recent snip, used by the welcome flow's practice step.
    @Published var lastSnip: Item?
    @Published var showWelcome = false
    /// A storage failure the user needs to know about; shown as an alert by the library window.
    @Published var errorMessage: String?

    /// Set by the clipboard monitor so Kept's own pasteboard writes are not captured again.
    var onOwnPasteboardWrite: (() -> Void)?
    /// Called after a snip is saved, to confirm it on screen.
    var onSnipSaved: ((Item) -> Void)?

    /// An item opened by ID that is outside the loaded list (older than the newest page).
    private var revealed: Item?
    private let work = DispatchQueue(label: "kept.ingest", qos: .userInitiated)
    private static let listLimit = 5000

    init(db: Database) {
        self.db = db
        Self.clearPreviewFiles()
        reload()
    }

    var selectedItem: Item? {
        guard let selectedID else { return nil }
        if let item = items.first(where: { $0.id == selectedID }) { return item }
        return revealed?.id == selectedID ? revealed : nil
    }

    func reload() {
        items = (try? db.items(filter: filter, search: searchText, limit: Self.listLimit)) ?? []
        counts = (try? db.counts()) ?? [:]
        if let selectedID, !items.contains(where: { $0.id == selectedID }), revealed?.id != selectedID {
            self.selectedID = nil
        }
    }

    private func report(_ action: String, _ error: Error) {
        NSLog("Kept: \(action) failed: \(error)")
        errorMessage = "Kept could not \(action). \(error)"
    }

    // MARK: Saving

    func ingest(
        _ content: ClipContent, method: CaptureMethod, source: NSRunningApplication?, select: Bool = false,
        title: String? = nil
    ) {
        let isSelf = source?.bundleIdentifier == Bundle.main.bundleIdentifier
        let appName = isSelf ? nil : source?.localizedName
        let bundleID = isSelf ? nil : source?.bundleIdentifier
        let db = self.db

        work.async {
            var item: Item?
            var failure: Error?
            switch content {
            case .image(let raw):
                // Animated GIFs are kept as they are; everything else is normalised to PNG.
                let isGIF = ImageTools.isGIF(raw)
                guard let data = isGIF ? raw : ImageTools.png(from: raw) else { break }
                let hash = Hashing.sha256(data)
                if let existing = try? db.item(hash: hash) {
                    item = existing
                    break
                }
                let size = ImageTools.pixelSize(data)
                let noun = method == .snip ? "Snip" : (isGIF ? "GIF" : "Image")
                var new = Item(
                    kind: .image, method: method, title: title ?? appName.map { "\(noun) from \($0)" } ?? noun,
                    width: size.width, height: size.height, sourceApp: appName, sourceBundleID: bundleID, hash: hash)
                new.assetName = new.id + (isGIF ? ".gif" : ".png")
                let assetURL = new.assetURL!
                do {
                    try KeptPaths.ensure()
                    try data.write(to: assetURL, options: .atomic)
                    // A missing thumbnail is not fatal: the grid falls back to the original.
                    if let thumb = ImageTools.jpegThumbnail(from: data, maxPixel: 720), let url = new.thumbURL {
                        try? thumb.write(to: url, options: .atomic)
                    }
                    if try db.insert(new) {
                        item = new
                    } else {
                        // Lost a race with an identical image: keep the stored row, drop our files.
                        Self.removeFiles(of: new)
                        item = try db.item(hash: hash)
                    }
                } catch {
                    Self.removeFiles(of: new)
                    failure = error
                }

            case .text(let string), .link(let string):
                let isLink: Bool
                if case .link = content { isLink = true } else { isLink = false }
                let hash = Hashing.sha256((isLink ? "link:" : "text:") + string)
                if let existing = try? db.item(hash: hash) {
                    item = existing
                    break
                }
                let new = Item(
                    kind: isLink ? .link : .text, method: method,
                    title: title ?? (isLink ? Self.linkTitle(string) : Self.textTitle(string)), text: string,
                    sourceApp: appName, sourceBundleID: bundleID, hash: hash, ocrDone: true)
                do {
                    item = try db.insert(new) ? new : try db.item(hash: hash)
                } catch {
                    failure = error
                }
            }

            DispatchQueue.main.async {
                if let failure { self.report("save that item", failure) }
                guard let item else { return }
                self.reload()
                if select {
                    if !self.items.contains(where: { $0.id == item.id }) {
                        self.searchText = ""
                        self.filter = .all
                    }
                    self.selectedID = item.id
                }
                if method == .snip {
                    self.lastSnip = item
                    self.onSnipSaved?(item)
                }
                if item.kind == .image, !item.ocrDone { self.recognizeText(in: item) }
            }
        }
    }

    /// Deliberately saves whatever is on the clipboard, regardless of the passive capture switches.
    func saveClipboard() {
        guard let content = ClipboardReader.read(.general, images: true, links: true, text: true) else {
            NSSound.beep()
            return
        }
        ingest(content, method: .manual, source: nil, select: true)
    }

    /// Imports image files (dropped, opened with Kept, or chosen in the import panel).
    func importFiles(_ urls: [URL]) {
        var imported = false
        for url in urls {
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 60_000_000,
                  let data = try? Data(contentsOf: url)
            else { continue }
            imported = true
            ingest(
                .image(data), method: .manual, source: nil, select: true,
                title: url.deletingPathExtension().lastPathComponent)
        }
        if !imported { NSSound.beep() }
    }

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose images or GIFs to add to Kept"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    /// Handles things dropped on the library: image files, web links, or text.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        if url.isFileURL {
                            self.importFiles([url])
                        } else if ClipboardReader.isSingleURL(url.absoluteString) {
                            self.ingest(.link(url.absoluteString), method: .manual, source: nil, select: true)
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !string.isEmpty
                    else { return }
                    DispatchQueue.main.async {
                        let content: ClipContent = ClipboardReader.isSingleURL(string) ? .link(string) : .text(string)
                        self.ingest(content, method: .manual, source: nil, select: true)
                    }
                }
            }
        }
        return accepted
    }

    nonisolated private static func textTitle(_ string: String) -> String {
        let line = string.split(whereSeparator: \.isNewline).first.map(String.init) ?? string
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }

    nonisolated private static func linkTitle(_ string: String) -> String {
        guard let url = URL(string: string), var host = url.host else { return string }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path == "/" ? "" : url.path
        let title = host + path
        return title.count > 80 ? String(title.prefix(80)) + "…" : title
    }

    nonisolated private static func removeFiles(of item: Item) {
        for url in [item.assetURL, item.thumbURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Text recognition

    func resumePendingOCR() {
        for item in (try? db.pendingOCR()) ?? [] { recognizeText(in: item) }
    }

    private func recognizeText(in item: Item) {
        guard let url = item.assetURL else { return }
        let db = self.db
        DispatchQueue.global(qos: .utility).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(url: url).perform([request])
            } catch {
                // Left unmarked so the next launch tries again.
                NSLog("Kept: text recognition failed for \(item.id): \(error)")
                return
            }
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            do {
                try db.setOCR(id: item.id, text: text)
            } catch {
                NSLog("Kept: could not store recognised text for \(item.id): \(error)")
                return
            }
            DispatchQueue.main.async {
                if self.searchText.isEmpty {
                    self.patch(item.id) {
                        $0.ocrText = text
                        $0.ocrDone = true
                    }
                } else {
                    // The new text may make this item match (or rank differently in) the active search.
                    self.reload()
                }
            }
        }
    }

    // MARK: Editing

    private func patch(_ id: String, _ change: (inout Item) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            change(&items[index])
            if lastSnip?.id == id { lastSnip = items[index] }
        }
        if revealed?.id == id, var item = revealed {
            change(&item)
            revealed = item
        }
    }

    func setNote(_ id: String, _ note: String) {
        do {
            try db.setNote(id: id, note: note)
            patch(id) { $0.note = note }
        } catch {
            report("save your note", error)
        }
    }

    func setTitle(_ id: String, _ title: String) {
        do {
            try db.setTitle(id: id, title: title)
            patch(id) { $0.title = title }
        } catch {
            report("save the title", error)
        }
    }

    func toggleFavorite(_ item: Item) {
        do {
            try db.setFavorite(id: item.id, favorite: !item.favorite)
            if revealed?.id == item.id { revealed?.favorite.toggle() }
            reload()
        } catch {
            report("update favorites", error)
        }
    }

    /// Removes the item, its search index entry, and then its files. Files are only touched once the
    /// library entry is really gone, so a failed delete never destroys an original.
    func delete(_ item: Item) {
        do {
            try db.delete(id: item.id)
        } catch {
            report("delete that item", error)
            return
        }
        Self.removeFiles(of: item)
        try? FileManager.default.removeItem(at: Self.previewFile(for: item.id))
        ThumbnailCache.shared.forget(item.id)
        if lastSnip?.id == item.id { lastSnip = nil }
        if revealed?.id == item.id { revealed = nil }
        let index = items.firstIndex { $0.id == item.id }
        reload()
        if let index, !items.isEmpty { selectedID = items[min(index, items.count - 1)].id }
    }

    // MARK: Reuse

    /// Puts the item on the clipboard. Returns false, leaving the clipboard alone, if it cannot be read.
    @discardableResult
    func copy(_ item: Item) -> Bool {
        let pasteboard = NSPasteboard.general
        switch item.kind {
        case .image:
            guard let url = item.assetURL, let data = try? Data(contentsOf: url) else {
                NSSound.beep()
                return false
            }
            pasteboard.clearContents()
            if item.isGIF {
                // As a file, so apps that support it keep the animation.
                pasteboard.writeObjects([url as NSURL])
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            } else {
                pasteboard.setData(data, forType: .png)
            }
        case .text:
            pasteboard.clearContents()
            pasteboard.setString(item.text, forType: .string)
        case .link:
            pasteboard.clearContents()
            pasteboard.setString(item.text, forType: .string)
            if let url = item.linkURL { pasteboard.setString(url.absoluteString, forType: .URL) }
        }
        onOwnPasteboardWrite?()
        return true
    }

    /// Opens the original: the image in the default viewer, or the link in the browser.
    func open(_ item: Item) {
        if let url = item.kind == .link ? item.linkURL : item.assetURL {
            NSWorkspace.shared.open(url)
        }
    }

    private static let previewDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeptPreview", isDirectory: true)

    private static func previewFile(for id: String) -> URL {
        previewDirectory.appendingPathComponent(id + ".txt")
    }

    /// Text previews are temporary copies; none should survive a relaunch.
    private static func clearPreviewFiles() {
        try? FileManager.default.removeItem(at: previewDirectory)
    }

    /// File to hand to Quick Look. Text is written to a temporary file, removed on delete and at launch.
    func previewURL(for item: Item) -> URL? {
        switch item.kind {
        case .image: return item.assetURL
        case .link: return nil
        case .text:
            try? FileManager.default.createDirectory(at: Self.previewDirectory, withIntermediateDirectories: true)
            let url = Self.previewFile(for: item.id)
            try? item.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    /// Selects an item by ID, e.g. from a `kept://item/<id>` link an agent cited.
    func reveal(_ id: String) {
        guard let item = try? db.item(id: id) else {
            NSSound.beep()
            return
        }
        searchText = ""
        filter = .all
        // Older than the loaded page: keep it reachable for the inspector anyway.
        revealed = items.contains(where: { $0.id == id }) ? nil : item
        selectedID = id
    }
}

extension Item {
    var isGIF: Bool { assetName?.hasSuffix(".gif") == true }
}

/// Thumbnails decoded off the main thread and kept in memory while the grid scrolls.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 600 }

    func cached(_ id: String) -> NSImage? { cache.object(forKey: id as NSString) }

    func forget(_ id: String) { cache.removeObject(forKey: id as NSString) }

    func image(for item: Item) async -> NSImage? {
        if let hit = cached(item.id) { return hit }
        let urls = [item.thumbURL, item.assetURL].compactMap { $0 }
        let cache = self.cache
        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
            for url in urls {
                if let image = NSImage(contentsOf: url) {
                    cache.setObject(image, forKey: item.id as NSString)
                    return image
                }
            }
            return nil
        }.value
    }
}
