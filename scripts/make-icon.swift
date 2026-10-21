import AppKit
import ImageIO
import UniformTypeIdentifiers

// Usage: swift scripts/make-icon.swift OUTPUT.iconset SOURCE_IMAGE
precondition(CommandLine.arguments.count == 3, "Expected output iconset and source image paths")
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot read source image: \(sourceURL.path)")
}
let side = min(image.width, image.height)
let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                  width: side, height: side)
guard let square = image.cropping(to: crop) else { fatalError("Cannot crop source image") }
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot create icon canvas") }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = CGRect(x: 72, y: 72, width: 880, height: 880)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 196, cornerHeight: 196, transform: nil))
        context.clip()
        context.interpolationQuality = .high
        context.draw(square, in: rect)
        let suffix = scale == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        guard let rendered = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Cannot encode icon") }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save icon") }
    }
}
