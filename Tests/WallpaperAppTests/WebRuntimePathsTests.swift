import XCTest
@testable import WallpaperApp

final class WebRuntimePathsTests: XCTestCase {
    func testBundlePathsNeverUseDevelopmentDependencies() throws {
        let bundle = URL(fileURLWithPath: "/isolated/DynamicWallpaper.app")
        let paths = WebRuntimePaths.resolve(bundleURL: bundle, developmentRoot: URL(fileURLWithPath: "/source"))
        XCTAssertEqual(paths.framework.path, "/isolated/DynamicWallpaper.app/Contents/Frameworks/Chromium Embedded Framework.framework")
        XCTAssertEqual(paths.helper.path, "/isolated/DynamicWallpaper.app/Contents/Frameworks/DynamicWallpaper Helper.app/Contents/MacOS/DynamicWallpaper Helper")
        XCTAssertThrowsError(try paths.validate())
    }

    func testDevelopmentUsesDedicatedApplicationBundle() {
        let paths = WebRuntimePaths.resolve(bundleURL: URL(fileURLWithPath: "/source/.build/debug"),
                                           developmentRoot: URL(fileURLWithPath: "/source"))
        XCTAssertEqual(paths.framework.path, "/source/.build/dependencies/cef/DynamicWallpaperCEF.app/Contents/Frameworks/Chromium Embedded Framework.framework")
        XCTAssertTrue(paths.helper.path.hasSuffix("DynamicWallpaper Helper.app/Contents/MacOS/DynamicWallpaper Helper"))
    }
}
