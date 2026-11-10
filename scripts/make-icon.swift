// Builds AppIcon.icns from the supplied artwork (Resources/AppIcon-source.png).
// The source has a soft shadow smear and ragged semi-transparent fringe, so we:
//   1. find the solid rounded-square artwork (rows/columns that are mostly opaque),
//   2. crop to it (slightly inset to drop the anti-aliased rim),
//   3. mask it to a clean macOS rounded rect, scaled to the 824px-in-1024 icon grid,
//   4. add a soft system-style drop shadow, and render every iconset size from a 1024 master.
// usage: swift scripts/make-icon.swift <source.png> <output.icns>
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write("usage: make-icon.swift <source.png> <output.icns>\n".data(using: .utf8)!); exit(2) }
let sourceURL = URL(fileURLWithPath: args[1])
let output = args[2]

guard let src = NSImage(contentsOf: sourceURL), let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("cannot read \(sourceURL.path)")
}
let w = cg.width, h = cg.height
// Read pixels as RGBA8 (top-left origin).
var px = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let readCtx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
readCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

func solid(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    // Opaque and light (the cream base or its artwork); the shadow smear is dark and/or translucent.
    let a = Int(px[i + 3])
    guard a >= 230 else { return false }
    let lum = (Int(px[i]) * 299 + Int(px[i + 1]) * 587 + Int(px[i + 2]) * 114) / 1000
    return lum * 255 / max(a, 1) > 90
}
// Rows/columns with a substantial run of opaque light pixels belong to the square (the shadow smear is dark/translucent).
func spans(_ count: Int, _ length: Int, _ test: (Int, Int) -> Bool) -> (Int, Int) {
    var counts = [Int](repeating: 0, count: count)
    for a in 0..<count { for b in 0..<length where test(a, b) { counts[a] += 1 } }
    let peak = counts.max() ?? 0
    // Include the rounded-corner region (shorter runs) but not stray fringe pixels.
    let first = counts.firstIndex { $0 > peak / 4 } ?? -1
    let last = counts.lastIndex { $0 > peak / 4 } ?? -1
    return (first, last)
}
let rows = spans(h, w) { y, x in solid(x, y) }     // y in memory order (top-left origin)
let cols = spans(w, h) { x, y in solid(x, y) }
guard rows.0 >= 0, cols.0 >= 0 else { fatalError("no solid artwork found") }
var box = CGRect(x: cols.0, y: rows.0, width: cols.1 - cols.0 + 1, height: rows.1 - rows.0 + 1)
// Use the detected opaque rectangle as-is (the source tile is ~4% wider than tall); it is drawn into a
// true square below, which is a barely visible stretch and keeps every edge clean.
let side = min(box.width, box.height)
let crop = box.insetBy(dx: side * 0.012, dy: side * 0.012)   // drop the anti-aliased rim
print("artwork box in source: \(box.integral)")
let art = cg.cropping(to: crop.integral)!

func master(_ size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let artSide = s * 824 / 1024
    let rect = CGRect(x: (s - artSide) / 2, y: (s - artSide) / 2 + s * 0.006, width: artSide, height: artSide)
    let radius = artSide * 0.2237
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    // Soft drop shadow like first-party icons (skipped at tiny sizes where it would just blur the edge).
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.028, color: CGColor(gray: 0, alpha: 0.30))
        ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.draw(art, in: rect)
    ctx.restoreGState()
    // Hairline edge so the light artwork still reads on light backgrounds.
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.10)); ctx.setLineWidth(max(0.5, s / 512)); ctx.strokePath()
    return ctx.makeImage()!
}

func png(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                     ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! png(master(size)).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output]
try! p.run(); p.waitUntilExit()
// Previews next to the .icns for review.
let base = URL(fileURLWithPath: output).deletingPathExtension()
try? png(master(1024)).write(to: base.appendingPathExtension("png"))
try? png(master(32)).write(to: base.appendingPathComponent("../AppIcon-32.png").standardizedFileURL)
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)
