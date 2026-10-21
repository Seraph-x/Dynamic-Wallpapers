import XCTest
import ScreenSaverCore
@testable import WallpaperScreenSaver

@MainActor
final class BookmarkAccessTests: XCTestCase {
    func testAuthorizeMapsInvalidExportIdentityToRecoverableError() throws {
        let suite = "local.dynamicwallpaper.screensaver.bookmark-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not JSON".utf8).write(to: root.appendingPathComponent("export.json"))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ScreenSaverBookmarkStore(defaults: defaults, resolve: { _ in
            BookmarkResolution(url: root, isStale: false)
        }, startAccess: { _ in true }, stopAccess: { _ in })

        XCTAssertThrowsError(try store.authorize(root)) { error in
            XCTAssertEqual(error as? ScreenSaverBookmarkError, .invalidExport)
        }
    }

    func testUnavailableModuleDefaultsFailExplicitly() throws {
        let store = ScreenSaverBookmarkStore(defaults: nil)

        XCTAssertThrowsError(try store.acquire()) { error in
            XCTAssertEqual(error as? ScreenSaverBookmarkError, .defaultsUnavailable)
        }
        XCTAssertThrowsError(try store.authorize(FileManager.default.temporaryDirectory)) { error in
            XCTAssertEqual(error as? ScreenSaverBookmarkError, .defaultsUnavailable)
        }
    }

    func testAuthorizeStartsSecurityScopeBeforeReadingExportIdentity() throws {
        let suite = "local.dynamicwallpaper.screensaver.bookmark-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bookmark-order-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let identity = ScreenSaverExportIdentity()
        var starts = 0
        let store = ScreenSaverBookmarkStore(defaults: defaults, resolve: { _ in
            BookmarkResolution(url: root, isStale: false)
        }, startAccess: { _ in
            starts += 1
            if starts == 1 {
                try! JSONEncoder().encode(identity).write(to: root.appendingPathComponent("export.json"))
            }
            return true
        })

        try store.authorize(root)
        let access = try store.acquire()
        XCTAssertEqual(access.expectedExportID, identity.id)
        try access.close()
        XCTAssertEqual(starts, 2)
    }

    func testStaleBookmarkIsRejectedBeforeDirectoryAccessStarts() throws {
        let suite = "local.dynamicwallpaper.screensaver.bookmark-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = ScreenSaverBookmarkRecord(exportID: UUID(), bookmark: Data("bookmark".utf8))
        defaults.set(try JSONEncoder().encode(record), forKey: ScreenSaverBookmarkStore.defaultsKey)
        var started = false
        let store = ScreenSaverBookmarkStore(defaults: defaults, resolve: { _ in
            BookmarkResolution(url: FileManager.default.temporaryDirectory, isStale: true)
        }, startAccess: { _ in started = true; return true })

        XCTAssertThrowsError(try store.acquire()) { error in
            XCTAssertEqual(error as? ScreenSaverBookmarkError, .staleBookmark)
        }
        XCTAssertFalse(started)
    }

    func testCorruptBookmarkRecordIsNotTreatedAsUnconfigured() throws {
        let suite = "local.dynamicwallpaper.screensaver.bookmark-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not JSON".utf8), forKey: ScreenSaverBookmarkStore.defaultsKey)
        let store = ScreenSaverBookmarkStore(defaults: defaults)

        XCTAssertThrowsError(try store.acquire()) { error in
            XCTAssertEqual(error as? ScreenSaverBookmarkError, .corruptBookmark)
        }
    }

    func testBookmarkErrorsMapToClosedFailureCodes() {
        let cases: [(ScreenSaverBookmarkError, ScreenSaverFailure.Code)] = [
            (.authorizationRequired, .authorizationRequired),
            (.accessDenied, .authorizationRequired),
            (.corruptBookmark, .bookmarkInvalid),
            (.staleBookmark, .bookmarkInvalid),
            (.notDirectory, .bookmarkInvalid),
            (.invalidExport, .bookmarkInvalid),
            (.identityChanged, .identityChanged),
            (.saveFailed, .settingsUnavailable),
            (.defaultsUnavailable, .settingsUnavailable),
            (.closed, .applicationClosing(.shutdown)),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(error.failure.code, expected, "\(error)")
        }
    }

    func testHostAuthorizationStateDependsOnlyOnFailureCode() {
        let misleading = ScreenSaverFailure(code: .bookmarkInvalid,
            diagnostic: FailureDiagnostic(capturing: NSError(domain: "fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "authorizationRequired"])))
        XCTAssertEqual(WallpaperScreenSaverView.diagnosticState(for: misleading), "failed")
        XCTAssertEqual(WallpaperScreenSaverView.diagnosticState(
            for: ScreenSaverFailure(code: .authorizationRequired)), "authorizationRequired")
    }
}
