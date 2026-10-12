// Turns the icon design into Folio's Mac app icon.
//
//     swift Tools/Icon/PrepareIcon.swift Tools/Icon/Design.png Folio/Assets.xcassets/AppIcon.appiconset
//
// The design is a 1024 × 1024 export on a dark background, with the tile on
// Apple's macOS icon grid: 824 × 824, 100 px in from each side. Its outline is
// a superellipse with exponent 5, as in the design's SVG (Design.svg).
// Everything outside the tile becomes transparent, a soft shadow is added as
// on other Mac icons, and every size the asset catalog lists is written.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: swift PrepareIcon.swift <design.png> <AppIcon.appiconset>")
    exit(64)
}
let designURL = URL(fileURLWithPath: arguments[1])
let iconSetURL = URL(fileURLWithPath: arguments[2], isDirectory: true)

let canvas = 1024

guard let source = CGImageSourceCreateWithURL(designURL as CFURL, nil),
      let design = CGImageSourceCreateImageAtIndex(source, 0, nil),
      design.width == canvas, design.height == canvas
else {
    print("The design must be a 1024 × 1024 image.")
    exit(1)
}

/// The tile's outline: |x|⁵ + |y|⁵ = 412⁵ around the centre. It's symmetric, so
/// it's the same whichever way up the canvas is.
let outline: CGPath = {
    let path = CGMutablePath()
    let centre = 512.0, radius = 412.0, exponent = 5.0, steps = 1440
    for step in 0...steps {
        let angle = Double(step) / Double(steps) * 2 * .pi
        let (c, s) = (cos(angle), sin(angle))
        let point = CGPoint(
            x: centre + radius * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent),
            y: centre + radius * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        )
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}()
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ size: Int) -> CGContext {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    return context
}

// 1. The tile alone: the design clipped to the outline, antialiased.
let cutOut = context(canvas)
cutOut.addPath(outline)
cutOut.clip()
cutOut.draw(design, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
let tileImage = cutOut.makeImage()!

// 2. The icon: a soft shadow under the tile, then the tile.
let icon = context(canvas)
icon.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.32))
icon.draw(tileImage, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
let iconImage = icon.makeImage()!

// 3. Every size the asset catalog lists.
func write(_ image: CGImage, size: Int, to url: URL) throws {
    let scaled: CGImage
    if size == canvas {
        scaled = image
    } else {
        let small = context(size)
        small.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        scaled = small.makeImage()!
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, scaled, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

struct Slot {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var fileName: String { "AppIcon-\(points)@\(scale)x.png" }
}
let slots = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }

do {
    try FileManager.default.createDirectory(at: iconSetURL, withIntermediateDirectories: true)
    for slot in slots {
        try write(iconImage, size: slot.pixels, to: iconSetURL.appending(path: slot.fileName))
    }
    let images = slots.map { slot in
        ["filename": slot.fileName, "idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.points)x\(slot.points)"]
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: iconSetURL.appending(path: "Contents.json"))
    print("Wrote \(slots.count) sizes to \(iconSetURL.path(percentEncoded: false))")
} catch {
    print("Couldn't write the icon: \(error.localizedDescription)")
    exit(1)
}
