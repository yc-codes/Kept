import KeptCore
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var library: LibraryStore
    let item: Item
    let onDelete: () -> Void

    @Local private var note: String
    @Local private var title: String
    @Local private var copied = false

    init(item: Item, onDelete: @escaping () -> Void) {
        self.item = item
        self.onDelete = onDelete
        _note = Local(wrappedValue: item.note)
        _title = Local(wrappedValue: item.title)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Title", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(LibraryPalette.heading(26))
                    .lineLimit(1...3)
                    .onChange(of: title) { library.setTitle(item.id, title) }

                preview

                HStack(spacing: 8) {
                    Button {
                        guard library.copy(item) else { return }
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    if item.kind != .text {
                        Button {
                            library.open(item)
                        } label: {
                            Label(item.kind == .link ? "Open Link" : "Open", systemImage: "arrow.up.forward.square")
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        library.toggleFavorite(item)
                    } label: {
                        Image(systemName: item.favorite ? "star.fill" : "star")
                            .foregroundStyle(item.favorite ? LibraryPalette.accent : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(item.favorite ? "Remove from Favorites" : "Add to Favorites")
                    .help(item.favorite ? "Remove from Favorites" : "Add to Favorites")
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete")
                    .help("Delete")
                }
                .controlSize(.regular)

                section("Your Note") {
                    ZStack(alignment: .topLeading) {
                        if note.isEmpty {
                            Text("Why did you save this?")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $note)
                            .accessibilityLabel("Your Note")
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .frame(minHeight: 84)
                            .onChange(of: note) { library.setNote(item.id, note) }
                    }
                    .background(LibraryPalette.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(LibraryPalette.line)
                    }
                }

                if item.kind == .link {
                    section("Link") {
                        Text(item.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if item.kind == .image {
                    section("Text in Image") {
                        if !item.ocrDone {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Reading text…").foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        } else if item.ocrText.isEmpty {
                            Text("No text found.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(item.ocrText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(14)
                        }
                    }
                }

                if !item.aiDescription.isEmpty {
                    section("Generated Description") {
                        Text(item.aiDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                section("Details") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        detail("Kind", item.kind.label)
                        detail("Captured", item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        detail("How", item.method.label)
                        if let app = item.sourceApp { detail("From", app) }
                        if item.kind == .image { detail("Size", "\(item.width) × \(item.height)") }
                        detail("ID", item.id)
                    }
                    .font(.callout)
                }
            }
            .padding(18)
        }
        .background(LibraryPalette.sidebar)
        .tint(LibraryPalette.accent)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .image:
            Group {
                if item.isGIF, let url = item.assetURL {
                    AnimatedImage(url: url)
                } else {
                    ThumbnailView(item: item)
                }
            }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .background(LibraryPalette.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(LibraryPalette.line)
                }
                .onTapGesture(count: 2) { library.open(item) }
        case .text:
            ScrollView {
                Text(item.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(LibraryPalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LibraryPalette.line)
            }
        case .link:
            ItemPreview(item: item)
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
