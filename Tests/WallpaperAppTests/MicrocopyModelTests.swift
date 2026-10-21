import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class MicrocopyModelTests: XCTestCase {
    func testNativeErrorsKeepDiagnosticsAlongsideAChineseSummary() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let error = NSError(domain: "DynamicWallpaper.MPV", code: -17,
                            userInfo: [NSLocalizedDescriptionKey: "Unrecognized file format"])
        fixture.model.report(error)
        let message = try XCTUnwrap(fixture.model.errorMessage)
        XCTAssertTrue(message.contains("操作未完成"))
        XCTAssertTrue(message.contains("Unrecognized file format"))
        XCTAssertTrue(message.contains("DynamicWallpaper.MPV"))
        XCTAssertTrue(message.contains("-17"))
        try await fixture.model.shutdownAndWait()
    }

    func testUnavailableImportNamesTheActualCause() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        try await fixture.model.shutdownAndWait()
        fixture.model.importFiles()
        XCTAssertEqual(fixture.model.errorMessage, "应用正在退出，无法导入。")

        let broken = fixture.output.appendingPathComponent("broken-library.json")
        try Data("invalid json".utf8).write(to: broken)
        let model = AppModel(store: LibraryStore(url: broken))
        defer { model.shutdown() }
        model.importFiles()
        XCTAssertEqual(model.errorMessage, "素材库无法读取，暂时无法导入。")
        try await model.shutdownAndWait()
    }

    func testPartialImportReportsOnlyPersistedSuccesses() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let source = fixture.model.library.media[0].url
        let imported = fixture.output.appendingPathComponent("new.png")
        try FileManager.default.copyItem(at: source, to: imported)
        fixture.model.importURLs([imported, fixture.output.appendingPathComponent("missing.png")])
        try await waitForImport(fixture.model)
        let message = try XCTUnwrap(fixture.model.errorMessage)
        XCTAssertTrue(message.contains("已导入 1 项，1 项未能导入。"))
        XCTAssertTrue(message.contains("missing.png"))
        XCTAssertEqual(fixture.model.library.media.count, 3)
        XCTAssertEqual(try fixture.model.store.load(), fixture.model.library)
        try await fixture.model.shutdownAndWait()
    }

    func testUnreadableFileExplainsLocationPermissionsAndDiskConnection() async throws {
        do {
            _ = try await MediaProbe.inspect(URL(fileURLWithPath: "/missing-wallpaper-file.png"))
            XCTFail("A missing file must fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "无法读取“missing-wallpaper-file.png”，请检查文件位置、读取权限和磁盘连接。")
        }
    }

    func testCleanupPresentationKeepsNestedNativeDiagnostics() throws {
        let underlying = NSError(domain: "Fixture.FileHandle", code: 9,
            userInfo: [NSLocalizedDescriptionKey: "Bad file descriptor", "path": "/tmp/original-input.mp4"])
        let original = TranscodeCleanupFailure(operation: "关闭输入失败", cleanup: underlying)
        let failure = PresentedFailure(original, context: .transcode)
        XCTAssertEqual(failure.summary, "关闭输入失败")
        let diagnostics = try XCTUnwrap(failure.diagnostics)
        for text in ["Fixture.FileHandle", "9", "Bad file descriptor", "/tmp/original-input.mp4"] {
            XCTAssertTrue(diagnostics.contains(text), "Missing nested diagnostic: \(text)")
        }
    }

    func testOrdinaryPipeFailureKeepsNativeDiagnostics() throws {
        let error = NSError(domain: "Fixture.IO", code: 28,
            userInfo: [NSLocalizedDescriptionKey: "No space left on device", "path": "/tmp/ffmpeg.log"])
        do {
            try TranscodeProcess.requirePipeSuccess([error])
            XCTFail("An IO failure must fail the process")
        } catch {
            let failure = PresentedFailure(error, context: .transcode)
            XCTAssertEqual(failure.summary, "转码失败。")
            let details = try XCTUnwrap(failure.diagnostics)
            for text in ["Fixture.IO", "28", "No space left on device", "/tmp/ffmpeg.log"] {
                XCTAssertTrue(details.contains(text), "Missing pipe diagnostic: \(text)")
            }
        }
    }

    func testShutdownKeepsTheErrorSummarySeparateFromDiagnostics() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let queue = TranscodeQueue { _, _ in
            throw TranscodeCleanupFailure(operation: "关闭输入失败", cleanup:
                NSError(domain: "Fixture.FileHandle", code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "Bad file descriptor"]))
        }
        let metadata = Data("""
        {"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":32,"height":32,"avg_frame_rate":"24/1"}],"format":{"duration":"1"}}
        """.utf8)
        let plan = try TranscodePlan(media: TranscodeMedia(json: metadata), preset: .original)
        queue.enqueue(try TranscodeRequest(source: fixture.output.appendingPathComponent("input.mov"),
            destination: fixture.output.appendingPathComponent("output.mp4"), plan: plan))
        let model = AppModel(store: fixture.model.store, transcoding: TranscodeModel(queue: queue))
        let deadline = ContinuousClock.now + .seconds(3)
        while queue.hasActiveJobs {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Queue did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
        do { try await model.shutdownAndWait(); XCTFail("Cleanup failure must prevent shutdown") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Bad file descriptor")) }
        let failure = try XCTUnwrap(model.failure)
        XCTAssertEqual(failure.title, "退出未完成")
        XCTAssertEqual(failure.summary, "关闭输入失败")
        XCTAssertTrue(try XCTUnwrap(failure.diagnostics).contains("Fixture.FileHandle"))
        try await fixture.model.shutdownAndWait()
    }

    private func waitForImport(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.importing {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Import timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
