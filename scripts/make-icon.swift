// Renders the original Claude Profiles app icon into an .iconset and converts it to .icns.
// usage: swift scripts/make-icon.swift <output.icns>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: ~80% artwork inset with a continuous-corner square.
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    color(0x1F2A5C).setFill()
    path.fill()
    ctx.restoreGState()

    ctx.saveGState()
    path.addClip()
    // Base: deep indigo -> violet, lit from the top.
    NSGradient(colors: [color(0x6A5BF0), color(0x4A3BC8), color(0x2A2380)])!.draw(in: rect, angle: -90)
    // Soft key light from the top-left.
    let light = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
    light.draw(fromCenter: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY - rect.height * 0.15), radius: 0,
               toCenter: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY - rect.height * 0.15), radius: rect.width * 0.8, options: [])
    // Ground shadow / vignette at the bottom.
    NSGradient(colors: [NSColor.black.withAlphaComponent(0.28), NSColor.black.withAlphaComponent(0)])!
        .draw(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.45), angle: 90)

    // Three overlapping "profile" figures: head + shoulders, back to front.
    struct Figure { let dx: CGFloat; let dy: CGFloat; let scale: CGFloat; let top: NSColor; let bottom: NSColor }
    let figures = [
        Figure(dx: -0.215, dy: 0.10, scale: 0.8, top: color(0x8BEFE0), bottom: color(0x2FB3A6)),
        Figure(dx: 0.215, dy: 0.10, scale: 0.8, top: color(0xFFC58A), bottom: color(0xE9803A)),
        Figure(dx: 0.0, dy: -0.02, scale: 1.0, top: color(0xFFFFFF), bottom: color(0xDCDDF5)),
    ]
    let cx = rect.midX, cy = rect.midY
    let unit = rect.width
    let floorY = cy - unit * 0.30
    for f in figures {
        let bodyW = unit * 0.36 * f.scale
        let headR = unit * 0.105 * f.scale
        let baseline = cy - unit * 0.24 + unit * f.dy * 0.5
        let x = cx + unit * f.dx
        let shoulder = bodyW * 0.42
        let bodyRect = CGRect(x: x - bodyW / 2, y: baseline - bodyW * 0.4, width: bodyW, height: bodyW * 0.4 + shoulder)
        let headC = CGPoint(x: x, y: baseline + shoulder + unit * 0.035 * f.scale + headR)
        let figure = NSBezierPath(roundedRect: bodyRect, xRadius: bodyW * 0.42, yRadius: bodyW * 0.42)
        figure.append(NSBezierPath(ovalIn: CGRect(x: headC.x - headR, y: headC.y - headR, width: 2 * headR, height: 2 * headR)))

        ctx.saveGState()
        ctx.clip(to: CGRect(x: rect.minX, y: max(baseline, floorY), width: rect.width, height: rect.height))
        // Drop shadow separates overlapping figures and gives depth.
        ctx.setShadow(offset: CGSize(width: 0, height: -unit * 0.012), blur: unit * 0.035, color: NSColor(srgbRed: 0.08, green: 0.04, blue: 0.3, alpha: 0.55).cgColor)
        f.bottom.setFill()
        figure.fill()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: CGRect(x: rect.minX, y: max(baseline, floorY), width: rect.width, height: rect.height))
        figure.addClip()
        NSGradient(colors: [f.top, f.bottom])!.draw(in: CGRect(x: x - bodyW, y: baseline, width: bodyW * 2, height: headC.y + headR - baseline), angle: -90)
        // Specular highlight on the head.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0)])!
            .draw(fromCenter: CGPoint(x: headC.x - headR * 0.35, y: headC.y + headR * 0.45), radius: 0,
                  toCenter: CGPoint(x: headC.x - headR * 0.35, y: headC.y + headR * 0.45), radius: headR * 0.9, options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Bezel: bright top edge, darker bottom edge, like system icons.
    let edge = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.003, dy: s * 0.003), xRadius: rect.width * 0.222, yRadius: rect.width * 0.222)
    edge.lineWidth = max(1, s * 0.006)
    ctx.saveGState()
    let strokeImage = NSGradient(colors: [NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0.0), NSColor.white.withAlphaComponent(0.08)])!
    ctx.addPath(edge.cgPathCompat)
    ctx.setLineWidth(edge.lineWidth)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    strokeImage.draw(in: rect, angle: -90)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(size: px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output]
try! p.run()
p.waitUntilExit()
let preview = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png")
try? FileManager.default.removeItem(at: preview)
try? FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512.png"), to: preview)
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)

extension NSBezierPath {
    var cgPathCompat: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
