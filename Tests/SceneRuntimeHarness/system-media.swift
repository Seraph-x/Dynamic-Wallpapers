import AppKit
import WallpaperCore
@testable import WallpaperMediaIntegration

@MainActor
struct OwnedSystemMediaConfiguration {
    let directory: URL
    let source: SystemMediaSource
    let pid: Int32
    let authorize: Bool

    init(directory: URL) throws {
        struct Descriptor: Decodable { let source: SystemMediaSource; let pid: Int32; let authorize: Bool }
        let descriptor = try JSONDecoder().decode(Descriptor.self,
            from: Data(contentsOf: directory.appendingPathComponent("scene-fixture.json")))
        let ready = try String(contentsOf: directory.appendingPathComponent("ready"), encoding: .utf8)
        try SceneSwiftHarness.require(descriptor.source != .disabled && descriptor.pid > 0
            && Int32(ready) == descriptor.pid, "Owned media fixture identity mismatch")
        self.directory = directory; source = descriptor.source; pid = descriptor.pid; authorize = descriptor.authorize
    }

    func makeController() throws -> SystemMediaController {
        let info = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: directory.appendingPathComponent("server.json")))
        guard let ca = info["ca"] else { throw WallpaperError("Missing owned artwork TLS anchor") }
        let pid = pid, selected = source
        let service = AppleEventMediaService(eventTimeout: 1, resolveProcess: { requested in requested == selected ? pid : nil })
        let loader = HTTPSArtworkLoader(timeout: 3,
            testTrust: ArtworkTestTrust(anchorDER: try Data(contentsOf: URL(fileURLWithPath: ca)), hostname: "localhost"))
        return SystemMediaController(service: service, pollInterval: 3600, artworkLoader: loader)
    }
}

@MainActor
enum SystemMediaSceneEvidence {
    private struct Prepared {
        let surface: SceneSurface
        let page: CEFScenePageSession
        let view: NSView
    }
    private enum Marker { case empty, playing, paused, second }

    static func run(runtime: CEFApplicationRuntime, configuration: OwnedSystemMediaConfiguration,
                    projects: URL) async throws {
        for representation in [SceneRepresentation.loose, .package] {
            let project = SceneProjectReference(root: projects.appendingPathComponent(representation.rawValue),
                entry: representation == .loose ? "scene.json" : "scene.pkg", representation: representation)
            try await exercise(project, runtime: runtime, configuration: configuration)
        }
    }

