@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class DesktopPreviewFixture {
    let factory = PreviewRecordingFactory()
    let original = MediaItem(url: URL(fileURLWithPath: "/original.png"), kind: .image, width: 32, height: 32)
    let candidate = MediaItem(url: URL(fileURLWithPath: "/candidate.png"), kind: .image, width: 32, height: 32)
    let coordinator: DesktopCoordinator
    let screen: NSScreen
    var library: Library
    var commits: [(UUID, UUID)] = []
    var errors: [String] = []

    init(systemWallpaperSource: DesktopWallpaperSource? = nil, screenIDs: [String] = ["A", "B"]) throws {
        _ = NSApplication.shared
        screen = try XCTUnwrap(NSScreen.main)
        let screen = screen
        let screens = Dictionary(uniqueKeysWithValues: screenIDs.map { ($0, screen) })
        coordinator = DesktopCoordinator(surfaceFactory: factory, screenProvider: { screens },
                                         systemWallpaperSource: systemWallpaperSource)
        var library = Library.empty
        library.media = [original, candidate]
        library.displays = [DisplayBinding(id: "A", source: .media(original.id, audio: AudioSettings()))]
        library.settings.isMuted = false
        self.library = library
        coordinator.onCommit = { [weak self] in self?.commits.append(($0, $1)) }
        coordinator.onError = { [weak self] in self?.errors.append($0.localizedDescription) }
    }

    func displayOriginal() async throws {
        coordinator.reconcile(library)
        try await wait { self.commits.count == Set(self.library.displays.map(\.groupID)).count }
    }

    func makePreview(on displayID: String? = "A", onError: ((Error) -> Void)? = nil) throws -> DesktopPreviewSession {
        try coordinator.previews.makeSession(id: UUID(), item: candidate,
            target: DesktopPreviewTarget(displayID: displayID, fit: .fill),
            onError: onError ?? { [weak self] in self?.errors.append($0.localizedDescription) })
    }

    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Desktop preview fixture timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func close() {
        factory.records.forEach { $0.surface.finishPrepare(); $0.surface.finishClose() }
        coordinator.shutdown()
    }
}

@MainActor
final class PreviewRecordingFactory: SurfaceMaking {
    struct Record {
        let item: MediaItem
        let surface: ControlledSurface
        let size: CGSize
        let fit: ContentFit
    }
    var records: [Record] = []
    var configure: (ControlledSurface) -> Void = { _ in }
    func makeSurface(item: MediaItem, size: CGSize, fit: ContentFit) throws -> any PlaybackSurface {
        let surface = ControlledSurface()
        configure(surface)
        records.append(Record(item: item, surface: surface, size: size, fit: fit))
        return surface
    }
}
