import XCTest
@testable import WallpaperApp

final class TranscodeToolsTests: XCTestCase {
    func testBundledAppNeverFallsBackToDevelopmentTools() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        XCTAssertThrowsError(try TranscodeTools.resolve(bundleURL: directory.appendingPathComponent("Missing.app"),
                                                       developmentRoot: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("MediaTools"))
        }
    }

    @MainActor
    func testDevelopmentUsesExplicitPinnedDirectory() throws {
        let tools = try TranscodeTools.resolve(bundleURL: TranscodeTestFixtures.root.appendingPathComponent(".build/debug"),
                                               developmentRoot: TranscodeTestFixtures.root)
        XCTAssertEqual(tools.directory, TranscodeTestFixtures.tools.directory)
    }
}
