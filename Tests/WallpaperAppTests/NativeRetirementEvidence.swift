@testable import WallpaperNative
import AppKit
import AVFoundation
import XCTest
@testable import WallpaperApp

/// AVPlayer properties remain diagnostic after the application releases playback.
/// Resource assertions use the queue, layer binding and surface ownership instead.
struct NativeRetirementEvidence: Codable {
    let phase: String
    let mutedDiagnostic: Bool
    let desiredRateDiagnostic: Float
    let volumeDiagnostic: Float
    let queuedItems: Int
    let hasCurrentItem: Bool
    let layerHasPlayer: Bool
    let viewIsAttached: Bool

    @MainActor
    static func verify(_ surface: MediaSurface, player: AVQueuePlayer, layer: AVPlayerLayer,
                       phase: String, file: StaticString = #filePath, line: UInt = #line) -> Self {
        let result = Self(phase: phase, mutedDiagnostic: player.isMuted,
                          desiredRateDiagnostic: player.rate, volumeDiagnostic: player.volume,
                          queuedItems: player.items().count, hasCurrentItem: player.currentItem != nil,
                          layerHasPlayer: layer.player != nil, viewIsAttached: surface.superview != nil)
        XCTAssertEqual(surface.state, .closed, file: file, line: line)
        XCTAssertFalse(surface.isPlaying, file: file, line: line)
        XCTAssertEqual(result.queuedItems, 0, "Old playback queue must be empty", file: file, line: line)
        XCTAssertFalse(result.hasCurrentItem, "Old content must be detached", file: file, line: line)
        XCTAssertFalse(result.layerHasPlayer, "Old painted layer must release its player", file: file, line: line)
        XCTAssertFalse(result.viewIsAttached, "Old view must leave the hierarchy", file: file, line: line)
        print("NATIVE_RETIREMENT phase=\(phase) mutedDiagnostic=\(result.mutedDiagnostic) desiredRateDiagnostic=\(result.desiredRateDiagnostic) queuedItems=\(result.queuedItems) hasCurrentItem=\(result.hasCurrentItem) layerHasPlayer=\(result.layerHasPlayer)")
        return result
    }
}
