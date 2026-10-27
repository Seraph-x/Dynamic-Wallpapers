import Foundation
import CoreGraphics
import ImageIO
import WallpaperCore
@testable import WallpaperMediaIntegration

struct Failure: Error, CustomStringConvertible { let description: String }
func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }

@main
struct Client {
    static func main() async {
        let arguments = CommandLine.arguments
        let resultURL = arguments.firstIndex(of: "--result-file").map { URL(fileURLWithPath: arguments[$0 + 1]) }
        func record(_ status: String, error: String? = nil) throws {
            guard let resultURL else { return }
            var value: [String: Any] = ["status": status, "pid": ProcessInfo.processInfo.processIdentifier]
            if let error { value["error"] = error }
            try JSONSerialization.data(withJSONObject: value).write(to: resultURL, options: .atomic)
        }
        do {
            try record("running")
            try await run()
            try record("passed")
        } catch {
            fputs("MEDIA_AUTOMATION FAILED: \(error)\n", stderr)
            do { try record("failed", error: String(describing: error)) }
            catch { fputs("MEDIA_AUTOMATION result recording failed: \(error)\n", stderr) }
            exit(1)
        }
    }

    static func run() async throws {
        guard CommandLine.arguments.count >= 4, let pid = Int32(CommandLine.arguments[1]),
              let source = SystemMediaSource(rawValue: CommandLine.arguments[2]), source != .disabled else {
            throw Failure(description: "client needs owned fixture PID, music/spotify, directory")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let authorize = CommandLine.arguments.contains("--authorize-owned-fixture")
        let service = AppleEventMediaService(eventTimeout: 0.15, resolveProcess: { _ in pid })
        if CommandLine.arguments.contains("--expect-exited") {
            let value = try await service.read(source: source, requestAuthorization: false)
            try require(value == .applicationNotRunning, "Exited fixture must be unavailable: \(value)")
            print("MEDIA_AUTOMATION exited_process_pass source=\(source.rawValue)"); return
        }
        try setMode("normal", directory)
        let initial = try await service.read(source: source, requestAuthorization: authorize)
        let first = try current(initial)
        try require(first.trackID == "owned-0" && first.title == "Owned 雪 \"é🎵", "Metadata/Unicode mismatch")
        try require(first.source == source && first.position == 12.5 && first.duration == 180.25, "Provider/timeline units mismatch")
        try require(first.albumArtist == (source == .music ? "Owned Ensemble" : nil), "Album artist semantics mismatch")
        try await service.perform(.pause, source: source)
        try require(try current(await service.read(source: source, requestAuthorization: false)).state == .paused, "Pause did not reach owned process")
        try await service.perform(.play, source: source)
        try require(try current(await service.read(source: source, requestAuthorization: false)).state == .playing, "Play did not reach owned process")
        try await service.perform(.playPause, source: source)
        try require(try current(await service.read(source: source, requestAuthorization: false)).state == .paused, "Toggle did not reach owned process")
        try await service.perform(.skipNext, source: source)
        try require(try current(await service.read(source: source, requestAuthorization: false)).trackID == "owned-1", "Next did not reach owned process")
        try await service.perform(.skipPrevious, source: source)
        try require(try current(await service.read(source: source, requestAuthorization: false)).trackID == "owned-0", "Previous did not reach owned process")
        let receipts = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("receipts.json"))) as? [String]
        try require(receipts == ["Paus", "Play", "PlPs", "Next", "Prev"], "Actual event receipt order mismatch")
        try setMode("missing", directory)
        let missing = try await service.read(source: source, requestAuthorization: false)
        try require(missing == .noCurrentItem, "Missing item must be explicit")
        for mode in ["malformed", "error", "track-change", "timeout"] {
            try setMode(mode, directory)
            do {
                _ = try await service.read(source: source, requestAuthorization: false)
                throw Failure(description: "Expected actual \(mode) failure")
            } catch let error as SystemMediaError {
                switch (mode, error) {
                case ("malformed", .invalidResponse), ("error", .appleEvent(code: -50, message: _)),
                     ("track-change", .trackChangedDuringRead), ("timeout", .appleEvent(code: -1712, message: _)): break
                default: throw Failure(description: "Wrong \(mode) error: \(error)")
                }
            }
            if mode == "timeout" { try await Task.sleep(for: .milliseconds(600)) }
        }
        try setMode("transport-error", directory)
        do { try await service.perform(.pause, source: source); throw Failure(description: "Expected actual transport failure") }
        catch let error as SystemMediaError {
            guard case .appleEvent(code: -1708, message: _) = error else { throw error }
        }
        try await artwork(service: service, source: source, first: first, directory: directory)
        print("MEDIA_AUTOMATION PASS source=\(source.rawValue) metadata=real-AppleEvents controls=5 malformed/error/track-change/timeout/transport-error=observed")
    }

    @MainActor static func artwork(service: AppleEventMediaService, source: SystemMediaSource,
                                   first: SystemMediaSnapshot, directory: URL) async throws {
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("server.json"))) as? [String: String]
        guard let ca = info?["ca"] else { throw Failure(description: "Missing owned TLS fixture CA") }
        let loader = HTTPSArtworkLoader(timeout: 3,
            testTrust: ArtworkTestTrust(anchorDER: try Data(contentsOf: URL(fileURLWithPath: ca)), hostname: "localhost"))
        let identity = SystemMediaArtworkIdentity(first)
        try setMode("normal", directory)
        let input = try await service.readArtwork(for: identity)
        let original = try Data(contentsOf: directory.appendingPathComponent("owned-artwork.png"))
        switch (source, input) {
        case (.music, .embedded(let data)): try require(data == original, "Music must preserve actual raw artwork bytes")
        case (.spotify, .remote(let url)):
            let expected = try String(contentsOf: directory.appendingPathComponent("artwork-url"), encoding: .utf8)
            try require(url.url.absoluteString == expected, "Spotify must preserve its actual aUrl")
        default: throw Failure(description: "Wrong actual provider artwork source")
        }
        let artifact = try await loader.load(input, for: identity)
        try require(artifact.identity == identity && artifact.width == 2 && artifact.height == 1,
                    "Actual artwork identity/dimensions mismatch")
        try verifyPixels(artifact.pngData)
        try setMode("artwork-missing", directory)
        try require(try await service.readArtwork(for: identity) == .unavailable, "Missing artwork must be explicit")
        for mode in ["artwork-error", "artwork-malformed", "track-change"] {
            try setMode(mode, directory)
            do { _ = try await service.readArtwork(for: identity); throw Failure(description: "Expected actual artwork \(mode) failure") }
            catch let error as SystemMediaError {
                switch (mode, error) {
                case ("artwork-error", .appleEvent(code: -50, message: _)),
                     ("artwork-malformed", .invalidResponse), ("track-change", .trackChangedDuringRead): break
                default: throw error
                }
            }
        }
        try setMode("artwork-error", directory)
        let controller = SystemMediaController(service: service, pollInterval: 3600, artworkLoader: loader)
        let demand = UUID()
        controller.configure(source: source); controller.setPlaying(demand, true)
        await controller.settled(); await controller.artwork.settled()
        guard case .failed = controller.artwork.state else { throw Failure(description: "Actual artwork failure must remain visible") }
        try require(controller.status == .available && controller.snapshot != nil && controller.failure == nil,
                    "Artwork failure must preserve valid actual metadata")
        try await controller.perform(.pause)
        try setMode("normal", directory); await controller.artwork.retry()
        guard case .ready = controller.artwork.state else { throw Failure(description: "Actual artwork retry must recover") }
        controller.setPlaying(demand, false)
        try setMode("artwork-slow", directory)
        controller.setPlaying(demand, true); await controller.settled()
        let requested = directory.appendingPathComponent("artwork-requested")
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: requested.path) {
            guard ContinuousClock.now < deadline else { throw Failure(description: "Actual artwork source did not start") }
            try await Task.sleep(for: .milliseconds(5))
        }
        controller.configure(source: .disabled)
        guard case .unavailable = controller.artwork.state else { throw Failure(description: "Source disable must clear artwork immediately") }
        await controller.shutdown()
        guard case .unavailable = controller.artwork.state else { throw Failure(description: "Late actual source completion republished old artwork") }
        try setMode("normal", directory)
        controller.cancelShutdown(); controller.configure(source: source); controller.setPlaying(UUID(), true)
        await controller.settled(); await controller.artwork.settled()
        guard case .ready = controller.artwork.state else { throw Failure(description: "Rejected quit must accept fresh actual artwork demand") }
        await controller.shutdown()
        print("MEDIA_ARTWORK PASS source=\(source.rawValue) raw-or-URL=actual PNG-pixels=red,blue errors=explicit metadata+transport=retained stale+shutdown+resume=verified")
    }

    static func verifyPixels(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(description: "Actual artwork PNG cannot decode") }
        var pixels = [UInt8](repeating: 0, count: 8)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(description: "Cannot inspect actual artwork pixels")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        }
        try require(pixels == [255, 0, 0, 255, 0, 0, 255, 255], "Actual artwork pixels were altered or substituted")
    }

    static func setMode(_ value: String, _ directory: URL) throws {
        try value.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }
    static func current(_ result: SystemMediaReadResult) throws -> SystemMediaSnapshot {
        guard case .current(let value) = result else { throw Failure(description: "Expected actual owned fixture snapshot, received \(result)") }
        return value
    }
}
