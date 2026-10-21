import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SystemWallpaperInvalidationTests: XCTestCase {
    func testRapidRebindCannotReviveARevokedTargetBeforeTheNewWallpaperCommits() async throws {
        let files = try SystemWallpaperFiles()
        let replacementURL = files.root.appendingPathComponent("replacement.png")
        try Data("replacement version 1".utf8).write(to: replacementURL)
        let replacement = MediaItem(url: replacementURL, kind: .image, width: 8, height: 6)
        let source = DesktopWallpaperSource(capture: { window in
            try SystemWallpaperFiles.image(width: Int((window.frame.width * window.backingScaleFactor).rounded()),
                                           height: Int((window.frame.height * window.backingScaleFactor).rounded()))
        })
        let fixture = try DesktopPreviewFixture(systemWallpaperSource: source, screenIDs: ["A", "B", "C"])
        var writes: [URL] = []
        let sync = SystemWallpaperSync(store: files.store, capture: source.capture, isCurrent: source.isCurrent,
                                       apply: { url, displayID in
            XCTAssertEqual(displayID, "A")
            writes.append(url)
        })
        source.onChange = { [weak sync] in sync?.updateTargets($0.filter { $0.displayID == "A" }) }
        addTeardownBlock { @MainActor in
            sync.shutdown(); fixture.close()
            await sync.waitForPendingOperations()
            try await fixture.coordinator.waitForShutdown()
            try files.remove()
        }
        let group = UUID()
        let original = DisplaySource.media(files.item.id, audio: AudioSettings())
        fixture.library.media += [files.item, replacement]
        fixture.library.displays = [DisplayBinding(id: "A", source: original, groupID: group),
                                    DisplayBinding(id: "B", source: original, groupID: group),
                                    DisplayBinding(id: "C", source: original)]
        try await fixture.displayOriginal()
        let target = try XCTUnwrap(source.targets.first { $0.displayID == "A" })
        sync.setEnabled(true)
        await sync.waitForPendingOperations()
        XCTAssertEqual(writes.count, 1)
        let cWindow = try XCTUnwrap(fixture.coordinator.wallpaperWindow(on: "C"))
        let outgoing = try XCTUnwrap(fixture.factory.records.first { $0.surface.view.window === cWindow }?.surface)
        outgoing.holdClose = true
        fixture.library.displays[2].source = .media(fixture.candidate.id, audio: AudioSettings())
        fixture.coordinator.reconcile(fixture.library)
        await fulfillment(of: [outgoing.closeStarted], timeout: 2)

        fixture.library.displays.removeAll { $0.id == "A" }
        fixture.coordinator.reconcile(fixture.library)
        XCTAssertFalse(source.isCurrent(target))
        fixture.library.displays.append(DisplayBinding(id: "A", source: .media(replacement.id, audio: AudioSettings())))
        fixture.coordinator.reconcile(fixture.library)
        XCTAssertFalse(source.isCurrent(target), "Rebinding must not restore a revoked formal instance")
        XCTAssertFalse(source.targets.contains { $0.displayID == "A" }, "Only a new formal commit may republish A")
        await sync.waitForPendingOperations()
        XCTAssertEqual(writes.count, 1, "The old cached poster must not be written again while reconciliation is blocked")

        outgoing.finishClose()
        try await fixture.wait { source.targets.contains { $0.displayID == "A" && $0.content.item.id == replacement.id } }
        await sync.waitForPendingOperations()
        XCTAssertEqual(writes.count, 2, "The newly committed wallpaper must still synchronize")
        XCTAssertNotEqual(writes.first, writes.last)
        XCTAssertNotEqual(source.targets.first { $0.displayID == "A" }?.revision, target.revision)
    }

    func testPartialUnbindCancelsSystemWriteWhileAnotherGroupBlocksReconciliation() async throws {
        let files = try SystemWallpaperFiles()
        let started = expectation(description: "A capture started")
        var pending: CheckedContinuation<CGImage, Error>?
        let source = DesktopWallpaperSource(capture: { _ in
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        })
        let fixture = try DesktopPreviewFixture(systemWallpaperSource: source, screenIDs: ["A", "B", "C"])
        var writes: [String] = []
        let sync = SystemWallpaperSync(store: files.store, capture: source.capture, isCurrent: source.isCurrent,
                                       apply: { _, displayID in writes.append(displayID) })
        source.onChange = { [weak sync] in sync?.updateTargets($0.filter { $0.displayID == "A" }) }
        addTeardownBlock { @MainActor in
            pending?.resume(throwing: CancellationError()); pending = nil
            sync.shutdown(); fixture.close()
            await sync.waitForPendingOperations()
            try await fixture.coordinator.waitForShutdown()
            try files.remove()
        }
        let group = UUID()
        let original = DisplaySource.media(files.item.id, audio: AudioSettings())
        fixture.library.media.append(files.item)
        fixture.library.displays = [DisplayBinding(id: "A", source: original, groupID: group),
                                    DisplayBinding(id: "B", source: original, groupID: group),
                                    DisplayBinding(id: "C", source: original)]
        try await fixture.displayOriginal()
        let target = try XCTUnwrap(source.targets.first { $0.displayID == "A" })
        sync.setEnabled(true)
        await fulfillment(of: [started], timeout: 2)
        let cWindow = try XCTUnwrap(fixture.coordinator.wallpaperWindow(on: "C"))
        let outgoing = try XCTUnwrap(fixture.factory.records.first { $0.surface.view.window === cWindow }?.surface)
        outgoing.holdClose = true
        fixture.library.displays[2].source = .media(fixture.candidate.id, audio: AudioSettings())
        fixture.coordinator.reconcile(fixture.library)
        await fulfillment(of: [outgoing.closeStarted], timeout: 2)
        fixture.library.displays.removeAll { $0.id == "A" }
        fixture.coordinator.reconcile(fixture.library)
        XCTAssertFalse(source.isCurrent(target), "Unbinding must take effect before deferred window retirement")
        XCTAssertFalse(source.targets.contains { $0.displayID == "A" })
        let capture = try XCTUnwrap(pending); pending = nil
        capture.resume(returning: try SystemWallpaperFiles.image(width: target.content.width, height: target.content.height))
        await sync.waitForPendingOperations()
        XCTAssertTrue(writes.isEmpty, "An unbound screen must never receive a late system wallpaper write")
        outgoing.finishClose()
        try await fixture.wait { fixture.coordinator.wallpaperWindow(on: "A") == nil }
    }

    func testOldGroupCommitCannotRepublishAnAlreadyUnboundDisplay() async throws {
        let fixture = try DesktopPreviewFixture()
        addTeardownBlock { @MainActor in fixture.close(); try await fixture.coordinator.waitForShutdown() }
        let binding = fixture.library.displays[0]
        fixture.library.displays.append(DisplayBinding(id: "B", source: binding.source, groupID: binding.groupID))
        try await fixture.displayOriginal()
        let source = fixture.coordinator.systemWallpaperSource
        let aWindow = try XCTUnwrap(fixture.coordinator.wallpaperWindow(on: "A"))
        let outgoing = try XCTUnwrap(fixture.factory.records.first { $0.surface.view.window === aWindow }?.surface)
        outgoing.holdClose = true
        for index in fixture.library.displays.indices {
            fixture.library.displays[index].source = .media(fixture.candidate.id, audio: AudioSettings())
        }
        fixture.coordinator.reconcile(fixture.library)
        await fulfillment(of: [outgoing.closeStarted], timeout: 2)
        fixture.library.displays.removeAll { $0.id == "A" }
        var republished = false
        source.onChange = { targets in republished = republished || targets.contains { $0.displayID == "A" } }
        fixture.coordinator.reconcile(fixture.library)
        outgoing.finishClose()
        try await fixture.wait { fixture.commits.count >= 2 }
        XCTAssertFalse(republished, "A callback from an old synchronized group must consult the latest bindings")
        try await fixture.wait { fixture.coordinator.wallpaperWindow(on: "A") == nil }
    }
}
