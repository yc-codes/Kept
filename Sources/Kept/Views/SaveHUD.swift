import AppKit
import KeptCore
import SwiftUI

/// Brief confirmation shown after a snip: proof it was saved, and a reminder it can be pasted.
@MainActor
final class SaveHUD {
    static let shared = SaveHUD()

    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    func show(_ item: Item) {
        dismissal?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: HUDView(item: item) { [weak self] in
            self?.hide()
            AppServices.shared.showLibrary()
            AppServices.shared.library.reveal(item.id)
        })

        let size = NSSize(width: 320, height: 72)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(
                NSRect(x: frame.maxX - size.width - 20, y: frame.minY + 20, width: size.width, height: size.height),
                display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    private func hide() {
        dismissal?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

private struct HUDView: View {
    let item: Item
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(item: item)
                .frame(width: 64, height: 48)
                .background(Color.black.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text("Saved to Kept")
                } icon: {
                    KeptIcon.checkCircle.image().foregroundStyle(.green)
                }
                .font(.callout.weight(.semibold))
                Text("Copied. Press ⌘V to paste, or click to add a note.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 320, height: 72)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}
