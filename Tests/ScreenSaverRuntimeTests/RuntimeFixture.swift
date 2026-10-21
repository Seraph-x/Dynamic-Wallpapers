import AppKit
import CryptoKit
import ImageIO
import XCTest
import ScreenSaverCore
import WallpaperCore
import WallpaperNative
@testable import ScreenSaverRuntime

@MainActor
final class RuntimeFixture {
    let root: URL
    let store: ScreenSaverSnapshotStore
    let window: NSWindow
    let view: NSView
    var sessions: [ScreenSaverSession] = []
    var accesses: [RuntimeAccess] = []

    init(test: XCTestCase) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("screensaver-runtime-\(UUID())")
        store = try ScreenSaverSnapshotStore(root: root)
        _ = try await store.initialize()
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 96, height: 64),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 64))
        window.contentView = view
        window.orderBack(nil)
        test.addTeardownBlock { @MainActor [self] in
            var errors: [Error] = []
            for session in sessions {
                if case .failure(let error) = await session.stop().result { errors.append(error) }
            }
            window.close()
            do { try FileManager.default.removeItem(at: root) } catch { errors.append(error) }
            if !errors.isEmpty { throw WallpaperErrorGroup(errors) }
        }
    }

    @discardableResult
    func publish(count: Int = 1, mode: PlaybackMode = .ordered, seconds: Double = 0.08,
                 transition: Double = 0, type: String = "public.png", frames: Int = 1,
                 timing: EntryTiming? = nil) async throws -> ScreenSaverManifest {
        let bytes = try Self.image(type: type, frames: frames)
        let item = MediaItem(url: root.appendingPathComponent("unused-source.png"),
            kind: frames > 1 ? .animatedImage : .image, width: 16, height: 16,
            duration: frames > 1 ? 0.2 * Double(frames) : nil)
        var library = Library(); library.media = [item]
        let playlist = Playlist(name: "Runtime", entries: (0..<count).map { _ in
            PlaylistEntry(mediaID: item.id, timing: timing ?? EntryTiming(seconds: seconds))
        }, mode: mode, transition: transition)
        library.playlists = [playlist]
        let projection = try ScreenSaverProjection(library: library, source: .playlist(playlist.id))
        let settings = ScreenSaverSettings(source: projection.source, isMuted: false)
        let stage = try await store.beginPublication()
        let file = try ScreenSaverMediaFile(media: item, relativePath: "media/fixture." + (type == "com.compuserve.gif" ? "gif" : "png"),
            byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try bytes.write(to: stage.directory.appendingPathComponent(file.relativePath))
        let manifest = try ScreenSaverManifest(generationID: stage.id, projection: projection, settings: settings, files: [file])
        _ = try await store.commit(stage, manifest: manifest, settingsRevision: UUID())
        return manifest
    }

    func makeSession(context: ScreenSaverAudioContext = .applicationPreview,
                     factory: @escaping ScreenSaverRenderer.SurfaceFactory = { MediaSurface(size: $0, fit: $1) }) -> ScreenSaverSession {
        let session = ScreenSaverSession(view: view, audioContext: context, access: { [self] in
            let access = RuntimeAccess(root: root); accesses.append(access); return access
        }, makeSurface: factory)
        sessions.append(session)
        return session
    }

    func publishVideo(_ url: URL) async throws {
        let item = try await NativeMediaProbe.inspect(url)
        let bytes = try Data(contentsOf: url)
        var library = Library(); library.media = [item]
        let projection = try ScreenSaverProjection(library: library, source: .media(item.id))
        let settings = ScreenSaverSettings(source: projection.source, isMuted: false)
        let stage = try await store.beginPublication()
        let file = try ScreenSaverMediaFile(media: item, relativePath: "media/video.mov", byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try bytes.write(to: stage.directory.appendingPathComponent(file.relativePath))
        let manifest = try ScreenSaverManifest(generationID: stage.id, projection: projection, settings: settings, files: [file])
        _ = try await store.commit(stage, manifest: manifest, settingsRevision: UUID())
    }

    static func image(type: String, frames: Int) throws -> Data {
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, type as CFString, frames, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for index in 0..<frames {
            context.setFillColor(index == 0 ? NSColor.red.cgColor : NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            let properties: [CFString: Any] = type == "com.compuserve.gif"
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.2]]
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw WallpaperError("Fixture image encoding failed") }
        return bytes as Data
    }
}

@MainActor
final class RuntimeAccess: ScreenSaverDirectoryAccess {
    let root: URL
    let expectedExportID: UUID? = nil
    var closed = false
    init(root: URL) { self.root = root }
    func close() throws { closed = true }
}

@MainActor
func eventually(_ predicate: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while try !predicate() {
        guard ContinuousClock.now < deadline else { throw WallpaperError("Runtime condition timed out") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
final class RuntimeGate {
    var arrived = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        arrived = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

/// Fault/delay injection wraps real native decoding; no simulated frame readiness.
@MainActor
final class GatedNativeSurface: PlaybackSurface {
    let native: MediaSurface
    let prepareGate: RuntimeGate?
    let closeGate: RuntimeGate?
    var failClose = false
    private(set) var closeCalls = 0
    var view: NSView { native.view }
    var state: PlaybackSurfaceState { native.state }
    var onError: ((Error) -> Void)? { get { native.onError } set { native.onError = newValue } }
    init(size: CGSize, fit: ContentFit, prepare: RuntimeGate? = nil, close: RuntimeGate? = nil) {
        native = MediaSurface(size: size, fit: fit); prepareGate = prepare; closeGate = close
    }
    func prepare(item: MediaItem, scale: CGFloat, fit: ContentFit) async throws {
        try await native.prepare(item: item, scale: scale, fit: fit)
        await prepareGate?.wait()
    }
    func play() { native.play() }
    func pause() { native.pause() }
    func prepareToResume() async throws { try await native.prepareToResume() }
    func cancelResumePreparation() async throws { try await native.cancelResumePreparation() }
    func setAudio(_ value: AudioSettings) { native.setAudio(value) }
    func setTransitionGain(_ value: Double) { native.setTransitionGain(value) }
    func setGlobalMute(_ value: Bool) { native.setGlobalMute(value) }
    func setAudioSuppressed(_ value: Bool) { native.setAudioSuppressed(value) }
    func close() async throws {
        closeCalls += 1
        await closeGate?.wait()
        if failClose { throw WallpaperError("injected native close failure") }
        try await native.close()
    }
}
