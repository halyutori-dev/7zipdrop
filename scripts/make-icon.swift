// Builds AppIcon.iconset from Resources/AppIcon-1024.png.
//
// The artwork is a full-bleed 1024x1024 square. macOS icons are not: measured from
// /System/Library/CoreServices/Finder.icns, the opaque body sits inside the canvas with a
// margin and rounded corners whose radius is ~22% of the body. Apple's published grid for
// Big Sur and later is a 1024 canvas with an 824x824 body (100px margin) and a 185.4px
// corner radius, which matches that measurement. Used unmasked, the icon would be a
// hard-edged square, larger than every other icon in the Dock.
//
// The corner is drawn by CALayer with `cornerCurve = .continuous`, i.e. the system's own
// squircle, rather than a hand-rolled approximation of it.
//
// Usage: swift scripts/make-icon.swift <output-dir> [source-png]
import AppKit

let arguments = CommandLine.arguments
let outputDirectory = arguments.count > 1
    ? URL(fileURLWithPath: arguments[1], isDirectory: true)
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

let packageRoot = URL(fileURLWithPath: #filePath)   // scripts/make-icon.swift
    .deletingLastPathComponent()                    // scripts
    .deletingLastPathComponent()                    // <package root>
let sourceURL = arguments.count > 2
    ? URL(fileURLWithPath: arguments[2])
    : packageRoot.appendingPathComponent("Resources/AppIcon-1024.png")

guard let sourceImage = NSImage(contentsOf: sourceURL),
      let source = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("cannot read icon artwork: \(sourceURL.path)\n".utf8))
    exit(1)
}

/// Apple's icon grid, as fractions of the canvas.
private let bodyFraction: CGFloat = 824.0 / 1024.0
private let radiusFraction: CGFloat = 185.4 / 824.0

func draw(size: CGFloat) -> NSBitmapImageRep? {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    let body = (size * bodyFraction).rounded()
    let origin = ((size - body) / 2).rounded()

    let layer = CALayer()
    // `render(in:)` draws the layer's BOUNDS at the context origin and ignores the
    // layer's position, so the margin has to come from a context translation. Measured:
    // setting it on the frame put the body flush in the corner instead of centred.
    layer.frame = CGRect(x: 0, y: 0, width: body, height: body)
    layer.contents = source
    layer.contentsGravity = .resizeAspectFill
    layer.cornerRadius = body * radiusFraction
    layer.cornerCurve = .continuous
    layer.masksToBounds = true
    // Nothing animates here, and an unset content scale renders at 1x regardless of size.
    layer.contentsScale = 1

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.interpolationQuality = .high
    context.cgContext.translateBy(x: origin, y: origin)
    layer.render(in: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    guard let rep = draw(size: variant.size),
          let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent(variant.name))
}
print("wrote \(iconset.path) from \(sourceURL.lastPathComponent)")
