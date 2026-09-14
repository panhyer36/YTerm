// Renders a simple app icon (two panes with a sync arrow) into an .iconset directory.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = args[1]
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.08
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: size * 0.2, yRadius: size * 0.2)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.75, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.17, blue: 0.42, alpha: 1),
    ])!
    gradient.draw(in: background, angle: -70)

    // Two "panes"
    let paneWidth = size * 0.30
    let paneHeight = size * 0.46
    let paneY = size * 0.27
    let leftPane = NSRect(x: size * 0.15, y: paneY, width: paneWidth, height: paneHeight)
    let rightPane = NSRect(x: size * 0.55, y: paneY, width: paneWidth, height: paneHeight)
    for pane in [leftPane, rightPane] {
        let path = NSBezierPath(roundedRect: pane, xRadius: size * 0.04, yRadius: size * 0.04)
        NSColor(calibratedWhite: 1, alpha: 0.92).setFill()
        path.fill()
        // lines representing files
        NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.75, alpha: 0.35).setFill()
        for i in 0..<4 {
            let lineRect = NSRect(x: pane.minX + size * 0.04, y: pane.maxY - size * 0.08 - CGFloat(i) * size * 0.10, width: pane.width - size * 0.08, height: size * 0.035)
            NSBezierPath(roundedRect: lineRect, xRadius: size * 0.015, yRadius: size * 0.015).fill()
        }
    }

    // Sync arrows in the middle
    let arrow = NSBezierPath()
    let midX = size * 0.5
    let arrowHalf = size * 0.07
    let thickness = size * 0.035
    func drawArrow(y: CGFloat, pointingRight: Bool) {
        let p = NSBezierPath()
        let startX = pointingRight ? midX - arrowHalf : midX + arrowHalf
        let endX = pointingRight ? midX + arrowHalf : midX - arrowHalf
        p.move(to: NSPoint(x: startX, y: y))
        p.line(to: NSPoint(x: endX, y: y))
        p.lineWidth = thickness
        p.lineCapStyle = .round
        NSColor(calibratedRed: 1, green: 0.78, blue: 0.2, alpha: 1).setStroke()
        p.stroke()
        let head = NSBezierPath()
        let dir: CGFloat = pointingRight ? 1 : -1
        head.move(to: NSPoint(x: endX - dir * size * 0.05, y: y + size * 0.05))
        head.line(to: NSPoint(x: endX, y: y))
        head.line(to: NSPoint(x: endX - dir * size * 0.05, y: y - size * 0.05))
        head.lineWidth = thickness
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.stroke()
    }
    drawArrow(y: size * 0.56, pointingRight: true)
    drawArrow(y: size * 0.42, pointingRight: false)
    _ = arrow
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to path: String, pixelSize: Int) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in sizes {
    let image = render(size: CGFloat(entry.pixels))
    writePNG(image, to: outputDirectory + "/" + entry.name + ".png", pixelSize: entry.pixels)
}
print("icons written to \(outputDirectory)")
