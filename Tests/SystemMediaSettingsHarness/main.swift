import AppKit
import Darwin
import CoreGraphics
import ImageIO
import SwiftUI
import WallpaperCore
@testable import WallpaperMediaIntegration
@testable import WallpaperApp

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw WallpaperError(message) }
}

private actor ObservedMediaService: SystemMediaServicing, SystemMediaArtworkServicing {
    let native: AppleEventMediaService
    private(set) var consentRequests: [Bool] = []
    init(_ native: AppleEventMediaService) { self.native = native }
    func read(source: SystemMediaSource, requestAuthorization: Bool) async throws -> SystemMediaReadResult {
        consentRequests.append(requestAuthorization)
        return try await native.read(source: source, requestAuthorization: requestAuthorization)
    }
    func perform(_ command: SystemMediaCommand, source: SystemMediaSource) async throws { try await native.perform(command, source: source) }
    func readArtwork(for identity: SystemMediaArtworkIdentity) async throws -> SystemMediaArtworkSource { try await native.readArtwork(for: identity) }
}

@MainActor
private final class SettingsSession {
    struct Descriptor: Decodable { let source: SystemMediaSource; let pid: Int32; let authorize: Bool }
    let directory: URL
    let descriptor: Descriptor
    let service: ObservedMediaService
    let controller: SystemMediaController
    let model: AppModel
    let window: NSWindow

