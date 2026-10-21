import XCTest
import CoreGraphics
@testable import WallpaperApp

final class FinderDesktopGeometryTests: XCTestCase {
    func testConvertsQuartzTopLeftIntoAppKitBottomLeftOnMainDisplay() {
        let geometry = FinderScreenGeometry(quartzBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(geometry.appKitPoint(for: CGPoint(x: 300, y: 200)), CGPoint(x: 300, y: 700))
    }

    func testSecondaryDisplayAboveAndLeftPreservesItsOwnOriginAndScale() {
        let geometry = FinderScreenGeometry(quartzBounds: CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
            appKitFrame: CGRect(x: -960, y: 900, width: 960, height: 540))
        XCTAssertEqual(geometry.appKitPoint(for: CGPoint(x: -1440, y: -810)), CGPoint(x: -720, y: 1305))
    }

    func testOutOfDisplayBoundaryAndInvalidGeometryRemainUnclassified() {
        let geometry = FinderScreenGeometry(quartzBounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 50))
        for point in [CGPoint(x: 100, y: 20), CGPoint(x: 20, y: 50), CGPoint(x: -1, y: 20),
                      CGPoint(x: CGFloat.nan, y: 20), CGPoint(x: 20, y: CGFloat.infinity)] {
            XCTAssertNil(geometry.appKitPoint(for: point))
        }
        let empty = FinderScreenGeometry(quartzBounds: .zero, appKitFrame: geometry.appKitFrame)
        XCTAssertNil(empty.appKitPoint(for: .zero))
    }
}
