import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration

final class AppleEventMediaServiceTests: XCTestCase {
    func testDisabledNeverResolvesOrSendsToAnApplication() async throws {
        let service = AppleEventMediaService(resolveProcess: { _ in
            XCTFail("Disabled source must not resolve an application"); return nil
        })
        do { _ = try await service.read(source: .disabled, requestAuthorization: true); XCTFail("Expected disabled error") }
        catch { XCTAssertEqual(error as? SystemMediaError, .disabled) }
        do { try await service.perform(.play, source: .disabled); XCTFail("Expected disabled error") }
        catch { XCTAssertEqual(error as? SystemMediaError, .disabled) }
    }

    func testMissingRunningProcessIsExplicitAndNeverLaunchesAPlayer() async throws {
        let service = AppleEventMediaService(resolveProcess: { _ in nil })
        let result = try await service.read(source: .music, requestAuthorization: false)
        XCTAssertEqual(result, .applicationNotRunning)
        do { try await service.perform(.skipNext, source: .spotify); XCTFail("Expected unavailable error") }
        catch { XCTAssertEqual(error as? SystemMediaError, .applicationNotRunning) }
    }
}
