import AppKit
import CoreText
import KeptCore

@MainActor
func testLibrary() async throws {
    let dir = try scratch("library")
    let db = try Database(url: dir.appendingPathComponent("library.sqlite"))
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let library = LibraryStore(db: db, pasteboard: board)
    let text = "A field diary\nSecond line"
    board.setString(text, forType: .string)
    library.saveClipboard()
    try await eventually("manual clipboard capture") { library.selectedItem?.text == text }
    let note = try library.selectedItem.unwrap("selected text")
    try check(note.title == "A field diary" && note.method == .manual, "clipboard title and method")
    library.setTitle(note.id, "Expedition diary")
    library.setNote(note.id, "Glacier waypoint")
    library.toggleFavorite(note)
    library.filter = .favorites
    library.searchText = "glac way"
    try check(library.items.map(\.id) == [note.id], "notes and favorites searchable")
    let preview = try library.previewURL(for: note).unwrap("text preview")
    try check(try String(contentsOf: preview, encoding: .utf8) == text, "preview preserves complete text")
    var ownWrites = 0
    library.onOwnPasteboardWrite = { ownWrites += 1 }
    try check(library.copy(note) && ownWrites == 1 && board.string(forType: .string) == text, "copy text")

    let shared = dir.appendingPathComponent("link.kepttext")
    let address = "https://www.example.test/one"
    try Data(address.utf8).write(to: shared)
    library.importShare(shared)
    try await eventually("share import selects link despite previous filters") { library.selectedItem?.text == address }
    let link = try library.selectedItem.unwrap("shared link")
    try check(library.filter == .all && library.searchText.isEmpty, "selection resets incompatible filters")
    try check(link.title == "example.test/one" && link.linkURL?.absoluteString == address, "share classified as link")
    try check(library.copy(link) && board.string(forType: .URL) == address && ownWrites == 2, "copy link with URL flavor")
    let drop = NSItemProvider(object: address as NSString)
    try check(library.handleDrop([drop]), "accept text drop provider")
    let droppedText = "Reproducible drop payload"
    try check(library.handleDrop([NSItemProvider(object: droppedText as NSString)]), "accept second text drop")
    try await eventually("drop provider saves a library item") { library.items.contains { $0.text == droppedText } }
    try check(try db.items(filter: .links).count == 1, "duplicate share and drop")
    try check(!library.handleDrop([]), "empty drop not accepted")
    let corrupt = dir.appendingPathComponent("invalid.kepttext")
    try Data([0xFF]).write(to: corrupt)
    library.importShare(corrupt)
    try check(library.errorMessage?.contains("read the shared item") == true, "invalid UTF-8 share reports error")

    let image = dir.appendingPathComponent("tiny.gif")
    try onePixelGIF.write(to: image)
    library.importFiles([image, image])
    try await eventually("GIF import and selection") { library.selectedItem?.isGIF == true }
    let gif = try library.selectedItem.unwrap("selected image")
    let asset = try gif.assetURL.unwrap("GIF asset path")
    let thumb = try gif.thumbURL.unwrap("thumbnail path")
    try check(try Data(contentsOf: asset) == onePixelGIF, "stored GIF bytes are unchanged")
    try check(gif.title == "tiny" && gif.width == 1 && gif.height == 1, "image metadata")
    try check(FileManager.default.fileExists(atPath: thumb.path), "thumbnail written")
    try check(library.copy(gif) && ownWrites == 3, "copy GIF")
    try check(board.data(forType: .init("com.compuserve.gif")) == onePixelGIF, "GIF copied without re-encoding")

    let png = try ImageTools.png(from: onePixelGIF).unwrap("convert GIF to PNG")
    try check(ImageTools.isPNG(png), "PNG signature")
    var callback: Item?
    library.onSnipSaved = { callback = $0 }
    library.ingest(.image(png), method: .snip, source: nil)
    try await eventually("snip stored") { library.lastSnip != nil }
    try check(callback?.id == library.lastSnip?.id && library.counts[.snips] == 1, "snip hook and filter count")
    library.filter = .snips
    library.reveal(note.id)
    try check(library.selectedItem?.id == note.id && library.filter == .all, "deep-link selection from another filter")

    library.delete(gif)
    library.delete(note)
    try check(try db.item(id: gif.id) == nil && db.item(id: note.id) == nil, "deletes persisted")
    for file in [asset, thumb, preview] {
        try check(!FileManager.default.fileExists(atPath: file.path), "deleted file \(file.lastPathComponent)")
    }
    try check(!library.copy(gif) && ownWrites == 3, "missing asset leaves pasteboard unchanged")
}

