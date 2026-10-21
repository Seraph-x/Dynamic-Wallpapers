@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class BackendRoutingTests: XCTestCase {
    func testNativeSurfaceRejectsExtendedBackendBeforeOpeningFile() async throws {
        let surface = MediaSurface(size: CGSize(width: 64, height: 64), fit: .fit)
        let media = MediaItem(url: URL(fileURLWithPath: "/missing/routing-only.mkv"), kind: .video,
                              width: 64, height: 64, duration: 1, backend: .extended)
        do {
            try await surface.prepare(item: media, scale: 1, fit: .fit)
            XCTFail("Native surface accepted extended backend")
        } catch {
            XCTAssertEqual(error.localizedDescription, "该素材需要 extended 后端，不能交给原生播放器。")
        }
        XCTAssertFalse(surface.isPlaying)
        XCTAssertNil(surface.superview)
    }
}
