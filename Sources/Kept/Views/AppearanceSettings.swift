import SwiftUI

struct AppearanceSettingsTab: View {
    @EnvironmentObject private var settings: CaptureSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Theme", "Choose how Kept looks, or match your Mac’s appearance.") {
                HStack(spacing: 12) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        themeButton(theme)
                    }
                }
            }

            section("Accent color", "Used for selection, primary buttons and highlights.") {
                HStack(spacing: 10) {
                    ForEach(AccentChoice.allCases) { accent in
                        AccentSwatch(accent: accent, selected: settings.accent == accent) {
                            settings.accent = accent
                        }
                    }
                    Spacer(minLength: 8)
                    Text(settings.accent.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .settingsCard()
            }

            section("Library", "How saved items are laid out in the main window.") {
                VStack(spacing: 0) {
                    row("Card size", "Smaller cards fit more on screen.") {
                        // Drawn by hand: the system segmented control brightens the tint under its white
                        // label, which made some accents hard to read.
                        HStack(spacing: 2) {
                            ForEach(CardSize.allCases) { size in
                                let selected = settings.cardSize == size
                                Button {
                                    settings.cardSize = size
                                } label: {
                                    Text(size.label)
                                        .font(.callout.weight(selected ? .semibold : .regular))
                                        .foregroundStyle(selected ? AnyShapeStyle(LibraryPalette.accent) : AnyShapeStyle(.primary))
                                        .padding(.horizontal, 12)
                                        .frame(height: 24)
                                        .background(
                                            selected ? AnyShapeStyle(LibraryPalette.accent.opacity(0.16)) : AnyShapeStyle(Color.clear),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .padding(2)
                        .background(LibraryPalette.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Card size")
                    }
                    Divider().padding(.leading, 12)
                    row("Crop images to fill cards", "Turn off to see each picture whole.") {
                        Toggle("Crop images to fill cards", isOn: $settings.cropThumbnails).labelsHidden()
                    }
                    Divider().padding(.leading, 12)
                    row("Show counts in the sidebar", "The number of items next to each filter.") {
                        Toggle("Show counts in the sidebar", isOn: $settings.showSidebarCounts).labelsHidden()
                    }
                }
                .toggleStyle(.switch)
                .settingsCard()
            }
        }
        .padding(20)
    }

    private func section<Content: View>(
        _ title: String, _ detail: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func row<Control: View>(
        _ title: String, _ detail: String, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func themeButton(_ theme: AppTheme) -> some View {
        let selected = settings.theme == theme
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return Button {
            settings.theme = theme
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ThemePreview(theme: theme)
                    .accessibilityHidden(true)
                HStack(spacing: 5) {
                    theme.icon.image()
                        .foregroundStyle(selected ? AnyShapeStyle(LibraryPalette.accent) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    Text(theme.rawValue.capitalized)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    if selected {
                        KeptIcon.checkCircle.image()
                            .foregroundStyle(LibraryPalette.accent)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 3)
            }
            .padding(8)
            .padding(.bottom, 2)
            .background(LibraryPalette.surface, in: shape)
            .overlay {
                shape.strokeBorder(
                    selected ? AnyShapeStyle(LibraryPalette.accent) : AnyShapeStyle(LibraryPalette.line),
                    lineWidth: selected ? 2 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(theme == .system ? "Follows the macOS appearance" : "")
    }
}

private struct AccentSwatch: View {
    let accent: AccentChoice
    let selected: Bool
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(accent.color)
                .frame(width: 22, height: 22)
                .overlay {
                    if selected {
                        KeptIcon.check.image(size: 12)
                            .foregroundStyle(LibraryPalette.surface)
                    }
                }
                .padding(4)
                .overlay {
                    Circle().strokeBorder(accent.color.opacity(selected ? 1 : (hovering ? 0.45 : 0)), lineWidth: 2)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(accent.label)
        .accessibilityLabel(accent.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// The rounded, bordered group that settings rows sit in.
    func settingsCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay { shape.strokeBorder(Color(nsColor: .separatorColor)) }
    }
}

private struct ThemePreview: View {
    let theme: AppTheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        libraryPreview
            .environment(\.colorScheme, theme == .dark ? .dark : .light)
            .overlay {
                if theme == .system {
                    libraryPreview
                        .environment(\.colorScheme, .dark)
                        .mask {
                            HStack(spacing: 0) {
                                Color.clear
                                Rectangle()
                            }
                        }
                }
            }
            .frame(height: 94)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.quaternary) }
    }

    private var libraryPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in
                    Circle().fill(.tertiary).frame(width: 3, height: 3)
                }
                Spacer()
                KeptIcon.magnifyingGlass.image(size: 8)
                    .foregroundStyle(.secondary)
                bar(width: 21)
            }
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(LibraryPalette.surface, in: Rectangle())

            Rectangle().fill(LibraryPalette.line).frame(height: 1)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    KeptIcon.tray.image(size: 9)
                        .foregroundStyle(LibraryPalette.accent)
                    bar(width: 19)
                    bar(width: 14)
                    bar(width: 17)
                }
                .frame(width: 26, alignment: .leading)
                .padding(6)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(LibraryPalette.sidebar, in: Rectangle())

                Rectangle().fill(LibraryPalette.line).frame(width: 1)

                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(.secondary).frame(width: 31, height: 4)
                    HStack(spacing: 5) {
                        tile(.image)
                        tile(.link)
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(LibraryPalette.canvas, in: Rectangle())
            }
        }
        .background(LibraryPalette.canvas, in: Rectangle())
    }

    private func bar(width: CGFloat) -> some View {
        Capsule().fill(.quaternary).frame(width: width, height: 3)
    }

    private func tile(_ icon: KeptIcon) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            icon.image(size: 13)
                .foregroundStyle(LibraryPalette.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(LibraryPalette.inset, in: Rectangle())
            bar(width: 15)
                .padding(.leading, 4)
                .padding(.bottom, 4)
        }
        .background(LibraryPalette.surface, in: Rectangle())
        .clipShape(.rect(cornerRadius: 3))
        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(LibraryPalette.line) }
    }
}

private extension AppTheme {
    var icon: KeptIcon {
        switch self {
        case .system: return .desktop
        case .light: return .sun
        case .dark: return .moon
        }
    }
}
