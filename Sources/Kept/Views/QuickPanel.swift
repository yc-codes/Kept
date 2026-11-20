import AppKit
import Carbon.HIToolbox
import KeptCore
import SwiftUI

@MainActor
final class QuickSearchModel: ObservableObject {
    @Published var query = "" { didSet { refresh() } }
    @Published private(set) var results: [Item] = []
    @Published var index = 0
    /// Bumped each time the panel is shown, to put the cursor back in the search field.
    @Published var focusRequest = 0

    private let db: Database

    init(db: Database) {
        self.db = db
    }

    var current: Item? { results.indices.contains(index) ? results[index] : nil }

    func reset() {
        query = ""
        refresh()
    }

    func refresh() {
        results = (try? db.items(filter: .all, search: query, limit: 40)) ?? []
        index = 0
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        index = min(max(index + delta, 0), results.count - 1)
    }
}

private final class QuickPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    /// Off while a snapshot is being rendered, when another app may take focus at any moment.
    var closesOnResignKey = true

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        if closesOnResignKey { orderOut(nil) }
    }
}

/// Spotlight-style search that floats over whatever app is in front.
@MainActor
final class QuickPanelController {
    private let library: LibraryStore
    private let model: QuickSearchModel
    private var panel: QuickPanel?

    init(library: LibraryStore) {
        self.library = library
        model = QuickSearchModel(db: library.db)
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func show(pinned: Bool = false) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.closesOnResignKey = !pinned
        model.reset()
        // A fresh hosting view each time puts the cursor back in the search field.
        panel.contentView = NSHostingView(rootView: QuickSearchView(
            model: model, onCopy: { [weak self] in self?.copy($0) }, onOpen: { [weak self] in self?.openInLibrary($0) }))

        let size = NSSize(width: 680, height: 440)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        // Focus asked for while the view is still being installed is sometimes dropped, leaving a panel
        // that shows the cursor nowhere and ignores typing. Ask again once the panel is key.
        DispatchQueue.main.async { [model] in model.focusRequest += 1 }
    }

    private func makePanel() -> QuickPanel {
        let panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.keyHandler = { [weak self] event in
            guard let self else { return false }
            switch Int(event.keyCode) {
            case kVK_DownArrow: self.model.move(1)
            case kVK_UpArrow: self.model.move(-1)
            case kVK_Escape: self.hide()
            case kVK_Return, kVK_ANSI_KeypadEnter:
                guard let item = self.model.current else { return true }
                if event.modifierFlags.contains(.command) { self.openInLibrary(item) } else { self.copy(item) }
            default: return false
            }
            return true
        }
        return panel
    }

    private func copy(_ item: Item) {
        library.copy(item)
        hide()
    }

    private func openInLibrary(_ item: Item) {
        hide()
        AppServices.shared.showLibrary()
        library.reveal(item.id)
    }
}

struct QuickSearchView: View {
    @ObservedObject var model: QuickSearchModel
    let onCopy: (Item) -> Void
    let onOpen: (Item) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                KeptIcon.magnifyingGlass.image(size: 20)
                    .foregroundStyle(.secondary)
                TextField("Search Kept", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .medium))
                    .focused($focused)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            if model.results.isEmpty {
                VStack(spacing: 6) {
                    (model.query.isEmpty ? KeptIcon.tray : .magnifyingGlass).image(size: 28)
                        .foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "Nothing kept yet" : "No matches for “\(model.query)”")
                        .foregroundStyle(.secondary)
                    if model.query.isEmpty {
                        Text("Snips and anything you save will show up here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { offset, item in
                                QuickRow(item: item, selected: offset == model.index)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.index = offset
                                        onCopy(item)
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.index) {
                        if let id = model.current?.id { proxy.scrollTo(id) }
                    }
                }
            }

            Divider()
            HStack(spacing: 14) {
                Text(model.query.isEmpty ? (model.results.isEmpty ? "" : "Recent") : "\(model.results.count) \(model.results.count == 1 ? "result" : "results")")
                Spacer()
                // Only offer actions that have something to act on.
                if !model.results.isEmpty {
                    hint("↩", "Copy")
                    hint("⌘↩", "Show in Library")
                }
                hint("esc", "Close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(LibraryPalette.canvas)
        .keptTheme()
        .ignoresSafeArea()
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { focused = true }
    }
}

private extension QuickSearchView {
    func hint(_ keys: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(LibraryPalette.inset, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(action)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct QuickRow: View {
    let item: Item
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ItemPreview(item: item, compact: true)
                .frame(width: 44, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(item.age())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            selected ? AnyShapeStyle(LibraryPalette.accent.opacity(0.18)) : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var detail: String {
        if !item.note.isEmpty { return item.note.replacingOccurrences(of: "\n", with: " ") }
        switch item.kind {
        case .link: return item.text
        case .text: return item.sourceApp ?? "Text"
        case .image:
            let firstLine = item.ocrText.split(whereSeparator: \.isNewline).first.map(String.init)
            return firstLine ?? item.sourceApp ?? "Image"
        }
    }
}