@MainActor
func testSearchAfterEdit() async throws {
    let db = try Database(url: scratch("edit").appendingPathComponent("test.sqlite"))
    let item = Item(kind: .text, method: .manual, title: "Bluebird", hash: "bluebird")
    try db.insert(item)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let library = LibraryStore(db: db, pasteboard: board)
    library.searchText = "bluebird"
    try check(library.items.map(\.id) == [item.id], "precondition: old title matched")
    library.selectedID = item.id
    library.setTitle(item.id, "Goldfinch")
    try check(try db.items(search: "bluebird").isEmpty, "database refreshed the search index")
    try check(library.items.isEmpty, "renamed item leaves the results for its old title")
    try check(library.selectedItem?.title == "Goldfinch", "item being edited stays open in the inspector")
    library.setNote(item.id, "A bluebird sighting")
    try check(library.items.map(\.id) == [item.id], "item returns once its note matches")
    library.setNote(item.id, "")
    try check(library.items.isEmpty && library.selectedItem?.id == item.id, "and leaves again, still selected")
    library.searchText = ""
    try check(library.items.map(\.id) == [item.id] && library.selectedID == item.id, "clearing the search lists it")
}

@MainActor
func testTruncatedImages() async throws {
    let db = try Database(url: scratch("truncated").appendingPathComponent("test.sqlite"))
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let library = LibraryStore(db: db, pasteboard: board)
    library.ingest(.image(Data([0x89, 0x50, 0x4E, 0x47])), method: .manual, source: nil)
    library.ingest(.image(Data([0x47, 0x49, 0x46, 0x38])), method: .manual, source: nil)
    library.ingest(.text("Queue barrier"), method: .manual, source: nil, select: true)
    try await eventually("ingest queue drained") { library.selectedItem?.text == "Queue barrier" }
    try check(try db.items(filter: .images).isEmpty, "signature-only PNG and GIF payloads are rejected")
    try check(library.errorMessage == nil, "rejection does not raise an error alert")
}