    init(_ directory: URL) throws {
        self.directory = directory
        descriptor = try JSONDecoder().decode(Descriptor.self,
            from: Data(contentsOf: directory.appendingPathComponent("scene-fixture.json")))
        let ready = try String(contentsOf: directory.appendingPathComponent("ready"), encoding: .utf8)
        try require(descriptor.authorize && descriptor.source != .disabled && descriptor.pid > 0
            && Int32(ready) == descriptor.pid, "Explicit owned-fixture authorization and matching PID are required")
        let pid = descriptor.pid, selected = descriptor.source
        service = ObservedMediaService(AppleEventMediaService(eventTimeout: 1,
            resolveProcess: { requested in requested == selected ? pid : nil }))
        let tls = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: directory.appendingPathComponent("server.json")))
        guard let ca = tls["ca"] else { throw WallpaperError("Missing owned TLS anchor") }
        let loader = HTTPSArtworkLoader(timeout: 3,
            testTrust: ArtworkTestTrust(anchorDER: try Data(contentsOf: URL(fileURLWithPath: ca)), hostname: "localhost"))
        controller = SystemMediaController(service: service, pollInterval: 3600, artworkLoader: loader)
        let data = directory.appendingPathComponent("application-data")
        for folder in ["Home", "Temp"] {
            try FileManager.default.createDirectory(at: data.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let paths = try ApplicationPaths.resolve(arguments: ["--validation-data-root", data.path],
            bundleIdentifier: "local.dynamicwallpaper.app.validation.media-settings", configuredBundleIdentifier: "local.dynamicwallpaper.app",
            environment: ["CFFIXED_USER_HOME": data.appendingPathComponent("Home").path,
                          "TMPDIR": data.appendingPathComponent("Temp").path])
        let store = LibraryStore(url: paths.library)
        var library = Library.empty; library.settings.language = .chinese
        try store.save(library)
        model = AppModel(paths: paths, store: store, systemMedia: controller,
            setSystemDesktopImage: { _, _ in throw WallpaperError("Owned media settings must not change system wallpaper") })
        window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 800, height: 680),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Owned media settings verification"
        let model = model
        window.contentView = NSHostingView(rootView: Form { SystemMediaSettingsSection(model: model) }
            .formStyle(.grouped).appInterfacePreferences(model))
    }

    func show() async throws {
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await wait("Actual settings controls did not mount") { self.contains("关闭媒体集成") && self.window.isKeyWindow }
    }

    func press(_ title: String, role: NSAccessibility.Role) throws {
        guard let element = elements.first(where: { $0.accessibilityRole?() == role && matches($0, title) }),
              element.isAccessibilityEnabled?() == true, element.accessibilityPerformPress?() != nil else {
            throw WallpaperError("Missing or disabled actual settings control: \(title)")
        }
    }

    func contains(_ text: String) -> Bool { elements.contains { matches($0, text) } }
    var elements: [AnyObject] { descendants(window) }
    func setMode(_ value: String) throws { try value.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8) }
    func close() async throws { window.orderOut(nil); window.contentView = nil; window.close(); try await model.shutdownAndWait() }

    func wait(_ message: String, _ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !(await predicate()) {
            try require(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func descendants(_ element: AnyObject) -> [AnyObject] {
        [element] + (element.accessibilityChildren?() ?? []).flatMap { descendants($0 as AnyObject) }
    }
    private func matches(_ element: AnyObject, _ text: String) -> Bool {
        let value = element.accessibilityRole?() == .staticText ? AccessibilityTestText.read("accessibilityValue", of: element) : nil
        let title = AccessibilityTestText.read("accessibilityValue", of: element.accessibilityTitleUIElement?() as AnyObject?)
        return AccessibilityTestText.read("accessibilityLabel", of: element) == text
            || AccessibilityTestText.read("accessibilityTitle", of: element) == text || value == text || title == text
    }
}

@main
private struct SettingsMediaHarness {
    @MainActor
    static func run() async throws {
        guard CommandLine.arguments.count >= 2 else { throw WallpaperError("Expected owned fixture directory") }
        let session = try SettingsSession(URL(fileURLWithPath: CommandLine.arguments[1]))
        var failures: [Error] = []
        do {
            try await session.show()
            try await consent(session)
            try await artwork(session)
            try await providerFailures(session)
            try session.press("关闭媒体集成", role: .radioButton)
            try await session.wait("Actual Off choice did not clear native state") {
                session.controller.source == .disabled && session.controller.snapshot == nil
            }
            try require(try session.model.store.load().settings.systemMediaSource == .disabled,
                        "Actual source choice was not persisted")
        } catch { failures.append(error) }
        do { try await session.close() } catch { failures.append(error) }
        if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
        try require(session.model.webRuntime.activePageCount == 0 && session.model.webRuntime.sceneMedia.count == 0,
                    "Owned settings host retained native pages or media slots")
        print("MEDIA_SETTINGS PASS source=\(session.descriptor.source.rawValue) actualProductionView=1 threeChoices=1 selectionNoRead=1 explicitConsent=1 actualAppleEvents=1 actualArtworkPixels=1 artworkRetryIndependent=1 providerFailureVisible=1 persistedOff=1 resourcesReleased=1")
        fflush(stdout)
    }

    @MainActor
    private static func consent(_ session: SettingsSession) async throws {
        try require(session.elements.filter { $0.accessibilityRole?() == .radioButton }.count == 3, "Source selector must expose exactly three choices")
        try require(session.controller.source == .disabled, "Owned settings did not default off")
        try session.press(session.descriptor.source == .music ? "Music" : "Spotify", role: .radioButton)
        try await session.wait("Actual source choice did not persist") { session.controller.source == session.descriptor.source }
        let before = await session.service.consentRequests
        try require(before.isEmpty, "Selecting a source sent an implicit native query or prompt")
        try session.press("授权播放器", role: .button)
        try await session.wait("Actual authorization did not reach the owned native provider") { await session.service.consentRequests.count == 1 }
        await session.controller.settled()
        let requested = await session.service.consentRequests
        try require(requested == [true] && session.controller.status == .waitingForPlayback && session.controller.snapshot == nil,
                    "Explicit consent failed or disclosed idle metadata")
        try await session.wait("Idle authorization status misrepresented scene disclosure") {
            session.contains("等待场景播放，当前不向场景提供媒体信息。")
        }
        // This UI fixture drives backend demand directly; actual scene demand and
        // disclosure are independently exercised by the real CEF media harness.
        session.controller.setPlaying(UUID(), true)
        await session.controller.settled(); await session.controller.artwork.settled()
        if let error = session.controller.failure { throw error }
        try require(session.controller.snapshot?.title == "Owned 雪 \"é🎵", "Settings did not receive actual native Unicode metadata")
        try await session.wait("Actual provider availability was not rendered") { session.contains("所选播放器的媒体信息可用。") }
        try artworkPixels(session.controller.artwork.state)
    }

    @MainActor
    private static func artwork(_ session: SettingsSession) async throws {
        try session.setMode("artwork-error")
        await session.controller.artwork.retry()
        guard case .failed = session.controller.artwork.state else { throw WallpaperError("Owned native artwork fault did not surface") }
        try await session.wait("Actual artwork error was not visible") { session.contains("封面读取失败，播放信息仍可用。") }
        try require(session.controller.status == .available && session.controller.snapshot != nil, "Artwork failure invalidated native metadata")
        let before = await session.service.consentRequests.count
        try session.setMode("normal"); try session.press("重试封面", role: .button)
        try await session.wait("Actual UI artwork retry did not restore the owned image") {
            if case .ready = session.controller.artwork.state { return true }; return false
        }
        try artworkPixels(session.controller.artwork.state)
        let after = await session.service.consentRequests.count
        try require(before == after, "Artwork-only UI retry re-read playback metadata")
        try await session.wait("Recovered artwork left a stale error in the actual UI") { !session.contains("封面读取失败，播放信息仍可用。") }
    }

    @MainActor
    private static func providerFailures(_ session: SettingsSession) async throws {
        for (mode, status, text) in [
            ("missing", SystemMediaStatus.noCurrentItem, "所选播放器没有当前媒体。"),
            ("error", .failed, "媒体信息暂不可用，请查看错误并重试。"),
            ("normal", .available, "所选播放器的媒体信息可用。"),
        ] {
            try session.setMode(mode); try session.press("重试媒体信息", role: .button)
            try await session.wait("Actual native provider fault/recovery was not rendered: \(mode)") {
                session.controller.status == status && session.contains(text)
            }
            if mode == "error" { try require(session.controller.failure != nil, "Native provider failure lost its actual cause") }
        }
    }

    private static func artworkPixels(_ state: SystemMediaArtworkState) throws {
        guard case .ready(let artwork) = state, artwork.width == 2, artwork.height == 1,
              let source = CGImageSourceCreateWithData(artwork.pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WallpaperError("Missing actual normalized owned PNG") }
        var pixels = [UInt8](repeating: 0, count: 8)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw WallpaperError("Cannot inspect actual owned artwork pixels")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        }
        try require(pixels == [255, 0, 0, 255, 0, 0, 255, 255], "Owned native artwork pixels changed")
    }

    private static func record(_ status: String, error: String? = nil) throws {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--result-file"), index + 1 < arguments.count else {
            throw WallpaperError("Expected explicit result file for owned settings host")
        }
        var value: [String: Any] = ["status": status, "pid": ProcessInfo.processInfo.processIdentifier]
        if let error { value["error"] = error }
        try JSONSerialization.data(withJSONObject: value).write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
    }

    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try record("running"); try await run(); try record("passed"); Darwin.exit(0) }
            catch {
                fputs("MEDIA_SETTINGS FAILED: \(error)\n", stderr)
                do { try record("failed", error: String(describing: error)) }
                catch { fputs("MEDIA_SETTINGS result write failed: \(error)\n", stderr) }
                Darwin.exit(1)
            }
        }
        application.run()
    }
}
