import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@main
struct MakeFixtures {
    private static let size = 64

    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw error("Expected a new output directory.") }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            guard !FileManager.default.fileExists(atPath: root.path) else { throw error("Output already exists.") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(".lease"), options: .withoutOverwriting)
            try makeImage(root.appendingPathComponent("still.png"), type: UTType.png.identifier, frames: 1)
            try makeImage(root.appendingPathComponent("animated.gif"), type: UTType.gif.identifier, frames: 2)
            try makeImage(root.appendingPathComponent("animated.png"), type: UTType.png.identifier, frames: 2)
            try await makeVideo(root.appendingPathComponent("video.mov"))
            let manifest: [String: Any] = ["schemaVersion": 1, "entries": [
                ["file": "still.png", "kind": "image"], ["file": "animated.gif", "kind": "animatedImage"],
                ["file": "animated.png", "kind": "animatedImage"], ["file": "video.mov", "kind": "video"]]]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("probe.json"), options: .withoutOverwriting)
            print("GENERATED four original media fixtures: \(root.path)")
        } catch { fputs("FIXTURE GENERATION FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    private static func makeImage(_ url: URL, type: String, frames: Int) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw error("Cannot create fixture image.")
        }
        for index in 0..<frames {
            context.setFillColor(index == 0 ? NSColor.red.cgColor : NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            guard let image = context.makeImage() else { throw error("Cannot create fixture pixels.") }
            let properties: [CFString: Any] = type == UTType.gif.identifier
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.2]]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw error("Cannot encode fixture image.") }
    }

    private static func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? error("Fixture encoder did not start.") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<24 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? error("Fixture encoding failed.") }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard let pool = adaptor.pixelBufferPool else { throw error("Missing pixel buffer pool.") }
            var optional: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess,
                  let buffer = optional else { throw error("Cannot allocate fixture frame.") }
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw error("Cannot lock fixture frame.") }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw error("Missing fixture pixels.") }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<size { for x in 0..<size {
                let offset = y * stride + x * 4
                bytes[offset] = 255; bytes[offset + 1] = (frame / 6) % 2 == 0 ? 255 : 0
                bytes[offset + 2] = 0; bytes[offset + 3] = (frame / 6) % 2 == 0 ? 0 : 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)) else {
                throw writer.error ?? error("Cannot append fixture frame.")
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 24, timescale: 12))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? error("Fixture encoder did not finish.") }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ScreenSaverFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
