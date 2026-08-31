// Draws the app icon and writes an .icns. Run by Scripts/bundle.sh.
//
// Generating the icon keeps binary assets out of the repository: the only source of
// truth for the artwork is this file.
import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.icns"

/// Draw one square icon at `size` points: two worktrees leaving the working copy and
/// merging back, which traces a W.
func render(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS icons sit in a rounded square inset from the canvas edge.
    let inset = s * 0.086
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = CGPath(
        roundedRect: rect,
        cornerWidth: rect.width * 0.2237,
        cornerHeight: rect.height * 0.2237,
        transform: nil
    )

    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let colors = [
        CGColor(red: 0.11, green: 0.62, blue: 0.55, alpha: 1),
        CGColor(red: 0.16, green: 0.40, blue: 0.72, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }
    context.restoreGState()

    let line = max(1, s * 0.042)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(line)

    let nodeRadius = rect.width * 0.072

    /// A point given as a fraction of the icon's rounded square, origin bottom-left.
    func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
    }

    let workingCopy = point(0.16, 0.80)
    let mergeBack = point(0.50, 0.61)
    let landed = point(0.84, 0.80)

    // One stroke: the shoulders fall as trunks, the feet curve into each other as
    // merges. Drawing it unbroken keeps the apex a single mitred join rather than two
    // round caps stacked on the same point.
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
    context.move(to: workingCopy)
    context.addLine(to: point(0.16, 0.44))
    context.addCurve(
        to: mergeBack,
        control1: point(0.16, 0.20),
        control2: point(0.44, 0.20)
    )
    context.addCurve(
        to: point(0.84, 0.44),
        control1: point(0.56, 0.20),
        control2: point(0.84, 0.20)
    )
    context.addLine(to: landed)
    context.strokePath()

    /// A filled dot marking a commit.
    func node(_ center: CGPoint) {
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: CGRect(
            x: center.x - nodeRadius, y: center.y - nodeRadius,
            width: nodeRadius * 2, height: nodeRadius * 2
        ))
    }

    node(workingCopy)
    node(mergeBack)
    node(landed)

    return context.makeImage()
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("WorktreesUI-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// The set of sizes iconutil expects.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard
        let image = render(size: variant.size),
        let destination = CGImageDestinationCreateWithURL(
            iconset.appendingPathComponent("\(variant.name).png") as CFURL,
            "public.png" as CFString,
            1,
            nil
        )
    else {
        FileHandle.standardError.write(Data("Failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
