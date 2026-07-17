import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: MakeIcon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

guard let context = NSGraphicsContext.current else {
    image.unlockFocus()
    fputs("Could not create drawing context\n", stderr)
    exit(1)
}

context.imageInterpolation = .high

let canvas = NSRect(origin: .zero, size: size)
let backgroundRect = canvas.insetBy(dx: 50, dy: 50)
let backgroundPath = NSBezierPath(
    roundedRect: backgroundRect,
    xRadius: 218,
    yRadius: 218
)

let backgroundShadow = NSShadow()
backgroundShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
backgroundShadow.shadowBlurRadius = 34
backgroundShadow.shadowOffset = NSSize(width: 0, height: -18)
backgroundShadow.set()

let gradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.18, green: 0.31, blue: 0.88, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.13, blue: 0.70, alpha: 1)
    ]
)
gradient?.draw(in: backgroundPath, angle: -55)

NSGraphicsContext.saveGraphicsState()

let driveShadow = NSShadow()
driveShadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
driveShadow.shadowBlurRadius = 26
driveShadow.shadowOffset = NSSize(width: 0, height: -12)
driveShadow.set()

let driveRect = NSRect(x: 218, y: 287, width: 588, height: 425)
let drivePath = NSBezierPath(
    roundedRect: driveRect,
    xRadius: 98,
    yRadius: 98
)
NSColor.white.withAlphaComponent(0.97).setFill()
drivePath.fill()

NSGraphicsContext.restoreGraphicsState()

let slotPath = NSBezierPath(
    roundedRect: NSRect(x: 322, y: 525, width: 380, height: 35),
    xRadius: 17.5,
    yRadius: 17.5
)
NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.54, alpha: 0.86).setFill()
slotPath.fill()

let indicatorPath = NSBezierPath(
    ovalIn: NSRect(x: 350, y: 391, width: 48, height: 48)
)
NSColor(calibratedRed: 0.10, green: 0.72, blue: 0.45, alpha: 1).setFill()
indicatorPath.fill()

NSGraphicsContext.saveGraphicsState()

let badgeShadow = NSShadow()
badgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
badgeShadow.shadowBlurRadius = 18
badgeShadow.shadowOffset = NSSize(width: 0, height: -8)
badgeShadow.set()

let badgeRect = NSRect(x: 624, y: 206, width: 244, height: 244)
let badgePath = NSBezierPath(ovalIn: badgeRect)
NSColor(calibratedRed: 0.10, green: 0.72, blue: 0.45, alpha: 1).setFill()
badgePath.fill()

NSGraphicsContext.restoreGraphicsState()

let check = NSBezierPath()
check.lineWidth = 34
check.lineCapStyle = .round
check.lineJoinStyle = .round
check.move(to: NSPoint(x: 682, y: 326))
check.line(to: NSPoint(x: 735, y: 271))
check.line(to: NSPoint(x: 823, y: 376))
NSColor.white.setStroke()
check.stroke()

image.unlockFocus()

guard
    let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Could not encode icon\n", stderr)
    exit(1)
}

try pngData.write(to: outputURL)
