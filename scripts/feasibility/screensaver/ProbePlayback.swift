import AppKit
import AVFoundation
import ImageIO

/// Diagnostic fixture playback only; the product will use the shared native player.
@MainActor
final class ProbePlayback {
    private struct Manifest: Decodable { let schemaVersion: Int; let entries: [Entry] }
    private struct Entry: Decodable {
        enum Kind: String, Decodable { case image, animatedImage, video }
        let file: String
        let kind: Kind
    }
    private static let imageHold: Double = 1
    private static let videoHold: Double = 2.5
    private static let firstFrameTimeout: Double = 15
    private let view: NSView
    private let onFrame: (String, Int) -> Void
    private var root: URL?
    private var entries: [Entry] = []
    private var index = 0
    private var selectedAt: Double = 0
    private var displayedAt: Double?
    private var imageSource: CGImageSource?
    private var imageIndex = 0
    private var nextImageTime = 0.0
    private var player: AVPlayer?
    private var videoLayer: AVPlayerLayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var samples: [String: Set<UInt32>] = [:]
    var frameCounts: [String: Int] { samples.mapValues(\.count) }

    init(view: NSView, onFrame: @escaping (String, Int) -> Void) { self.view = view; self.onFrame = onFrame }

    func start(directory: URL) throws {
        root = directory
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file("probe.json")))
        guard manifest.schemaVersion == 1, !manifest.entries.isEmpty else { throw failure("Invalid probe manifest.") }
        entries = manifest.entries
        for entry in entries { _ = try file(entry.file) }
        try select(0)
    }

    func tick() throws {
        guard !entries.isEmpty else { return }
        let entry = entries[index]
        let now = ProcessInfo.processInfo.systemUptime
        if let source = imageSource, now >= nextImageTime {
            guard let image = CGImageSourceCreateImageAtIndex(source, imageIndex, nil) else {
                throw failure("Cannot decode \(entry.file) frame \(imageIndex).")
            }
            view.layer?.contents = image
            record(try pixel(image))
            let count = CGImageSourceGetCount(source)
            nextImageTime = count > 1 ? now + (try delay(source, index: imageIndex)) : .infinity
            imageIndex = (imageIndex + 1) % count
        }
        if let player, let output = videoOutput {
            if player.currentItem?.status == .failed { throw player.currentItem?.error ?? failure("Video decoder failed.") }
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                record(try pixel(buffer))
            }
        }
        if displayedAt == nil, now - selectedAt > Self.firstFrameTimeout { throw failure("No decoded frame: \(entry.file)") }
        let hold = entry.kind == .video ? Self.videoHold : Self.imageHold
        if let displayedAt, now - displayedAt >= hold { try select((index + 1) % entries.count) }
    }

    func stop() {
        stopMedia()
        entries = []
        root = nil
    }

    private func select(_ next: Int) throws {
        stopMedia()
        index = next
        selectedAt = ProcessInfo.processInfo.systemUptime
        displayedAt = nil
        let entry = entries[next]
        let url = try file(entry.file)
        if entry.kind == .video {
            let item = AVPlayerItem(url: url)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            let layer = AVPlayerLayer(player: player)
            layer.frame = view.bounds
            layer.videoGravity = .resizeAspect
            view.layer?.insertSublayer(layer, at: 0)
            self.player = player; videoLayer = layer; videoOutput = output
            player.play()
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                throw failure("Cannot open \(entry.file).")
            }
            imageSource = source; imageIndex = 0; nextImageTime = 0
            view.layer?.contentsGravity = .resizeAspect
        }
    }

    private func stopMedia() {
        player?.isMuted = true
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        videoLayer?.player = nil
        videoLayer?.removeFromSuperlayer()
        player = nil; videoLayer = nil; videoOutput = nil; imageSource = nil
        view.layer?.contents = nil
    }

    private func file(_ name: String) throws -> URL {
        guard let root, !name.isEmpty, name != ".", name != "..",
              URL(fileURLWithPath: name).lastPathComponent == name else { throw failure("Invalid fixture path.") }
        let url = root.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false else {
            throw failure("Fixture must be a regular file: \(name)")
        }
        return url
    }

    private func record(_ sample: UInt32) {
        if displayedAt == nil { displayedAt = ProcessInfo.processInfo.systemUptime }
        let name = entries[index].file
        if samples[name, default: []].insert(sample).inserted { onFrame(name, samples[name]!.count) }
    }

    private func pixel(_ image: CGImage) throws -> UInt32 {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Cannot sample image.") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func pixel(_ buffer: CVPixelBuffer) throws -> UInt32 {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw failure("Cannot sample video.") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw failure("Missing video pixels.") }
        let offset = (CVPixelBufferGetHeight(buffer) / 2) * CVPixelBufferGetBytesPerRow(buffer)
            + (CVPixelBufferGetWidth(buffer) / 2) * 4
        let bytes = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        return (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[$1]) }
    }

    private func delay(_ source: CGImageSource, index: Int) throws -> Double {
        let values = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = values?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = values?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let raw = gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]
            ?? png?[kCGImagePropertyAPNGUnclampedDelayTime] ?? png?[kCGImagePropertyAPNGDelayTime]
        guard let seconds = (raw as? NSNumber)?.doubleValue, seconds.isFinite, seconds > 0 else {
            throw failure("Animation frame is missing a valid duration.")
        }
        return seconds
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "ScreenSaverProbePlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
