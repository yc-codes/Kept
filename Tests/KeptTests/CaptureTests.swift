import AppKit
import Carbon.HIToolbox
import KeptCore

@MainActor
func testCaptureSettings() throws {
    let name = "app.kept.tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = CaptureSettings(defaults: defaults)
    try check(!settings.anyClipboardCapture && !settings.paused && !settings.didOnboard, "fresh install defaults")
    try check(settings.theme == .system && settings.theme.appearance == nil, "default follows macOS")
    try check(settings.statusLine == "Saving snips only", "default status")
    try check(settings.excludedApps.isEmpty, "no custom exclusions by default")
    try check(settings.snipShortcut == .defaultSnip && settings.quickShortcut == .defaultQuickSearch,
              "default shortcuts")

    for mask in 0..<8 {
        settings.captureImages = mask & 1 != 0
        settings.captureLinks = mask & 2 != 0
        settings.captureText = mask & 4 != 0
        for paused in [false, true] {
            settings.paused = paused
            let restored = CaptureSettings(defaults: defaults)
            try check(restored.captureImages == settings.captureImages, "image switch persists")
            try check(restored.captureLinks == settings.captureLinks, "link switch persists")
            try check(restored.captureText == settings.captureText, "text switch persists")
            try check(restored.paused == paused, "pause persists")
            try check(restored.anyClipboardCapture == (mask != 0), "combined capture state")
            if paused {
                try check(restored.statusLine == "Clipboard capture paused. Snips still save.", "paused status")
            } else {
                for (flag, label) in [(1, "images"), (2, "links"), (4, "text")] {
                    try check(restored.statusLine.contains(label) == (mask & flag != 0), "status for \(label)")
                }
            }
        }
    }
    for theme in AppTheme.allCases {
        settings.theme = theme
        try check(CaptureSettings(defaults: defaults).theme == theme, "\(theme) persists")
    }
    try check(settings.accent == .terracotta && settings.cardSize == .medium && settings.cropThumbnails
              && settings.showSidebarCounts, "appearance defaults")
    for accent in AccentChoice.allCases {
        settings.accent = accent
        try check(CaptureSettings(defaults: defaults).accent == accent, "\(accent) accent persists")
    }
    for size in CardSize.allCases {
        settings.cardSize = size
        try check(CaptureSettings(defaults: defaults).cardSize == size, "\(size) card size persists")
    }
    try check(CardSize.small.minWidth < CardSize.medium.minWidth && CardSize.medium.minWidth < CardSize.large.minWidth,
              "card sizes grow in order")
    settings.cropThumbnails = false
    settings.showSidebarCounts = false
    let look = CaptureSettings(defaults: defaults)
    try check(!look.cropThumbnails && !look.showSidebarCounts, "switched-off appearance options persist")
    defaults.set("invalid accent", forKey: "accent")
    defaults.set("huge", forKey: "cardSize")
    let fallback = CaptureSettings(defaults: defaults)
    try check(fallback.accent == .terracotta && fallback.cardSize == .medium, "invalid appearance values restore defaults")
    try check(AppTheme.light.appearance?.name == .aqua && AppTheme.dark.appearance?.name == .darkAqua,
              "appearance mapping")

    settings.didOnboard = true
    let excluded = ExcludedApp(bundleID: "app.kept.tests.example", name: "Privacy test")
    settings.excludedApps.append(excluded)
    let restored = CaptureSettings(defaults: defaults)
    try check(restored.didOnboard && restored.excludedApps == [excluded], "welcome and exclusions persist")
    try check(restored.isExcluded(excluded.bundleID), "custom exclusion applied")
    settings.excludedApps.removeAll()
    try check(!CaptureSettings(defaults: defaults).isExcluded(excluded.bundleID), "custom exclusion removed")
    for bundleID in CaptureSettings.alwaysExcluded {
        try check(settings.isExcluded(bundleID), "built-in protection for \(bundleID)")
    }

    var notifications = 0
    settings.onShortcutsChanged = { notifications += 1 }
    settings.snipShortcut = Shortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: NSEvent.ModifierFlags.option.rawValue, keyLabel: "Y")
    settings.quickShortcut = Shortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: NSEvent.ModifierFlags.control.rawValue, keyLabel: "Q")
    let shortcuts = CaptureSettings(defaults: defaults)
    try check(notifications == 2 && shortcuts.snipShortcut == settings.snipShortcut
              && shortcuts.quickShortcut == settings.quickShortcut, "both shortcuts trigger re-registration and persist")

    defaults.set("invalid theme", forKey: "theme")
    for key in ["excludedApps", "snipShortcut", "quickShortcut"] {
        defaults.set(Data([0xFF]), forKey: key)
    }
    let recovered = CaptureSettings(defaults: defaults)
    try check(recovered.theme == .system && recovered.excludedApps.isEmpty
              && recovered.snipShortcut == .defaultSnip && recovered.quickShortcut == .defaultQuickSearch,
              "invalid saved values restore defaults")
}

@MainActor
func testShortcuts() throws {
    func key(_ code: Int, _ characters: String, _ flags: NSEvent.ModifierFlags) -> Shortcut? {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                         timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))
        else { return nil }
        return Shortcut(event: event)
    }
    try check(key(kVK_ANSI_S, "s", []) == nil && key(kVK_ANSI_S, "s", .shift) == nil, "modifier required")
    try check(key(kVK_ANSI_S, "s", [.control, .option, .capsLock]) == .defaultSnip, "caps lock ignored")
    try check(key(kVK_F12, "", .command)?.display == "⌘F12", "function keys")
    try check(key(kVK_Space, " ", [.control, .option, .shift, .command])?.display == "⌃⌥⇧⌘Space",
              "modifier order and space")
    try check(key(kVK_Return, "\r", .option)?.carbonModifiers == UInt32(optionKey), "Carbon mapping")
    try check(key(kVK_ANSI_A, "", .command) == nil, "unlabelled key")
}

let onePixelGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!

@MainActor
func testClipboard() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let pngType = NSPasteboard.PasteboardType.png
    let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")
    let png = try ImageTools.png(from: onePixelGIF).unwrap("PNG fixture")
    let address = "https://example.test/saved"
    func write(_ values: [NSPasteboard.PasteboardType: Data]) {
        board.declareTypes(Array(values.keys), owner: nil)
        for (type, value) in values { board.setData(value, forType: type) }
    }
    func read(_ mask: Int = 7) -> String? {
        switch ClipboardReader.read(board, images: mask & 1 != 0, links: mask & 2 != 0, text: mask & 4 != 0) {
        case .image(let data): return data == png ? "png" : (data == onePixelGIF ? "gif" : "image")
        case .link(let url): return "link:" + url
        case .text(let text): return "text:" + text
        case nil: return nil
        }
    }
    for mask in 0..<8 {
        write([.string: Data(" \nplain text \n".utf8)])
        try check(read(mask) == (mask & 4 == 0 ? nil : "text:plain text"), "text with mask \(mask)")
        write([.string: Data((" " + address + "\n").utf8)])
        try check(read(mask) == (mask & 2 == 0 ? nil : "link:" + address), "link with mask \(mask)")
        write([pngType: png])
        try check(read(mask) == (mask & 1 == 0 ? nil : "png"), "image with mask \(mask)")
    }
    for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                   "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"] {
        write([.string: Data(address.utf8), pngType: png, .init(marker): Data()])
        try check(read() == nil, "privacy marker \(marker)")
    }
    for text in ["", " \n ", "A", String(repeating: "é", count: 250_001)] {
        write([.string: Data(text.utf8)])
        try check(read() == nil, "empty, single-character and oversized text ignored")
    }
    let maxText = String(repeating: "é", count: 250_000)
    write([.string: Data(maxText.utf8)])
    try check(read() == "text:" + maxText, "500,000 UTF-8 bytes allowed")
    write([.URL: Data(address.utf8)])
    try check(read(2) == "link:" + address, "explicit URL without string flavor")
    write([pngType: png, gifType: onePixelGIF])
    try check(read() == "gif", "preserve GIF bytes ahead of PNG fallback")
    write([pngType: png, .string: Data(address.utf8)])
    try check(read() == "png", "image with source URL")
    write([pngType: png, .rtf: Data(), .string: Data("spreadsheet cells".utf8)])
    try check(read() == "text:spreadsheet cells" && read(1) == nil, "rich text preview is not an image capture")
    for value in ["example.test", "https://", "file:///tmp/file", "mailto:x@example.test",
                  "https://example.test/a b", "https://example.test/a\nhttps://example.test/b"] {
        try check(!ClipboardReader.isSingleURL(value), "not a single web link: \(value)")
    }

    let dir = try scratch("clipboard")
    let imageURL = dir.appendingPathComponent("image.png")
    let secondURL = dir.appendingPathComponent("second.png")
    let textURL = dir.appendingPathComponent("notes.txt")
    try png.write(to: imageURL)
    try png.write(to: secondURL)
    try Data("file".utf8).write(to: textURL)
    for (urls, expected) in [([imageURL], "png"), ([imageURL, secondURL], nil), ([textURL], nil)] {
        board.clearContents()
        try check(board.writeObjects(urls.map { $0 as NSURL }), "write files to named pasteboard")
        try check(read() == expected && read(6) == nil, "eligible single file only")
    }
}

extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw CheckFailure(description: message) }
        return value
    }
}

@MainActor
func testClipboardMonitor() async throws {
    let finder = try NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        .unwrap("Run the clipboard monitor tests in a logged-in desktop session with Finder running")
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let suite = "app.kept.tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = CaptureSettings(defaults: defaults)
    let db = try Database(url: scratch("monitor").appendingPathComponent("library.sqlite"))
    let library = LibraryStore(db: db, pasteboard: board)
    let monitor = ClipboardMonitor(library: library, settings: settings, pasteboard: board)
    library.onOwnPasteboardWrite = { monitor.markOwnWrite() }

    func put(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    put("Sources are off")
    monitor.processChanges(from: [finder])
    settings.captureText = true
    monitor.processChanges(from: [finder])
    settings.paused = true
    put("Capture is paused")
    monitor.processChanges(from: [finder])
    settings.paused = false
    settings.excludedApps = [.init(bundleID: "com.apple.finder", name: "Finder")]
    put("Source is excluded")
    monitor.processChanges(from: [finder])
    settings.excludedApps = []
    put("Source is unknown")
    monitor.processChanges(from: [])
    put("Kept wrote this")
    monitor.markOwnWrite()
    monitor.processChanges(from: [finder])
    put("https://example.test/links-disabled")
    monitor.processChanges(from: [finder])
    put("Allowed text from Finder")
    monitor.processChanges(from: [finder])
    monitor.processChanges(from: [finder])
    settings.captureLinks = true
    put("https://example.test/link")
    monitor.processChanges(from: [finder])
    settings.paused = true
    put("Save intentionally while paused")
    library.saveClipboard()
    try await eventually("manual save follows pending monitor work") {
        library.selectedItem?.text == "Save intentionally while paused"
    }
    let items = try db.items()
    try check(items.map(\.text) == ["Save intentionally while paused", "https://example.test/link", "Allowed text from Finder"],
              "only allowed clipboard reads entered the library")
    try check(items.dropFirst().allSatisfy { $0.method == .clipboard && $0.sourceBundleID == "com.apple.finder" }
              && items.first?.method == .manual, "source metadata and manual override")
}
