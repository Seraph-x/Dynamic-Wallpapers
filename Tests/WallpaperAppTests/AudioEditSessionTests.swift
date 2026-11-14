import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class AudioEditSessionTests: XCTestCase {
    func testDragAppliesEverySampleAndCommitsOnlyLastValue() throws {
        var applied: [AudioSettings] = [], saved: [AudioSettings] = []
        let editor = AudioEditSession(apply: { _, audio in applied.append(audio) },
                                      commit: { _, audio in saved.append(audio) })
        let target = makeTarget()
        for tick in 1...100 { try editor.update(AudioSettings(volume: Double(tick) / 100), target: target) }
        XCTAssertEqual(applied.count, 100)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(editor.value(for: target, persisted: AudioSettings()).volume, 1)
        try editor.finish()
        try editor.finish()
        XCTAssertEqual(saved, [AudioSettings(volume: 1)])
    }

    func testSwitchingTargetCommitsPreviousEdit() throws {
        var saved: [AudioEditTarget] = []
        let editor = AudioEditSession(apply: { _, _ in }, commit: { target, _ in saved.append(target) })
        let first = makeTarget(), second = makeTarget()
        try editor.update(AudioSettings(volume: 0.2), target: first)
        try editor.update(AudioSettings(volume: 0.4), target: second)
        XCTAssertEqual(saved, [first])
        try editor.finish()
        XCTAssertEqual(saved, [first, second])
    }

    func testSaveFailureRetainsDraftAndCanBeRetried() throws {
        var fail = true, writes = 0
        let editor = AudioEditSession(apply: { _, _ in }, commit: { _, _ in
            if fail { throw WallpaperError("disk failure") }
            writes += 1
        })
        let target = makeTarget()
        try editor.update(AudioSettings(volume: 0.3), target: target)
        XCTAssertThrowsError(try editor.finish())
        XCTAssertEqual(editor.value(for: target, persisted: AudioSettings()).volume, 0.3)
        fail = false
        try editor.finish()
        XCTAssertEqual(writes, 1)
    }

    func testInvalidAudioNeverReachesPlayer() throws {
        var applied = false
        let editor = AudioEditSession(apply: { _, _ in applied = true }, commit: { _, _ in })
        XCTAssertThrowsError(try editor.update(AudioSettings(volume: 2), target: makeTarget()))
        XCTAssertFalse(applied)
    }

    func testDirectTargetCannotWriteIntoReplacementWallpaper() throws {
        var library = Library.empty
        let original = UUID(), replacement = UUID(), group = UUID()
        library.displays = [DisplayBinding(id: "display", source: .media(replacement, audio: AudioSettings()), groupID: group)]
        let target = AudioEditTarget(id: .direct(groupID: group), mediaID: original)
        XCTAssertThrowsError(try target.write(AudioSettings(volume: 0.4), to: &library))
        guard case .media(let id, let audio) = library.displays[0].source else { return XCTFail() }
        XCTAssertEqual(id, replacement)
        XCTAssertEqual(audio, AudioSettings())
    }

    func testAppModelLeavesDiskUntouchedDuringDragAndFlushesOnShutdown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        var library = Library.empty
        let item = MediaItem(url: directory.appendingPathComponent("sound.mov"), kind: .video, width: 32, height: 32)
        let entry = PlaylistEntry(mediaID: item.id)
        library.media = [item]; library.playlists[0].entries = [entry]
        try store.save(library)
        let original = try Data(contentsOf: store.url)
        let model = AppModel(store: store)
        let target = AudioEditTarget(id: .playlist(playlistID: library.playlists[0].id, entryID: entry.id), mediaID: item.id)
        for tick in 1...100 {
            XCTAssertTrue(model.editAudio(AudioSettings(volume: Double(tick) / 200), target: target))
        }
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        XCTAssertEqual(model.library, library)
        try await model.shutdownAndWait()
        XCTAssertEqual(try store.load().playlists[0].entries[0].audio.volume, 0.5)
    }

    func testFailedAudioSavePreventsShutdownAndRetainsValueForRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        var library = Library.empty
        let item = MediaItem(url: directory.appendingPathComponent("sound.mov"), kind: .video, width: 32, height: 32)
        let entry = PlaylistEntry(mediaID: item.id)
        library.media = [item]; library.playlists[0].entries = [entry]
        try store.save(library)
        let model = AppModel(store: store)
        let target = AudioEditTarget(id: .playlist(playlistID: library.playlists[0].id, entryID: entry.id), mediaID: item.id)
        XCTAssertTrue(model.editAudio(AudioSettings(volume: 0.25), target: target))
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        do { try await model.shutdownAndWait(); XCTFail("Failed save allowed termination") }
        catch { XCTAssertNotNil(model.failure) }
        XCTAssertFalse(model.isShuttingDown)
        XCTAssertEqual(model.audioEdits.value(for: target, persisted: entry.audio).volume, 0.25)
        try FileManager.default.removeItem(at: store.url)
        try await model.shutdownAndWait()
        XCTAssertEqual(try store.load().playlists[0].entries[0].audio.volume, 0.25)
    }

    func testPanelCloseCallbackDoesNotReenterWhenFailurePresentationChangesFocus() {
        let panel = AudioPanelWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        var saves = 0
        panel.onClose = { saves += 1; panel.resignKey(); panel.close() }
        panel.close()
        panel.close()
        XCTAssertEqual(saves, 1)
    }

    private func makeTarget() -> AudioEditTarget {
        AudioEditTarget(id: .playlist(playlistID: UUID(), entryID: UUID()), mediaID: UUID())
    }
}
