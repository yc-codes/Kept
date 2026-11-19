import KeptCore
import QuickLook
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: CaptureSettings
    @Environment(\.openWindow) private var openWindow

    @AppStorage("libraryViewMode") private var viewMode = "grid"
    @AppStorage("libraryShowInspector") private var showInspector = false
    @Local private var previewURL: URL? = nil
    @Local private var pendingDelete: Item? = nil
    @Local private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 202, max: 280)
        } detail: {
            content
                .inspector(isPresented: inspectorBinding) {
                    Group {
                        if let item = library.selectedItem {
                            InspectorView(item: item, onDelete: { pendingDelete = item })
                                .id(item.id)
                        } else {
                            ContentUnavailableView(
                                "No item selected", systemImage: "sidebar.trailing",
                                description: Text("Select an item to see its source and add a note."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(LibraryPalette.sidebar)
                        }
                    }
                    .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
                }
        }
        .navigationTitle("Kept")
        .tint(LibraryPalette.accent)
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search notes, text, and images")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("View", selection: $viewMode) {
                    Label("Grid", systemImage: "square.grid.2x2").tag("grid")
                    Label("List", systemImage: "list.bullet").tag("list")
                }
                .pickerStyle(.segmented)
                .help("Show items as a grid or a list")

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
                .help("Show or hide the inspector")
                .disabled(library.items.isEmpty)
            }
        }
        .quickLookPreview($previewURL)
        .confirmationDialog(
            "Delete “\(pendingDelete?.title ?? "")”?", isPresented: deleteBinding, presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { library.delete(item) }
        } message: { _ in
            Text("This permanently removes the saved item and its note from Kept.")
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
        .sheet(isPresented: $library.showWelcome) {
            WelcomeView()
                .environmentObject(library)
                .environmentObject(settings)
        }
        .onOpenURL { url in
            // An image opened with Kept, or a kept://item/<id> link.
            if url.isFileURL {
                if ["kepttext", "keptimage"].contains(url.pathExtension) {
                    library.importShare(url)
                } else {
                    library.importFiles([url])
                }
            } else if url.scheme == "kept", url.host == "item" {
                library.reveal(url.lastPathComponent)
                showInspector = true
            }
        }
        .onAppear {
            AppServices.shared.openLibraryWindow = { openWindow(id: "library") }
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { showInspector && !library.items.isEmpty }, set: { showInspector = $0 })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var subtitle: String {
        let count = library.items.count
        let noun = count == 1 ? "item" : "items"
        let itemCount = library.searchText.isEmpty
            ? "\(count.formatted()) \(noun)"
            : "\(count.formatted()) matching \(noun)"
        return library.hasMoreItems ? "Showing the first \(itemCount)" : itemCount
    }

    private var content: some View {
        VStack(spacing: 0) {
            libraryHeader

            if library.items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewMode == "list" {
                ItemTable(onPreview: preview, onDelete: { pendingDelete = $0 })
            } else {
                ItemGrid(onPreview: preview, onDelete: { pendingDelete = $0 })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LibraryPalette.canvas)
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted) { providers in
            library.handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        Label("Drop to save in Kept", systemImage: "tray.and.arrow.down.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(library.filter.title)
                    .font(LibraryPalette.heading(30))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Save Clipboard", systemImage: "doc.on.clipboard") { library.saveClipboard() }
                Button("Import Images…", systemImage: "photo.on.rectangle") { library.showImportPanel() }
            } label: {
                Label("Take Snip", systemImage: "camera.viewfinder")
                    .font(.callout.weight(.semibold))
            } primaryAction: {
                AppServices.shared.snip()
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .tint(LibraryPalette.accent)
            .controlSize(.large)
            .fixedSize()
            .help("Take a snip (\(settings.snipShortcut.display)), or open the menu for more capture options")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LibraryPalette.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !library.searchText.isEmpty {
            ContentUnavailableView.search(text: library.searchText)
        } else if library.filter != .all {
            ContentUnavailableView(
                "No \(library.filter.title)", systemImage: library.filter.symbol,
                description: Text(library.filter == .favorites
                    ? "Star an item to find it here."
                    : "Items you save will appear here."))
        } else {
            VStack(spacing: 14) {
                CaptureStack()
                Text("Keep your first capture")
                    .font(LibraryPalette.heading(32))
                Text("Press \(settings.snipShortcut.display) to capture part of your screen, or drop images and links here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Button("Import images…") { library.showImportPanel() }
                    .buttonStyle(.link)
                    .foregroundStyle(LibraryPalette.accent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func preview(_ item: Item) {
        if let url = library.previewURL(for: item) {
            previewURL = url
        } else {
            library.open(item)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: CaptureSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text("Kept")
                    .font(LibraryPalette.heading(22))
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)

            List(selection: $library.filter) {
                Section {
                    filterRow(.all)
                    filterRow(.favorites)
                }
                Section {
                    ForEach([ItemFilter.snips, .images, .links, .text]) { filter in
                        filterRow(filter)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Library filters")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(settings.paused ? Color.orange : LibraryPalette.accent)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(settings.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    settings.paused.toggle()
                } label: {
                    Image(systemName: settings.paused ? "play.fill" : "pause.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(settings.paused ? "Resume clipboard capture" : "Pause clipboard capture")
                .help(settings.paused ? "Resume clipboard capture" : "Pause clipboard capture")
            }
            .padding(12)
            .background(LibraryPalette.sidebar)
            .overlay(alignment: .top) {
                Rectangle().fill(LibraryPalette.line).frame(height: 1)
            }
        }
        .background(LibraryPalette.sidebar)
    }

    private func filterRow(_ filter: ItemFilter) -> some View {
        let count = library.counts[filter] ?? 0
        return Label(filter.title, systemImage: filter.symbol)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
            .badge(count.formatted())
            .tag(filter)
            .accessibilityLabel(filter.title)
            .accessibilityValue("\(count) \(count == 1 ? "item" : "items")")
    }
}

/// Shared right-click menu for the grid, the list and quick search.
struct ItemMenu: View {
    @EnvironmentObject private var library: LibraryStore
    let item: Item
    let onPreview: (Item) -> Void
    let onDelete: (Item) -> Void

    var body: some View {
        Button("Copy") { library.copy(item) }
        if item.kind != .text {
            Button(item.kind == .link ? "Open Link" : "Open in Preview") { library.open(item) }
        }
        if item.kind != .link {
            Button("Quick Look") { onPreview(item) }
        }
        if let url = item.assetURL {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button(item.favorite ? "Remove from Favorites" : "Add to Favorites") { library.toggleFavorite(item) }
        Button("Copy Kept Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.deepLink, forType: .string)
            library.onOwnPasteboardWrite?()
        }
        Divider()
        Button("Delete…", role: .destructive) { onDelete(item) }
    }
}

struct ItemGrid: View {
    @EnvironmentObject private var library: LibraryStore
    let onPreview: (Item) -> Void
    let onDelete: (Item) -> Void

    @FocusState private var focused: Bool
    private let spacing: CGFloat = 18
    private let padding: CGFloat = 24
    private let minCardWidth: CGFloat = 205

    var body: some View {
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - padding * 2 + spacing) / (minCardWidth + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                        spacing: spacing
                    ) {
                        ForEach(library.items) { item in
                            ItemCard(item: item, selected: library.selectedID == item.id)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .gesture(TapGesture(count: 2).onEnded { activate(item) })
                                .simultaneousGesture(TapGesture().onEnded {
                                    library.selectedID = item.id
                                    focused = true
                                })
                                .contextMenu {
                                    ItemMenu(item: item, onPreview: onPreview, onDelete: onDelete)
                                }
                                .onDrag { dragProvider(item) }
                        }
                    }
                    .padding(padding)
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) { move(-1, proxy) }
                .onKeyPress(.rightArrow) { move(1, proxy) }
                .onKeyPress(.upArrow) { move(-columns, proxy) }
                .onKeyPress(.downArrow) { move(columns, proxy) }
                .onKeyPress(.space) {
                    guard let item = library.selectedItem else { return .ignored }
                    onPreview(item)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let item = library.selectedItem else { return .ignored }
                    activate(item)
                    return .handled
                }
                .onKeyPress(.delete) {
                    guard let item = library.selectedItem else { return .ignored }
                    onDelete(item)
                    return .handled
                }
                .onCopyCommand {
                    guard let item = library.selectedItem else { return [] }
                    library.copy(item)
                    return []
                }
            }
        }
    }

    private func activate(_ item: Item) {
        if item.kind == .text { onPreview(item) } else { library.open(item) }
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let items = library.items
        guard !items.isEmpty else { return .ignored }
        let target: Int
        if let current = items.firstIndex(where: { $0.id == library.selectedID }) {
            target = min(max(current + delta, 0), items.count - 1)
        } else {
            target = 0
        }
        library.selectedID = items[target].id
        proxy.scrollTo(items[target].id)
        return .handled
    }

    private func dragProvider(_ item: Item) -> NSItemProvider {
        switch item.kind {
        case .image:
            if let url = item.assetURL, let provider = NSItemProvider(contentsOf: url) { return provider }
            return NSItemProvider()
        case .link:
            if let url = item.linkURL { return NSItemProvider(object: url as NSURL) }
            return NSItemProvider(object: item.text as NSString)
        case .text:
            return NSItemProvider(object: item.text as NSString)
        }
    }
}

struct ItemTable: View {
    @EnvironmentObject private var library: LibraryStore
    let onPreview: (Item) -> Void
    let onDelete: (Item) -> Void

    var body: some View {
        Table(library.items, selection: $library.selectedID) {
            TableColumn("Name") { item in
                HStack(spacing: 8) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(item.title)
                        .lineLimit(1)
                    if item.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
            }
            .width(min: 180, ideal: 320)

            TableColumn("Note") { item in
                Text(item.note.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 240)

            TableColumn("Source") { item in
                Text(item.sourceApp ?? item.method.label)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Captured") { item in
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let item = library.items.first(where: { $0.id == id }) {
                ItemMenu(item: item, onPreview: onPreview, onDelete: onDelete)
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = library.items.first(where: { $0.id == id }) {
                if item.kind == .text { onPreview(item) } else { library.open(item) }
            }
        }
        .onKeyPress(.space) {
            guard let item = library.selectedItem else { return .ignored }
            onPreview(item)
            return .handled
        }
        .onDeleteCommand {
            if let item = library.selectedItem { onDelete(item) }
        }
        .onCopyCommand {
            guard let item = library.selectedItem else { return [] }
            library.copy(item)
            return []
        }
    }
}

extension Item {
    var symbol: String {
        switch kind {
        case .image: return method == .snip ? "camera.viewfinder" : "photo"
        case .link: return "link"
        case .text: return "text.alignleft"
        }
    }

    var host: String {
        guard var host = linkURL?.host else { return text }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
