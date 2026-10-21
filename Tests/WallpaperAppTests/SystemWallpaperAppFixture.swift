import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SystemWallpaperAppFixture {
    let files: SystemWallpaperFiles
    let store: LibraryStore
    let screen: NSScreen
    let screenID: String
    let setter: SystemWallpaperSetterRecorder
    let model: AppModel

    init(enabled: Bool = false, bound: Bool = false, fit: ContentFit = .fill, item: MediaItem? = nil) throws {
        _ = NSApplication.shared
        screen = try XCTUnwrap(NSScreen.main)
        screenID = try XCTUnwrap(screen.wallpaperID)
        files = try SystemWallpaperFiles()
        let bitmap = NSBitmapImageRep(cgImage: try SystemWallpaperFiles.image())
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: files.item.url)
        store = LibraryStore(url: files.root.appendingPathComponent("library.json"))
        var library = Library.empty
        let item = item ?? files.item
        library.media = [item]
        library.settings.systemWallpaperSyncEnabled = enabled
        if bound {
            library.displays = [DisplayBinding(id: screenID, source: .media(item.id, audio: AudioSettings()), fit: fit)]
        }
        try store.save(library)
        setter = SystemWallpaperSetterRecorder(store: store)
        model = AppModel(store: store, setSystemDesktopImage: setter.apply)
    }

    func wait(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while try !condition() {
            if let failure = model.failure { throw failure }
            guard ContinuousClock.now < deadline else {
                throw WallpaperError("System wallpaper fixture timed out", diagnostic: String(describing: model.systemWallpaperSync.states))
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func syncedImage(after attempts: Int = 1) async throws -> URL {
        try await wait {
            if case .failed(let failure) = model.systemWallpaperSync.states[screenID] { throw failure }
            guard case .synced = model.systemWallpaperSync.states[screenID] else { return false }
            return setter.attempts.count == attempts
        }
        guard case .synced(let url) = model.systemWallpaperSync.states[screenID] else {
            throw WallpaperError("System wallpaper has no synchronized image")
        }
        return url
    }

    func close() async throws {
        try await model.shutdownAndWait()
        try files.remove()
    }
}

@MainActor
final class SystemWallpaperSetterRecorder {
    struct Attempt {
        let url: URL
        let displayID: String
        let savedEnabled: Bool
    }
    let store: LibraryStore
    var failure: Error?
    private(set) var attempts: [Attempt] = []

    init(store: LibraryStore) { self.store = store }

    func apply(_ url: URL, _ displayID: String) throws {
        // Inspect the real persisted PNG, but never write the user's macOS wallpaper.
        XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: url)))
        attempts.append(Attempt(url: url, displayID: displayID,
                                savedEnabled: try store.load().settings.systemWallpaperSyncEnabled))
        if let failure { throw failure }
    }
}
