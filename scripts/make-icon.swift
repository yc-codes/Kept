// Draws the Kept app icon. Usage: swift scripts/make-icon.swift <output.png>
//
// A captured fragment is lifted out of a viewfinder.
import AppKit

let side: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Standard macOS icon grid: an 824pt rounded square centred on a 1024pt canvas.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)

NSGraphicsContext.saveGraphicsState()
let drop = NSShadow()
drop.shadowColor = NSColor.black.withAlphaComponent(0.30)
drop.shadowBlurRadius = 26
drop.shadowOffset = NSSize(width: 0, height: -12)
drop.set()
color(0x242B3A).setFill()
platePath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [color(0x343E50), color(0x1B202D)])!.draw(in: platePath, angle: -90)
platePath.lineWidth = 2
color(0xCED8EA, 0.25).setStroke()
platePath.stroke()

// Three corners remain in place. The lifted fragment occupies the fourth.
let finder = NSBezierPath()
finder.lineWidth = 43
finder.lineCapStyle = .round
finder.lineJoinStyle = .round

func corner(from start: NSPoint, through elbow: NSPoint, to end: NSPoint) {
    finder.move(to: start)
    finder.line(to: elbow)
    finder.line(to: end)
}

corner(from: NSPoint(x: 318, y: 567), through: NSPoint(x: 318, y: 693), to: NSPoint(x: 444, y: 693))
corner(from: NSPoint(x: 318, y: 445), through: NSPoint(x: 318, y: 319), to: NSPoint(x: 444, y: 319))
corner(from: NSPoint(x: 566, y: 319), through: NSPoint(x: 692, y: 319), to: NSPoint(x: 692, y: 445))
color(0xF1E8D8).setStroke()
finder.stroke()

NSGraphicsContext.saveGraphicsState()
let tilt = NSAffineTransform()
tilt.translateX(by: 623, yBy: 629)
tilt.rotate(byDegrees: -12)
tilt.concat()

// A cut corner gives the lifted fragment a distinct silhouette at Dock size.
let fragment = NSBezierPath()
fragment.move(to: NSPoint(x: -117, y: -89))
fragment.line(to: NSPoint(x: -117, y: 117))
fragment.line(to: NSPoint(x: 57, y: 117))
fragment.line(to: NSPoint(x: 117, y: 57))
fragment.line(to: NSPoint(x: 117, y: -117))
fragment.line(to: NSPoint(x: -89, y: -117))
fragment.close()

let lift = NSShadow()
lift.shadowColor = NSColor.black.withAlphaComponent(0.32)
lift.shadowBlurRadius = 20
lift.shadowOffset = NSSize(width: 0, height: -9)
NSGraphicsContext.saveGraphicsState()
lift.set()
color(0xFFB17E).setFill()
fragment.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [color(0xFFD6A0), color(0xFF996D)])!.draw(in: fragment, angle: -90)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
