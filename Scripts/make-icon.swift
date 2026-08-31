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

/// Draw one square icon at `size` points: a trunk with two branches leaving it, one
/// still open and one merged back.
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

    let trunkX = rect.minX + rect.width * 0.30
    let branchX = rect.maxX - rect.width * 0.28
    let top = rect.maxY - rect.height * 0.18
    let bottom = rect.minY + rect.height * 0.18
    let nodeRadius = rect.width * 0.072

    // The trunk: the working copy, running the whole height.
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
    context.move(to: CGPoint(x: trunkX, y: bottom))
    context.addLine(to: CGPoint(x: trunkX, y: top))
    context.strokePath()

    /// A branch leaving the trunk at `y` and curving out to `branchX`.
    func branch(from y: CGFloat, to endY: CGFloat, alpha: CGFloat, merged: Bool) {
        context.setStrokeColor(CGColor(gray: 1, alpha: alpha))
        context.move(to: CGPoint(x: trunkX, y: y))
        context.addCurve(
            to: CGPoint(x: branchX, y: endY),
            control1: CGPoint(x: trunkX + rect.width * 0.20, y: y),
            control2: CGPoint(x: branchX - rect.width * 0.12, y: endY - (endY - y) * 0.55)
        )
        context.strokePath()

        if merged {
            // Curves back into the trunk higher up: work that landed.
            context.move(to: CGPoint(x: branchX, y: endY))
            context.addCurve(
                to: CGPoint(x: trunkX, y: top),
                control1: CGPoint(x: branchX, y: endY + (top - endY) * 0.55),
                control2: CGPoint(x: trunkX + rect.width * 0.20, y: top)
            )
            context.strokePath()
        }
    }

    branch(from: bottom + rect.height * 0.20, to: rect.midY + rect.height * 0.10, alpha: 0.95, merged: true)
    branch(from: rect.midY - rect.height * 0.06, to: bottom + rect.height * 0.06, alpha: 0.7, merged: false)

    /// A filled dot marking a commit.
    func node(_ point: CGPoint, filled: Bool) {
        let box = CGRect(
            x: point.x - nodeRadius, y: point.y - nodeRadius,
            width: nodeRadius * 2, height: nodeRadius * 2
        )
        if filled {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: box)
        } else {
            // Hollow: the branch that has not been pushed anywhere yet.
            context.setFillColor(CGColor(red: 0.13, green: 0.5, blue: 0.63, alpha: 1))
            context.fillEllipse(in: box)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            context.setLineWidth(line * 0.8)
            context.strokeEllipse(in: box.insetBy(dx: line * 0.4, dy: line * 0.4))
        }
    }

    node(CGPoint(x: trunkX, y: top), filled: true)
    node(CGPoint(x: trunkX, y: bottom), filled: true)
    node(CGPoint(x: branchX, y: rect.midY + rect.height * 0.10), filled: true)
    node(CGPoint(x: branchX, y: bottom + rect.height * 0.06), filled: false)

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
