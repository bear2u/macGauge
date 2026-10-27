import AppKit
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let s = CGFloat(px)
        NSColor(calibratedRed: 0.06, green: 0.13, blue: 0.19, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88), xRadius: s * 0.21, yRadius: s * 0.21).fill()
        let path = NSBezierPath(); path.lineWidth = s * 0.065; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: NSPoint(x: s * 0.2, y: s * 0.48))
        for (x, y) in [(0.34, 0.48), (0.43, 0.7), (0.54, 0.3), (0.65, 0.55), (0.8, 0.55)] { path.line(to: NSPoint(x: s * x, y: s * y)) }
        NSColor(calibratedRed: 0.27, green: 0.88, blue: 0.71, alpha: 1).setStroke(); path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