    private static func prepare(_ project: SceneProjectReference, runtime: CEFApplicationRuntime) async throws -> Prepared {
        let factory = ObservedSceneFactory(runtime)
        let surface = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: factory)
        let item = MediaItem(url: project.entryURL, kind: .scene, width: 640, height: 360, backend: .scene, sceneProject: project)
        do {
            try await surface.prepare(item: item, scale: 1, fit: .fill)
            guard let page = factory.pages.first?.underlying as? CEFScenePageSession,
                  let view = surface.subviews.first else { throw WallpaperError("Missing actual native media scene") }
            return Prepared(surface: surface, page: page, view: view)
        } catch {
            do { try await surface.close() } catch { fputs("SCENE_MEDIA_SWIFT prepare cleanup failed: \(error)\n", stderr) }
            throw error
        }
    }

    private static func exercise(_ project: SceneProjectReference, runtime: CEFApplicationRuntime,
                                 configuration: OwnedSystemMediaConfiguration) async throws {
        let media = runtime.systemMedia, owner = runtime.sceneMedia
        media.configure(source: .disabled)
        let first = try await prepare(project, runtime: runtime)
        var second: Prepared?
        var failures: [Error] = []
        first.surface.onError = { failures.append($0) }
        do {
            try requirePixels(first, marker: .empty, artwork: false)
            media.configure(source: configuration.source)
            try SceneSwiftHarness.require(media.status == .waitingForPlayback && media.snapshot == nil,
                "Source selection disclosed idle metadata or started native reads")
            if configuration.authorize { await media.authorize() }
            first.surface.play(); await first.surface.waitForPlaybackCommand()
            try await settle(runtime, scenes: [first])
            try await visible(first, marker: .playing, artwork: true)
            // Prepare while another page already owns actual native metadata/PNG.
            let next = try await prepare(project, runtime: runtime)
            second = next
            let second = next
            second.surface.onError = { failures.append($0) }
            try requirePixels(second, marker: .empty, artwork: false)
            second.surface.play(); await second.surface.waitForPlaybackCommand()
            try await settle(runtime, scenes: [first, second])
            try await visible(second, marker: .playing, artwork: true)
            try await controls(first, runtime: runtime, directory: configuration.directory)
            first.surface.pause(); await first.surface.waitForPlaybackCommand()
            try requirePixels(first, marker: .empty, artwork: false)
            try SceneSwiftHarness.require(media.snapshot != nil && second.surface.state == .playing,
                "Pausing one instance removed another playing instance's provider")
            try await visible(second, marker: .playing, artwork: true)
            try await first.surface.prepareToResume()
            first.surface.play(); await first.surface.waitForPlaybackCommand()
            try await settle(runtime, scenes: [first, second])
            try await artworkFailure(first, second, runtime: runtime, directory: configuration.directory)
            try await transportFailure(first, second, runtime: runtime, directory: configuration.directory)
            media.configure(source: .disabled)
            try await owner.settled(first.page.id); try await owner.settled(second.page.id)
            try requirePixels(first, marker: .empty, artwork: false)
            try requirePixels(second, marker: .empty, artwork: false)
            try SceneSwiftHarness.require(media.snapshot == nil, "Disabled provider retained native metadata")
        } catch { failures.append(error) }
        for scene in [first, second].compactMap({ $0 }) {
            do { try await scene.surface.close() } catch { failures.append(error) }
        }
        if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
        try SceneSwiftHarness.require(runtime.activePageCount == 0 && owner.count == 0 && media.snapshot == nil,
                                      "Media scene lifetime retained a page, slot or item")
        print("SCENE_MEDIA_SWIFT PASS source=\(configuration.source.rawValue) representation=\(project.representation.rawValue) actualAppleEvents=1 actualArtwork=1 metadataPixels=1 fiveSceneControls=1 defaultOff=1 preparingPrivate=1 sharedPlaying=1 pausedClears=1 artworkFailureIndependent=1 transportFailureVisible=1 explicitRetry=1 disabledClears=1 closed=1")
        fflush(stdout)
    }

    private static func controls(_ scene: Prepared, runtime: CEFApplicationRuntime, directory: URL) async throws {
        let expected = ["Play", "Paus", "PlPs", "Next", "Prev"]
        let markers: [Marker] = [.playing, .paused, .playing, .second, .playing]
        let baseline = try receipts(directory).count
        for index in expected.indices {
            guard let identity = scene.surface.interactivePageID else { throw WallpaperError("Media scene lost actual input identity") }
            try scene.surface.sendPointer(at: CGPoint(x: (70 + Double(index) * 120) / 2, y: 150),
                kind: "click", expectedPageID: identity)
            try await SceneSwiftHarness.waitUntil("Scene control did not reach the actual owned application") {
                try receipts(directory).count == baseline + index + 1
            }
            try SceneSwiftHarness.require(try receipts(directory).last == expected[index], "Native transport event changed command")
            try await settle(runtime, scenes: [scene])
            try await visible(scene, marker: markers[index], artwork: true)
        }
        try SceneSwiftHarness.require(Array(try receipts(directory).suffix(5)) == expected,
                                      "Five actual scene controls changed native dispatch order")
    }

    private static func artworkFailure(_ first: Prepared, _ second: Prepared,
                                       runtime: CEFApplicationRuntime, directory: URL) async throws {
        try setMode("artwork-error", directory: directory)
        await runtime.systemMedia.artwork.retry()
        guard case .failed = runtime.systemMedia.artwork.state else { throw WallpaperError("Actual artwork error was hidden") }
        try SceneSwiftHarness.require(runtime.systemMedia.status == .available && runtime.systemMedia.snapshot != nil,
                                      "Artwork failure invalidated actual metadata")
        try await runtime.sceneMedia.settled(first.page.id); try await runtime.sceneMedia.settled(second.page.id)
        try await visible(first, marker: .playing, artwork: false)
        try await visible(second, marker: .playing, artwork: false)
        try setMode("normal", directory: directory)
        await runtime.sceneMedia.retryArtwork()
        try await settle(runtime, scenes: [first, second])
        try await visible(first, marker: .playing, artwork: true)
    }

    private static func transportFailure(_ first: Prepared, _ second: Prepared,
                                         runtime: CEFApplicationRuntime, directory: URL) async throws {
        try setMode("transport-error", directory: directory)
        guard let identity = first.surface.interactivePageID else { throw WallpaperError("Media scene lost actual input identity") }
        try first.surface.sendPointer(at: CGPoint(x: 35, y: 150), kind: "click", expectedPageID: identity)
        try await SceneSwiftHarness.waitUntil("Actual native transport failure did not reach Main") {
            runtime.systemMedia.status == .failed
        }
        try SceneSwiftHarness.require(runtime.systemMedia.failure != nil, "Actual transport failure lost its cause")
        try await runtime.sceneMedia.settled(first.page.id); try await runtime.sceneMedia.settled(second.page.id)
        try await visible(first, marker: .empty, artwork: false)
        try setMode("normal", directory: directory)
        await runtime.systemMedia.retry()
        try await settle(runtime, scenes: [first, second])
        try await visible(first, marker: .playing, artwork: true)
    }

    private static func settle(_ runtime: CEFApplicationRuntime, scenes: [Prepared]) async throws {
        await runtime.systemMedia.settled(); await runtime.systemMedia.artwork.settled()
        if let error = runtime.systemMedia.failure { throw error }
        for scene in scenes { try await runtime.sceneMedia.settled(scene.page.id) }
    }

    private static func receipts(_ directory: URL) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("receipts.json")))
    }

    private static func setMode(_ value: String, directory: URL) throws {
        try value.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    private static func visible(_ scene: Prepared, marker: Marker, artwork: Bool) async throws {
        try await SceneSwiftHarness.waitUntil("Actual media metadata/artwork pixels did not match \(marker)") {
            try pixels(scene, marker: marker, artwork: artwork)
        }
    }

    private static func requirePixels(_ scene: Prepared, marker: Marker, artwork: Bool) throws {
        try SceneSwiftHarness.require(try pixels(scene, marker: marker, artwork: artwork),
                                      "Acknowledged media frame disclosed unexpected metadata/artwork")
    }

    private static func pixels(_ scene: Prepared, marker: Marker, artwork: Bool) throws -> Bool {
        let image = try SceneSwiftHarness.frame(scene.view)
        guard let data = image.dataProvider?.data else { throw WallpaperError("Actual media frame has no pixel storage") }
        let bytes = data as Data
        func pixel(_ x: Double, _ y: Double) -> [Int] {
            let offset = Int(y / 360 * Double(image.height)) * image.bytesPerRow + Int(x / 640 * Double(image.width)) * 4
            return [Int(bytes[offset + 2]), Int(bytes[offset + 1]), Int(bytes[offset])]
        }
        let expected: [Int]
        switch marker {
        case .empty: expected = [255, 0, 0]
        case .playing: expected = [0, 255, 0]
        case .paused: expected = [255, 255, 0]
        case .second: expected = [0, 255, 255]
        }
        let actual = pixel(100, 50)
        guard zip(actual, expected).allSatisfy({ abs($0.0 - $0.1) < 10 }) else { return false }
        if artwork {
            let left = pixel(250, 130), right = pixel(390, 130)
            return left[0] > 220 && left[1] < 30 && left[2] < 30
                && right[2] > 220 && right[0] < 30 && right[1] < 30
        }
        return [pixel(250, 130), pixel(390, 130), pixel(250, 230)].allSatisfy { $0 == [0, 0, 0] }
    }
}
