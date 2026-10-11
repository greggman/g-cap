// Renders the app icon. Usage: swift tools/make-icon.swift Resources/AppIcon.icns
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func render(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw in a 1024 × 1024 space with a top-left origin.
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: rgb, components: [r, g, b, a])!
    }

    // Body: the standard macOS icon grid, 824 pt with a continuous-ish corner.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0, 0, 0, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0.1, 0.1, 0.14))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: rgb, colors: [color(0.24, 0.26, 0.38), color(0.07, 0.07, 0.11)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Soft top sheen.
    let sheen = CGGradient(colorsSpace: rgb, colors: [color(1, 1, 1, 0.10), color(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 480), options: [])
    ctx.restoreGState()

    // Thin inner edge highlight.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(color(1, 1, 1, 0.12))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Region-selection corner brackets.
    let frame = CGRect(x: 262, y: 262, width: 500, height: 500)
    let arm: CGFloat = 130
    let brackets = CGMutablePath()
    for (x, y, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                           (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
        brackets.move(to: CGPoint(x: x + dx * arm, y: y))
        brackets.addLine(to: CGPoint(x: x, y: y))
        brackets.addLine(to: CGPoint(x: x, y: y + dy * arm))
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: color(0, 0, 0, 0.4))
    ctx.addPath(brackets)
    ctx.setStrokeColor(color(0.96, 0.97, 1))
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // Record dot with a red glow.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 128
    let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: color(1, 0.15, 0.15, 0.75))
    ctx.setFillColor(color(0.9, 0.12, 0.14))
    ctx.fillEllipse(in: dot)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: dot)
    ctx.clip()
    let red = CGGradient(colorsSpace: rgb, colors: [color(1, 0.45, 0.42), color(0.93, 0.16, 0.17), color(0.72, 0.06, 0.1)] as CFArray,
                         locations: [0, 0.55, 1])!
    ctx.drawRadialGradient(red, startCenter: CGPoint(x: center.x - 40, y: center.y - 50), startRadius: 0,
                           endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
    // Specular highlight.
    let spec = CGGradient(colorsSpace: rgb, colors: [color(1, 1, 1, 0.55), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(spec, startCenter: CGPoint(x: center.x - 45, y: center.y - 60), startRadius: 0,
                           endCenter: CGPoint(x: center.x - 45, y: center.y - 60), endRadius: 70, options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
// Also keep a 1024 px PNG next to the .icns for the README and previews.
writePNG(render(size: 1024), to: output.deletingPathExtension().appendingPathExtension("png"))
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
