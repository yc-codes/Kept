import AppKit

/// Lets the user crop the single frame approved through the system sharing picker.
@MainActor
final class SnipCropView: NSView {
    private let image: NSImage
    private var start: CGPoint?
    private var selection = CGRect.zero

    private init(image: CGImage, size: CGSize) {
        self.image = NSImage(cgImage: image, size: size)
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    static func select(in image: CGImage) -> CGImage? {
        guard let screen = NSScreen.main else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let scale = min(1, screen.visibleFrame.width * 0.9 / width, screen.visibleFrame.height * 0.85 / height)
        let view = SnipCropView(image: image, size: CGSize(width: width * scale, height: height * scale))
        let panel = NSPanel(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Drag to snip • Esc to cancel"
        panel.contentView = view
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(view)
        let result = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        guard result == .OK else { return nil }
        let pixels = view.selection.applying(CGAffineTransform(scaleX: width / view.bounds.width, y: height / view.bounds.height))
        return image.cropping(to: pixels.integral)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        guard !selection.isEmpty else { return }
        let outside = NSBezierPath(rect: bounds)
        outside.appendRect(selection)
        outside.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.4).setFill()
        outside.fill()
        NSColor.white.setStroke()
        NSBezierPath(rect: selection).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                           width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        start = nil
        if !selection.isEmpty { NSApp.stopModal(withCode: .OK) }
    }

    override func cancelOperation(_ sender: Any?) { NSApp.stopModal(withCode: .cancel) }
}
