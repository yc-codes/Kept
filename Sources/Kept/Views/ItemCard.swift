import KeptCore
import SwiftUI

struct ThumbnailView: View {
    let item: Item
    var contentMode: ContentMode = .fit
    @Local private var image: NSImage? = nil

    var body: some View {
        ZStack {
            if let image = image ?? ThumbnailCache.shared.cached(item.id) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: item.id) {
            image = await ThumbnailCache.shared.image(for: item)
        }
    }
}

/// The picture, text excerpt or link badge that stands for an item.
struct ItemPreview: View {
    let item: Item
    var compact = false

    var body: some View {
        switch item.kind {
        case .image:
            LibraryPalette.inset
                .overlay {
                    ThumbnailView(item: item, contentMode: .fill)
                }
                .clipped()
        case .text:
            Group {
                if compact {
                    KeptIcon.textAlignLeft.image()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        KeptIcon.quotes.image()
                            .foregroundStyle(.secondary)
                        Text(String(item.text.prefix(420)))
                            .font(.system(size: 15, weight: .medium))
                            .multilineTextAlignment(.leading)
                            .lineLimit(4)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .background(LibraryPalette.inset)
        case .link:
            VStack(alignment: compact ? .center : .leading, spacing: 7) {
                KeptIcon.arrowUpRight.image(size: compact ? 14 : 22)
                if !compact {
                    Spacer(minLength: 0)
                    Text(item.host)
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .truncationMode(.middle)
                    if let path = item.linkURL?.path, !path.isEmpty, path != "/" {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .opacity(0.75)
                    }
                }
            }
            .padding(compact ? 2 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .center : .topLeading)
            .foregroundStyle(.white)
            .background(Color(white: 0.20))
        }
    }
}

struct ItemCard: View {
    let item: Item
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ItemPreview(item: item)
                .frame(height: 152)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if item.isGIF {
                        Text("GIF")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(LibraryPalette.surface, in: RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(LibraryPalette.line).frame(height: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    item.icon.image()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(item.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.favorite {
                        KeptIcon.starFill.image(size: 14)
                            .foregroundStyle(LibraryPalette.accent)
                            .accessibilityLabel("Favorite")
                    }
                }
                .font(.callout)
                HStack(spacing: 5) {
                    if !item.note.isEmpty {
                        KeptIcon.note.image(size: 14)
                            .help(item.note)
                    }
                    Text(subtitle)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(selected ? LibraryPalette.selection : LibraryPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? LibraryPalette.accent : LibraryPalette.line, lineWidth: selected ? 2 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var subtitle: String {
        let when = item.createdAt.formatted(.relative(presentation: .named))
        if !item.note.isEmpty { return item.note.replacingOccurrences(of: "\n", with: " ") }
        if let app = item.sourceApp { return "\(app) · \(when)" }
        return when
    }
}
