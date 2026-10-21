import AppKit
import Combine
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class FullScreenWallpaperStateTests: XCTestCase {
    func testLateCaptureCannotRestoreBackgroundAfterExit() async throws {
        let state = FullScreenWallpaperState()
        let started = expectation(description: "capture started")
        var completion: CheckedContinuation<CGImage, Error>?
        state.prepare {
            try await withCheckedThrowingContinuation {
                completion = $0
                started.fulfill()
            }
        }
        state.activate()
        await fulfillment(of: [started], timeout: 1)
        state.reset()
        completion?.resume(returning: try makeImage(.red))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(state.image)
        XCTAssertNil(state.failure)
    }

    func testPreviousCaptureCannotReplaceNewFullScreenSnapshot() async throws {
        let state = FullScreenWallpaperState()
        let started = expectation(description: "old capture started")
        var completion: CheckedContinuation<CGImage, Error>?
        state.prepare {
            try await withCheckedThrowingContinuation {
                completion = $0
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let blue = try makeImage(.blue)
        state.prepare { blue }
        state.activate()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(state.image === blue)
        completion?.resume(throwing: WallpaperError("old capture failed"))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(state.image === blue)
        XCTAssertNil(state.failure)
        state.reset()
    }

    func testCaptureFailureIsExposedWithoutAReplacementImage() async throws {
        let state = FullScreenWallpaperState()
        state.prepare { throw WallpaperError("当前壁纸无法取帧") }
        state.activate()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(state.image)
        XCTAssertEqual(state.failure?.title, "全屏背景无法显示")
        XCTAssertEqual(state.failure?.summary, "当前壁纸无法取帧")
        state.reset()
    }

    func testDetachDoesNotPublishDuringSwiftUIViewDestruction() async throws {
        let state = FullScreenWallpaperState()
        let image = try makeImage(.red)
        state.prepare { image }
        state.activate()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(state.image)
        var destroyingView = true
        let subscription = state.objectWillChange.sink {
            XCTAssertFalse(destroyingView, "Publishing during dismantleNSView reenters SwiftUI's invalidating graph")
        }
        state.detach()
        destroyingView = false
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(state.image)
        withExtendedLifetime(subscription) {}
    }

    private func makeImage(_ color: NSColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try XCTUnwrap(context.makeImage())
    }
}
