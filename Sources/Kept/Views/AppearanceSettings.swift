import SwiftUI

struct AppearanceSettingsTab: View {
    @EnvironmentObject private var settings: CaptureSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Theme")
                    .font(LibraryPalette.heading(24))
                    .accessibilityAddTraits(.isHeader)
                Text("Choose how Kept looks, or match your Mac’s appearance.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    themeButton(theme)
                }
            }
        }
        .padding(24)
    }

    private func themeButton(_ theme: AppTheme) -> some View {
        let selected = settings.theme == theme
        let shape = RoundedRectangle(cornerRadius: 12)

        return Button {
            settings.theme = theme
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ThemePreview(theme: theme)
                    .accessibilityHidden(true)
                HStack(spacing: 5) {
                    theme.icon.image()
                        .foregroundStyle(selected ? LibraryPalette.accent : Color.secondary)
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
                shape.strokeBorder(selected ? LibraryPalette.accent : LibraryPalette.line, lineWidth: selected ? 2 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(theme == .system ? "Follows the macOS appearance" : "")
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
