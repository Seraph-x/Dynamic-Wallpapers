import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor final class EditorInstallPromptTests: XCTestCase {
    func testNativePromptCanBeCancelled() throws {
        NSApplication.shared.finishLaunching()
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let previous = NSApplication.shared.applicationIconImage
        NSApplication.shared.applicationIconImage = try XCTUnwrap(NSImage(contentsOf:root.appendingPathComponent("Resources/AppIcon.icns")))
        defer { NSApplication.shared.applicationIconImage = previous }
        let alert = EditorInstallPrompt.makeAlert(localizer:AppLocalizer(language:.chinese))
        var cancelled = false
        let timer = Timer(timeInterval:0.25,repeats:true) { timer in
            MainActor.assumeIsolated {
                guard NSApplication.shared.modalWindow === alert.window else { return }
                cancelled = true
                timer.invalidate(); alert.buttons.last?.performClick(nil)
            }
        }
        RunLoop.main.add(timer,forMode:.modalPanel); defer { timer.invalidate() }
        XCTAssertEqual(alert.runModal(),.alertSecondButtonReturn)
        XCTAssertTrue(cancelled)
    }
    func testBrandLogoOccupiesItsOwnCenteredFirstRowInEveryLanguage() throws {
        for language in AppLanguage.allCases where language != .system {
            let alert = EditorInstallPrompt.makeAlert(localizer:AppLocalizer(language:language))
            let content = try XCTUnwrap(alert.window.contentView)
            let icon = try XCTUnwrap(content.subviews.compactMap { $0 as? NSImageView }.first)
            let title = try XCTUnwrap(content.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == alert.messageText })
            let iconFrame = content.convert(icon.bounds,from:icon), titleFrame = content.convert(title.bounds,from:title)
            XCTAssertEqual(iconFrame.midX,content.bounds.midX,accuracy:0.5)
            XCTAssertEqual(titleFrame.midX,content.bounds.midX,accuracy:0.5)
            if content.isFlipped { XCTAssertLessThanOrEqual(iconFrame.maxY,titleFrame.minY) }
            else { XCTAssertGreaterThanOrEqual(iconFrame.minY,titleFrame.maxY) }
            XCTAssertEqual(alert.icon.tiffRepresentation,AppBranding.applicationIcon.tiffRepresentation)
            let localizer = AppLocalizer(language:language)
            XCTAssertEqual(alert.buttons.map(\.title),[localizer("下载 Editor"),localizer("取消")])
            XCTAssertEqual(alert.buttons.last?.keyEquivalent,"\u{1b}")
        }
    }
}
