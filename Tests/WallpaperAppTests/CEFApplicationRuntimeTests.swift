import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class CEFApplicationRuntimeTests: XCTestCase {
    func testLazyPagesAreOwnedUntilClosedAndShutdownPreventsCreation() async throws {
        let runtime = CEFApplicationRuntime(paths: .resolve(bundleURL: URL(fileURLWithPath: "/missing.app")))
        let page = try runtime.makePage(size: CGSize(width: 32, height: 18))
        XCTAssertEqual(runtime.activePageCount, 1)
        try await page.close()
        XCTAssertEqual(runtime.activePageCount, 0)
        try await runtime.shutdown()
        XCTAssertThrowsError(try runtime.makePage(size: CGSize(width: 32, height: 18)))
        try await runtime.shutdown()
    }

    func testDependencyFailureIsExplicitAndPageRetainsOwnershipUntilClose() async throws {
        let runtime = CEFApplicationRuntime(paths: .resolve(bundleURL: URL(fileURLWithPath: "/missing.app")))
        let page = try runtime.makePage(size: CGSize(width: 32, height: 18))
        let project = WebProjectReference(root: URL(fileURLWithPath: "/missing-project"), entry: "index.html")
        do {
            try await page.prepare(project: project, scale: 1)
            XCTFail("Missing bundled framework must not initialize or use a fallback")
        } catch {
            let failure = try XCTUnwrap(error as? WallpaperError)
            XCTAssertEqual(failure.message, "网页播放组件不可用。")
            XCTAssertTrue(try XCTUnwrap(failure.diagnostic).contains("/missing.app/"))
        }
        XCTAssertEqual(runtime.activePageCount, 1)
        try await runtime.shutdown()
        XCTAssertEqual(runtime.activePageCount, 0)
    }

    func testWebFrameRateChoiceAppliesToExistingAndFutureSessions() async throws {
        let runtime = CEFApplicationRuntime(paths: .resolve(bundleURL: URL(fileURLWithPath: "/missing.app")))
        let first = try runtime.makePage(size: CGSize(width: 32, height: 18))
        XCTAssertEqual(runtime.frameRate, .fps30)
        XCTAssertEqual(try XCTUnwrap(first as? CEFPageSession).frameRate, .fps30)

        runtime.setFrameRate(.fps24)
        XCTAssertEqual(runtime.frameRate, .fps24)
        XCTAssertEqual(try XCTUnwrap(first as? CEFPageSession).frameRate, .fps24)
        let second = try runtime.makePage(size: CGSize(width: 32, height: 18))
        XCTAssertEqual(try XCTUnwrap(second as? CEFPageSession).frameRate, .fps24)

        runtime.setFrameRate(.fps60)
        XCTAssertEqual(try XCTUnwrap(first as? CEFPageSession).frameRate, .fps60)
        XCTAssertEqual(try XCTUnwrap(second as? CEFPageSession).frameRate, .fps60)
        try await first.close()
        try await second.close()
        try await runtime.shutdown()
    }
}
