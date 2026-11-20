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
                            ContentUnavailableView {
                                Label("No item selected", icon: .inspector, size: 32)
                            } description: {
                                Text("Select an item to see its source and add a note.")
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(LibraryPalette.sidebar)
                        }
                    }
                    .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
                }
        }
        .navigationTitle("Kept")
        .keptTheme()
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search notes, text, and images")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("View", selection: $viewMode) {
                    Label("Grid", icon: .squaresFour).tag("grid")
                    Label("List", icon: .listBullets).tag("list")
                }
                .pickerStyle(.segmented)
                .help("Show items as a grid or a list")

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", icon: .inspector)
                }
                .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
                .help("Show or hide the inspector")
                .disabled(library.items.isEmpty)
            }
        }
        .quickLookPreview($previewURL)
        .confirmationDialog(
            "Delete “\(pendingDelete?.displayTitle ?? "")”?", isPresented: deleteBinding, presenting: pendingDelete
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
                    .strokeBorder(LibraryPalette.accent, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                    .background(LibraryPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        Label("Drop to save in Kept", icon: .archiveTray, size: 20)
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

    /// In a narrow pane the button gives up its label before the heading gives up its letters.
    private var libraryHeader: some View {
        ViewThatFits(in: .horizontal) {
            header(compact: false)
            header(compact: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LibraryPalette.line).frame(height: 1)
        }
    }

    private func header(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(library.filter.title)
                    .font(LibraryPalette.heading(28))
                    .lineLimit(1)
                    .minimumScaleFactor(compact ? 0.7 : 1)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: !compact, vertical: false)
            Spacer(minLength: 0)
            // A real prominent button for the main action: a Menu with a primary action ignores the
            // prominent style on macOS and came out as a plain white button.
            HStack(spacing: 6) {
                Button {
                    AppServices.shared.snip()
                } label: {
                    if compact {
                        KeptIcon.cornersOut.image()
                    } else {
                        Label("Take Snip", icon: .cornersOut)
                            .font(.callout.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Take Snip")
                .help("Take a snip (\(settings.snipShortcut.display))")

                Menu {
                    Button { library.saveClipboard() } label: {
                        Label("Save Clipboard", icon: .clipboard)
                    }
                    Button { library.showImportPanel() } label: {
                        Label("Import Images…", icon: .images)
                    }
                } label: {
                    KeptIcon.plus.image()
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .accessibilityLabel("More ways to save")
                .help("Save the clipboard or import images")
            }
            .controlSize(.large)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !library.searchText.isEmpty {
            ContentUnavailableView.search(text: library.searchText)
        } else if library.filter != .all {
            ContentUnavailableView {
                Label("No \(library.filter.title)", icon: library.filter.icon, size: 32)
            } description: {
                Text(library.filter == .favorites
                    ? "Star an item to find it here."
                    : "Items you save will appear here.")
            }
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
            // A link has nothing to Quick Look. Space must not leave Kept for the browser (Return does
            // that), so show the link's details instead.
            library.selectedID = item.id
            showInspector = true
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: CaptureSettings
    @FocusState private var focused: Bool

    private static let groups: [[ItemFilter]] = [[.all, .favorites], [.snips, .images, .links, .text]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text("Kept")
                    .font(LibraryPalette.heading(20))
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)

            // Drawn by hand rather than with a sidebar List, whose selection always takes the macOS accent
            // colour and would sit next to Kept's own.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.groups[0]) { row($0) }
                    Text("Kinds")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 14)
                        .padding(.bottom, 3)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Self.groups[1]) { row($0) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Library filters")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(settings.paused ? AnyShapeStyle(Color.orange) : AnyShapeStyle(LibraryPalette.accent))
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
                    (settings.paused ? KeptIcon.play : .pause).image(size: 13)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel(settings.paused ? "Resume clipboard capture" : "Pause clipboard capture")
                .help(settings.paused ? "Resume clipboard capture" : "Pause clipboard capture")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .background(LibraryPalette.sidebar)
            .overlay(alignment: .top) {
                Rectangle().fill(LibraryPalette.line).frame(height: 1)
            }
        }
        .background(LibraryPalette.sidebar)
    }

    private func row(_ filter: ItemFilter) -> some View {
        SidebarRow(
            filter: filter, count: library.counts[filter] ?? 0, showCount: settings.showSidebarCounts,
            selected: library.filter == filter
        ) {
            library.filter = filter
            focused = true
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let order = Self.groups.flatMap { $0 }
        guard let index = order.firstIndex(of: library.filter) else { return .ignored }
        library.filter = order[min(max(index + delta, 0), order.count - 1)]
        return .handled
    }
}

private struct SidebarRow: View {
    let filter: ItemFilter
    let count: Int
    let showCount: Bool
    let selected: Bool
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                filter.icon.image()
                    .foregroundStyle(selected ? AnyShapeStyle(LibraryPalette.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                Text(filter.title)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showCount, count > 0 {
                    Text(count.formatted())
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(filter.title)
        .accessibilityValue("\(count) \(count == 1 ? "item" : "items")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(LibraryPalette.accent.opacity(0.16)) }
        return AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0))
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

    @EnvironmentObject private var settings: CaptureSettings
    @FocusState private var focused: Bool
    private let padding: CGFloat = 24
    private var spacing: CGFloat { settings.cardSize == .small ? 14 : 18 }
    private var minCardWidth: CGFloat { settings.cardSize.minWidth }

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
                            ItemCard(
                                item: item, selected: library.selectedID == item.id,
                                previewHeight: settings.cardSize.previewHeight, crop: settings.cropThumbnails)
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
                                .onDrag { item.dragProvider }
                        }
                    }
                    .padding(padding)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                    // A click on empty space clears the selection, as in Finder.
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                library.selectedID = nil
                                focused = true
                            }
                    }
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
                // The Mac's Delete key arrives as U+007F, which `KeyEquivalent.delete` (U+0008) does not
                // match, so it is matched by character as well. Forward Delete has its own key.
                .onKeyPress(phases: .down) { press in
                    let isDelete = press.key == .delete || press.key == .deleteForward
                        || press.characters == "\u{7F}" || press.characters == "\u{8}"
                    return isDelete ? askToDelete() : .ignored
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

    private func askToDelete() -> KeyPress.Result {
        guard let item = library.selectedItem else { return .ignored }
        onDelete(item)
        return .handled
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
}

/// The list view. Drawn by hand rather than with `Table`: a table's selection always takes the macOS accent
/// colour, and it keeps the column widths it was first laid out with, so columns ran off the edge when the
/// inspector opened. Here the selection uses Kept's accent and the columns are worked out from the width.
struct ItemTable: View {
    @EnvironmentObject private var library: LibraryStore
    let onPreview: (Item) -> Void
    let onDelete: (Item) -> Void
    @FocusState private var focused: Bool

    private struct Columns {
        let note: CGFloat
        let source: CGFloat
        let captured: CGFloat
        /// Date only, when there is no room for the time as well. The inspector has the full value.
        let shortDate: Bool

        /// Name takes what is left and is the last thing to give way: as the pane narrows the note goes
        /// first, then the source, then the time of day.
        init(width: CGFloat) {
            note = width < 720 ? 0 : min(max(width * 0.24, 130), 280)
            source = width < 520 ? 0 : (width < 620 ? 104 : 136)
            shortDate = width < 440
            captured = shortDate ? 100 : 176
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = Columns(width: geometry.size.width)
            VStack(spacing: 0) {
                header(columns)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(library.items.enumerated()), id: \.element.id) { index, item in
                                ItemRow(
                                    item: item, columns: (columns.note, columns.source, columns.captured),
                                    shortDate: columns.shortDate,
                                    selected: library.selectedID == item.id, striped: index.isMultiple(of: 2))
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
                                    .onDrag { item.dragProvider }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(minHeight: geometry.size.height - 30, alignment: .top)
                        .background {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    library.selectedID = nil
                                    focused = true
                                }
                        }
                    }
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(.upArrow) { move(-1, proxy) }
                    .onKeyPress(.downArrow) { move(1, proxy) }
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
                    .onKeyPress(phases: .down) { press in
                        let isDelete = press.key == .delete || press.key == .deleteForward
                            || press.characters == "\u{7F}" || press.characters == "\u{8}"
                        guard isDelete, let item = library.selectedItem else { return .ignored }
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
    }

    private func header(_ columns: Columns) -> some View {
        HStack(spacing: 0) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            if columns.note > 0 { Text("Note").frame(width: columns.note, alignment: .leading) }
            if columns.source > 0 { Text("Source").frame(width: columns.source, alignment: .leading) }
            Text("Captured").frame(width: columns.captured, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 12 + 10 + 24)
        .padding(.trailing, 12 + 10)
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LibraryPalette.line).frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    private func activate(_ item: Item) {
        if item.kind == .text { onPreview(item) } else { library.open(item) }
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let items = library.items
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0.id == library.selectedID }
        let target = current.map { min(max($0 + delta, 0), items.count - 1) } ?? 0
        library.selectedID = items[target].id
        proxy.scrollTo(items[target].id)
        return .handled
    }
}

private struct ItemRow: View {
    let item: Item
    let columns: (note: CGFloat, source: CGFloat, captured: CGFloat)
    var shortDate = false
    let selected: Bool
    let striped: Bool
    @Local private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                item.icon.image()
                    .foregroundStyle(selected ? AnyShapeStyle(LibraryPalette.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(item.displayTitle)
                    .lineLimit(1)
                if item.favorite {
                    KeptIcon.starFill.image(size: 12)
                        .foregroundStyle(LibraryPalette.accent)
                        .accessibilityLabel("Favorite")
                }
            }
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            if columns.note > 0 {
                cell(item.note.replacingOccurrences(of: "\n", with: " "), width: columns.note)
            }
            if columns.source > 0 {
                cell(item.sourceApp ?? item.method.label, width: columns.source)
            }
            cell(item.createdAt.formatted(date: .abbreviated, time: shortDate ? .omitted : .shortened), width: columns.captured)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.trailing, 12)
            .frame(width: width, alignment: .leading)
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(LibraryPalette.accent.opacity(0.18)) }
        if hovering { return AnyShapeStyle(Color.primary.opacity(0.06)) }
        return AnyShapeStyle(Color.primary.opacity(striped ? 0 : 0.03))
    }
}

private extension ItemFilter {
    var icon: KeptIcon {
        switch self {
        case .all: return .tray
        case .snips: return .cornersOut
        case .images: return .image
        case .links: return .link
        case .text: return .textAlignLeft
        case .favorites: return .star
        }
    }
}

extension Item {
    /// What dragging the item out of Kept carries: the image file, the link, or the text.
    var dragProvider: NSItemProvider {
        switch kind {
        case .image:
            if let url = assetURL, let provider = NSItemProvider(contentsOf: url) { return provider }
            return NSItemProvider()
        case .link:
            if let url = linkURL { return NSItemProvider(object: url as NSURL) }
            return NSItemProvider(object: text as NSString)
        case .text:
            return NSItemProvider(object: text as NSString)
        }
    }

    /// The title, or a stand-in when the user has cleared it.
    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
    }

    var icon: KeptIcon {
        switch kind {
        case .image: return method == .snip ? .cornersOut : .image
        case .link: return .link
        case .text: return .textAlignLeft
        }
    }

    /// "Just now", "5 minutes ago", "yesterday". Seconds are not shown: they are stale as soon as drawn.
    func age(at now: Date = Date()) -> String {
        if now.timeIntervalSince(createdAt) < 60 { return "Just now" }
        return createdAt.formatted(.relative(presentation: .named))
    }

    var host: String {
        guard var host = linkURL?.host else { return text }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
