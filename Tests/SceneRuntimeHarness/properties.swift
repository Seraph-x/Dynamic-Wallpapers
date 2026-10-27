import AppKit
import WallpaperCore

@MainActor
enum ScenePropertiesEvidence {
    private static let changes: [ScenePropertyOverride] = [
        .init(name: "enabled", value: .boolean(false)), .init(name: "amount", value: .number(0.75)),
        .init(name: "tint", value: .string("1 0 0")), .init(name: "caption", value: .string("")),
        .init(name: "mode", value: .string("loud")), .init(name: "é", value: .string("composed-live")),
        .init(name: "e\u{301}", value: .string("decomposed-live")),
    ]

    static func run(runtime: CEFApplicationRuntime, directory: URL) async throws {
        for representation in [SceneRepresentation.loose, .package] {
            let root = directory.appendingPathComponent(representation.rawValue)
            let project = SceneProjectReference(root: root, entry: representation == .loose ? "scene.json" : "scene.pkg",
                                                 representation: representation)
            try await exercise(project, runtime: runtime)
        }
    }

    private static func exercise(_ project: SceneProjectReference, runtime: CEFApplicationRuntime) async throws {
        var item = MediaItem(url: project.entryURL, kind: .scene, width: 640, height: 360,
                             backend: .scene, sceneProject: project)
        let metadata = try Data(contentsOf: project.root.appendingPathComponent("project.json"))
        let scene = try Data(contentsOf: project.entryURL)
        let baseline = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: runtime)
        let first = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: runtime)
        let second = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: runtime)
        var errors: [Error] = []
        for surface in [baseline, first, second] { surface.onError = { errors.append($0) } }
        do {
            try await baseline.prepare(item: item, scale: 1, fit: .fill)
            try colors(baseline, red: false)
            try await baseline.close()
            item.scenePropertyOverrides = changes
            try await first.prepare(item: item, scale: 1, fit: .fill)
            try await second.prepare(item: item, scale: 1, fit: .fill)
            // Restored values must be in the very first exposed native frame.
            try colors(first, red: true); try colors(second, red: true)
            let firstView = first.subviews.first, secondView = second.subviews.first
            first.play(); second.play()
            await first.waitForPlaybackCommand(); await second.waitForPlaybackCommand()
            second.pause(); await second.waitForPlaybackCommand()
            let capture = try SceneProjectProbe.propertyCatalog(item)
            let defaults = try capture.catalog.resolvedValues(overrides: [])
            try await runtime.sceneProperties.publish(item: item, capture: capture, values: defaults)
            try await visible(first, second, red: false)
            try await runtime.sceneProperties.publish(item: item, capture: capture, values: changes)
            try await visible(first, second, red: true)
            item.scenePropertyOverrides = []
            try await runtime.sceneProperties.publish(item: item, capture: capture, values: defaults)
            try await visible(first, second, red: false)
            try SceneSwiftHarness.require(first.state == .playing && second.state == .paused,
                "Property updates changed actual playback/paused state")
            try SceneSwiftHarness.require(first.subviews.first === firstView && second.subviews.first === secondView
                && runtime.activePageCount == 2, "Property update recreated a scene instance")
            let pending = Task { try await runtime.sceneProperties.publish(item: item, capture: capture, values: changes) }
            await Task.yield()
            try await first.close()
            // Closing cancels an in-flight native command rather than pretending
            // it completed. The other owned instance must still receive it.
            switch await pending.result {
            case .success: break
            case .failure(let error):
                let failures = (error as? WallpaperErrorGroup)?.errors ?? [error]
                try SceneSwiftHarness.require(failures.allSatisfy {
                    let native = $0 as NSError
                    return $0 is CancellationError || (native.domain == "DynamicWallpaper.Web" && native.code == 1
                        && native.localizedDescription == "Scene command cancelled because the page is closing")
                },
                    "Property close race returned an unexpected native failure: \(error)")
            }
            try await SceneSwiftHarness.waitUntil("Remaining scene missed update during close") {
                try hasColors(second, red: true)
            }
            try await second.close()
            try SceneSwiftHarness.require(runtime.activePageCount == 0 && runtime.sceneProperties.count == 0,
                "Closed property scenes retained a native owner")
            try SceneSwiftHarness.require(try Data(contentsOf: project.root.appendingPathComponent("project.json")) == metadata
                && Data(contentsOf: project.entryURL) == scene, "Property updates modified original project bytes")
        } catch { errors.append(error) }
        for surface in [baseline, first, second] {
            do { try await surface.close() } catch { errors.append(error) }
        }
        if !errors.isEmpty { throw WallpaperErrorGroup(errors) }
        print("SCENE_PROPERTIES PASS representation=\(project.representation.rawValue) restoredPixels=1 allInstances=1 pausedAndPlaying=1 resetDefaults=1 sourceUnchanged=1 closed=1")
        fflush(stdout)
    }

    private static func visible(_ first: SceneSurface, _ second: SceneSurface, red: Bool) async throws {
        try await SceneSwiftHarness.waitUntil("Actual scene property colors did not update") {
            try hasColors(first, red: red) && hasColors(second, red: red)
        }
    }

    private static func colors(_ surface: SceneSurface, red: Bool) throws {
        try SceneSwiftHarness.require(try hasColors(surface, red: red), "First exposed scene frame has incorrect restored properties")
    }

    private static func hasColors(_ surface: SceneSurface, red: Bool) throws -> Bool {
        guard let view = surface.subviews.first else { throw WallpaperError("Actual property scene has no native view") }
        let image = try SceneSwiftHarness.frame(view)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw WallpaperError("Cannot inspect actual native property pixels")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let expected = red ? [255, 0, 0] : [0, 255, 0]
        return [0.1875, 0.5].allSatisfy { x in
            let offset = (image.height / 2 * image.width + Int(Double(image.width) * x)) * 4
            return (0..<3).allSatisfy { abs(Int(pixels[offset + $0]) - expected[$0]) <= 1 }
        }
    }
}
