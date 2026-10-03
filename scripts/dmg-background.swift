import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3,
      ["unsigned-development", "developer-id-notarized"].contains(CommandLine.arguments[2]) else {
    fail("Usage: swift scripts/dmg-background.swift OUTPUT MODE")
}

// Finder's 560x340 window includes a 32-point title bar.
let size = NSSize(width: 560, height: 308)
let unsigned = CommandLine.arguments[2] == "unsigned-development"
var images: [NSBitmapImageRep] = []

for scale in [1, 2] {
    guard let image = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: image) else {
        fail("Cannot create DMG background graphics context")
    }
    image.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    // A neutral midtone keeps Finder's light and dark icon labels readable.
    NSColor(calibratedWhite: 0.465, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    func text(_ value: String, top: CGFloat, height: CGFloat,
              font: NSFont, color: NSColor = .white) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ]
        (value as NSString).draw(
            in: NSRect(x: 20, y: size.height - top - height,
                       width: size.width - 40, height: height),
            withAttributes: attributes
        )
    }

    if unsigned {
        text("UNSIGNED DEVELOPMENT", top: 42, height: 20,
             font: .systemFont(ofSize: 12, weight: .bold),
             color: NSColor(calibratedRed: 1, green: 0.9, blue: 0.65, alpha: 1))
        text("Not Developer ID signed or notarized", top: 65, height: 18,
             font: .systemFont(ofSize: 11))
    }

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 256, y: size.height - 162))
    arrow.line(to: NSPoint(x: 304, y: size.height - 162))
    arrow.move(to: NSPoint(x: 293, y: size.height - 151))
    arrow.line(to: NSPoint(x: 304, y: size.height - 162))
    arrow.line(to: NSPoint(x: 293, y: size.height - 173))
    arrow.lineWidth = 2
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(calibratedWhite: 1, alpha: 0.75).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    images.append(image)
}

guard let data = NSBitmapImageRep.representationOfImageReps(
    in: images, using: .tiff, properties: [:]
) else {
    fail("Cannot encode DMG background")
}
do {
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
} catch {
    fail("Cannot save DMG background: \(error.localizedDescription)")
}
