import AppKit
import Carbon.HIToolbox
import KeptCore
import SwiftUI

@MainActor
final class QuickSearchModel: ObservableObject {
    @Published var query = "" { didSet { refresh() } }
    @Published private(set) var results: [Item] = []
    @Published var index = 0

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

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
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

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
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
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                TextField("Search Kept", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(LibraryPalette.heading(26))
                    .focused($focused)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            if model.results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "Nothing kept yet" : "No matches for “\(model.query)”")
                        .foregroundStyle(.secondary)
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
                Text(model.query.isEmpty ? "Recent" : "\(model.results.count) results")
                Spacer()
                Text("↩ Copy")
                Text("⌘↩ Show in Library")
                Text("esc Close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(LibraryPalette.canvas)
        .tint(LibraryPalette.accent)
        .ignoresSafeArea()
        .onAppear { focused = true }
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
                Text(item.title)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(item.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? LibraryPalette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
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
