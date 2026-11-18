// Draws the Kept app icon. Usage: swift scripts/make-icon.swift <output.png>
//
// The mark is a "K" built from a stem and a bookmark ribbon lying on its side: the ribbon's
// notch forms the two arms of the letter.
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
color(0xF2542D).setFill()
platePath.fill()
NSGraphicsContext.restoreGraphicsState()

// Warm plate: amber at the top falling to a deep coral.
NSGradient(colors: [color(0xFFB938), color(0xFF7A3D), color(0xEE4B3A)], atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!
    .draw(in: platePath, angle: -90)

// Soft highlight across the top edge.
NSGraphicsContext.saveGraphicsState()
platePath.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 610, width: 824, height: 314), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// The K. Glyph box is 430 x 500, optically centred.
let box = NSRect(x: 304, y: 262, width: 430, height: 500)
let stemWidth: CGFloat = 122
let gap: CGFloat = 40

let glyph = NSBezierPath()
glyph.append(NSBezierPath(
    roundedRect: NSRect(x: box.minX, y: box.minY, width: stemWidth, height: box.height), xRadius: 34, yRadius: 34))

// Ribbon with its notch pointing in from the right.
let left = box.minX + stemWidth + gap
let notch = NSPoint(x: left + 92, y: box.midY)
let ribbon = NSBezierPath()
ribbon.move(to: NSPoint(x: left, y: box.minY + 34))
ribbon.curve(to: NSPoint(x: left + 34, y: box.minY), controlPoint1: NSPoint(x: left, y: box.minY + 15), controlPoint2: NSPoint(x: left + 15, y: box.minY))
ribbon.line(to: NSPoint(x: box.maxX, y: box.minY))
ribbon.line(to: notch)
ribbon.line(to: NSPoint(x: box.maxX, y: box.maxY))
ribbon.line(to: NSPoint(x: left + 34, y: box.maxY))
ribbon.curve(to: NSPoint(x: left, y: box.maxY - 34), controlPoint1: NSPoint(x: left + 15, y: box.maxY), controlPoint2: NSPoint(x: left, y: box.maxY - 15))
ribbon.close()
glyph.append(ribbon)

NSGraphicsContext.saveGraphicsState()
let lift = NSShadow()
lift.shadowColor = color(0x9C2A14, 0.45)
lift.shadowBlurRadius = 22
lift.shadowOffset = NSSize(width: 0, height: -10)
lift.set()
NSColor.white.setFill()
glyph.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [NSColor.white, color(0xFFF1E4)])!.draw(in: glyph, angle: -90)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
