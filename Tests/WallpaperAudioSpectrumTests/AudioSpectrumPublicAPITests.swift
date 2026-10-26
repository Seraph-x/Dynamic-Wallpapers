import Foundation
import XCTest
import WallpaperAudioSpectrum

final class AudioSpectrumPublicAPITests: XCTestCase {
    func testStereoSpectrumCanCrossTheModuleBoundary() {
        let spectrum = AudioSpectrum(left: [0.5], right: [0.25])
        XCTAssertEqual(spectrum.left, [0.5])
        XCTAssertEqual(spectrum.right, [0.25])
        XCTAssertEqual(AudioSpectrum.zero.left, Array(repeating: 0, count: 64))
        XCTAssertEqual(AudioSpectrum.zero.right, AudioSpectrum.zero.left)
    }

    @MainActor
    func testUnsupportedPublicControllerNeverCreatesCapture() async throws {
        let controller = SystemAudioSpectrumController(supported: false, makeCapture: {
            XCTFail("Unsupported systems must not create capture")
            throw NSError(domain: "AudioSpectrumPublicAPITests", code: 1)
        })
        controller.setEnabled(true)
        controller.setPlaying(UUID(), true)
        await controller.settled()
        XCTAssertFalse(controller.supported)
        XCTAssertEqual(controller.status, .unsupported)
        XCTAssertNil(controller.failure)
        try await controller.shutdown()
    }
}
