import XCTest
@testable import ScreenSaverRuntime

final class AudioPolicyTests: XCTestCase {
    func testOnlyExplicitPreviewAndPhysicalMainDisplayMayPlayAudio() {
        XCTAssertFalse(ScreenSaverAudioPolicy(context: .applicationPreview, isMuted: false).isSuppressed)
        XCTAssertFalse(ScreenSaverAudioPolicy(context: .systemDisplay(isMain: true), isMuted: false).isSuppressed)
        for context in [ScreenSaverAudioContext.systemPreview, .systemDisplay(isMain: false), .systemDisplay(isMain: nil)] {
            let policy = ScreenSaverAudioPolicy(context: context, isMuted: false)
            XCTAssertTrue(policy.isSuppressed)
            XCTAssertNotNil(policy.reason)
        }
        XCTAssertTrue(ScreenSaverAudioPolicy(context: .applicationPreview, isMuted: true).isSuppressed)
    }
}
