import AppKit
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WindowGlassBackgroundTests: XCTestCase {
    func testTransparentWindowExtendsItsSavedGlassBehindTheToolbar() {
        let window = makeWindow()
        defer { window.close() }
        window.contentView = ClearWindowBackground.WindowView()

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView),
                      "The toolbar must share the content glass instead of drawing an opaque title-bar strip")
        XCTAssertTrue(window.titlebarAppearsTransparent)
    }

    func testClickReceivingWindowRetainsItsHitRegionInNativeFullScreen() async throws {
        let window = makeWindow()
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenPrimary)
        let bridge = ClearWindowBackground.WindowView()
        bridge.receivesTransparentClicks = true
        window.contentView = bridge
        defer { window.close() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        try await WallpaperMirrorTestSupport.setFullScreen(true, window: window)
        for x in [0.15, 0.5, 0.85] {
            for y in [0.15, 0.5, 0.85] {
                let point = NSPoint(x: window.frame.minX + window.frame.width * x,
                                    y: window.frame.minY + window.frame.height * y)
                XCTAssertEqual(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0),
                               window.windowNumber,
                               "Native full screen must receive clicks across transparent gaps at \(point)")
            }
        }
        try await WallpaperMirrorTestSupport.setFullScreen(false, window: window)
    }

    func testClickReceivingWindowUsesAnInvisibleBackingForTransparentPixels() {
        let window = makeWindow()
        defer { window.close() }
        let bridge = ClearWindowBackground.WindowView()
        bridge.receivesTransparentClicks = true
        window.contentView = bridge

        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 1.0 / 255, accuracy: 0.0001)
    }

    func testBridgeReappliesGlassImmediatelyBeforeFirstSheetFrame() throws {
        let window = makeWindow()
        defer { window.close() }
        let bridge = ClearWindowBackground.WindowView()
        window.contentView = bridge
        let frame = try XCTUnwrap(bridge.superview)
        let nativeSheetMaterial = NSVisualEffectView(frame: frame.bounds)
        nativeSheetMaterial.material = .sheet
        frame.addSubview(nativeSheetMaterial)
        // Reproduce AppKit's late sheet decoration after the SwiftUI content has attached.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor

        window.orderBack(nil)
        bridge.needsDisplay = true
        bridge.displayIfNeeded()

        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor.alphaComponent, 0)
        XCTAssertTrue(nativeSheetMaterial.isHidden)
    }

    func testNativeSheetMaterialIsHiddenWhenAttached() async throws {
        let state = SheetPresentationState()
        let parent = makeWindow()
        parent.contentView = NSHostingView(rootView: GlassSheetHost(state: state))
        defer { parent.close() }
        NSApplication.shared.finishLaunching()
        NSApplication.shared.activate(ignoringOtherApps: true)
        parent.makeKeyAndOrderFront(nil)
        defer { state.shown = false }
        state.shown = true
        let deadline = ContinuousClock.now + .seconds(3)
        while parent.attachedSheet == nil {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "SheetPresentation", code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
        let sheet = try XCTUnwrap(parent.attachedSheet)
        let frame = try XCTUnwrap(sheet.contentView?.superview)
        let nativeMaterial = try XCTUnwrap(frame.subviews.compactMap { $0 as? NSVisualEffectView }
            .first { $0.material == .sheet })
        XCTAssertFalse(sheet.isOpaque)
        XCTAssertEqual(sheet.backgroundColor.alphaComponent, 0)
        XCTAssertTrue(nativeMaterial.isHidden, "The native sheet material must not reach the first visible frame")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 390),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

@MainActor
private final class SheetPresentationState: ObservableObject {
    @Published var shown = false
}

private struct GlassSheetHost: View {
    @ObservedObject var state: SheetPresentationState
    var body: some View {
        Color.clear.frame(width: 400, height: 260)
            .sheet(isPresented: $state.shown) {
                Text("Importer").frame(width: 320, height: 180)
                    .appGlassPresentation(appearance: AppAppearanceSettings(transparency: 0.75))
            }
    }
}