@MainActor
func testStoreMonkey() async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let seeds: [UInt64] = [733, 2026, 112358]
    let steps = 100
    for seed in seeds {
        let db = try Database(url: scratch("store-\(seed)").appendingPathComponent("library.sqlite"))
        let library = LibraryStore(db: db, pasteboard: board)
        var rng = TestRandom(seed: seed)
        var saved: [Item] = []
        for step in 0..<steps {
            let context = "seed \(seed) step \(step)"
            let choice = rng.index(8)
            let item = saved.isEmpty ? nil : saved[rng.index(saved.count)]
            switch choice {
            case 0, 1:
                let content = "Monkey capture \(seed) \(step)"
                library.ingest(.text(content), method: .manual, source: nil, select: true)
                try await eventually("save and select \(context)") { library.selectedItem?.text == content }
                saved.append(try library.selectedItem.unwrap("selected item \(context)"))
            case 2:
                library.filter = ItemFilter.allCases[rng.index(ItemFilter.allCases.count)]
            case 3:
                let queries = ["", "monkey", "capture", "revised", "🤔", "***", "no matches", "\"mon\""]
                library.searchText = queries[rng.index(queries.count)]
            case 4:
                if let item {
                    library.reveal(item.id)
                    try check(library.selectedItem?.id == item.id, "reveal \(context)")
                    let updated = "revised \(step)"
                    library.setTitle(item.id, updated)
                    library.setNote(item.id, "note \(step)")
                    try check(library.selectedItem?.title == updated && library.selectedItem?.note == "note \(step)",
                              "edit selected item \(context)")
                }
            case 5:
                if let item, let fresh = try db.item(id: item.id) {
                    library.toggleFavorite(fresh)
                    try check(try db.item(id: item.id)?.favorite == !fresh.favorite, "favorite \(context)")
                }
            case 6:
                if let item {
                    library.delete(item)
                    saved.removeAll { $0.id == item.id }
                    try check(try db.item(id: item.id) == nil, "delete \(context)")
                }
            default:
                if let item {
                    try check(library.copy(item) && board.string(forType: .string) == item.text, "copy \(context)")
                }
            }
            try check(try db.counts()[.all] == saved.count, "reference count \(context)")
            try check(try db.items(filter: library.filter, search: library.searchText) == library.items,
                      "visible rows agree with stored search \(context)")
            if let id = library.selectedID {
                try check(library.selectedItem?.id == id, "selected ID is addressable \(context)")
            }
        }
    }
    print("  \(steps * seeds.count) app service operations across seeds \(seeds)")
}

@MainActor
func testImageOCR() async throws {
    let width = 700
    let height = 180
    let context = try CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue).unwrap("OCR fixture bitmap")
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let sentence = NSAttributedString(string: "Glacier observation",
                                      attributes: [.font: NSFont.systemFont(ofSize: 62), .foregroundColor: NSColor.black])
    context.textPosition = CGPoint(x: 35, y: 65)
    CTLineDraw(CTLineCreateWithAttributedString(sentence), context)
    let image = try context.makeImage().unwrap("rendered OCR fixture")
    let png = try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]).unwrap("PNG fixture")

    let db = try Database(url: scratch("ocr").appendingPathComponent("test.sqlite"))
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let library = LibraryStore(db: db, pasteboard: board)
    library.searchText = "glacier observation"
    library.ingest(.image(png), method: .manual, source: nil)
    try await eventually("Vision OCR recognized text under an active search", timeout: .seconds(35)) {
        library.items.first?.ocrText.localizedCaseInsensitiveContains("Glacier observation") == true
    }
    let item = try library.items.first.unwrap("indexed fixture")
    try check(item.ocrDone && item.width == width && item.height == height, "OCR status and pixel size")
    try check(try db.pendingOCR().isEmpty && db.items(search: "glac obser").map(\.id) == [item.id],
              "recognized text is persisted and searchable by prefix")
}

@MainActor
func testOlderItemLink() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let db = try Database(url: scratch("large-library").appendingPathComponent("test.sqlite"))
    let original = Item(id: "first", kind: .text, method: .manual, createdAt: Date(timeIntervalSince1970: 1),
                        title: "First saved note", hash: "first")
    try db.insert(original)
    for day in 2...5001 {
        try db.insert(Item(id: "newer-\(day)", kind: .link, method: .manual,
                           createdAt: Date(timeIntervalSince1970: Double(day)), title: "Newer item", hash: "item-\(day)"))
    }
    let library = LibraryStore(db: db, pasteboard: board)
    try check(library.hasMoreItems && library.items.count == 5000 && !library.items.contains(original),
              "oldest item falls past the library display limit")
    library.filter = .links
    library.reveal(original.id)
    try check(library.filter == .all && library.selectedItem == original, "older item remains accessible through its ID")
    library.setNote(original.id, "Found through a link")
    try check(library.selectedItem?.note == "Found through a link", "edits apply to the revealed item")
    library.searchText = "found through"
    try check(library.items.map(\.id) == [original.id] && !library.hasMoreItems, "search can find older items")
}
