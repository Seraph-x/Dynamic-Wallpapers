import AppKit
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore

extension ProductAcceptanceHarness {
    @MainActor static func runUI(_ run: URL) async throws {
        let store = LibraryStore(url: run.appendingPathComponent("library-extended.json"))
        try store.save(.empty)
        let model = AppModel(store: store)
        let product = try ProductBundleMetadata(bundle: .main)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1060, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DynamicWallpaper — 隔离功能验收"
        window.contentView = NSHostingView(rootView: LibraryView(model: model, product: product).tint(.mint))
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let parent = getppid()
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        do {
            try require(!model.loadFailed && model.library.media.isEmpty, "Isolated UI library did not start empty")
            try Data("UI READY isolatedLibrary=1 actualNativeUI=1\n".utf8)
                .write(to: run.appendingPathComponent("READY"), options: .withoutOverwriting)
            var lastState = "", lastShot = ""
            while !FileManager.default.fileExists(atPath: run.appendingPathComponent("END").path) {
                try require(getppid() == parent, "UI acceptance controller exited")
                let state = "media=\(model.library.media.count) importing=\(model.importing) sheet=\(model.showingImport) pages=\(model.webRuntime.activePageCount) error=\(model.errorMessage ?? "none")"
                if state != lastState { print("PRODUCT_UI \(state)"); lastState = state }
                let shotFile = run.appendingPathComponent("SNAPSHOT")
                if FileManager.default.fileExists(atPath: shotFile.path) {
                    let name = try String(contentsOf: shotFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    try require(!name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") },
                                "Snapshot name must be a simple filename")
                    if name != lastShot {
                        try await snapshot(window, to: run.appendingPathComponent(name + ".png"))
                        print("PRODUCT_UI snapshot=\(name)"); lastShot = name
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(model.library.media.contains { $0.kind != .web }, "Actual file-picker media import not completed")
            try require(model.library.media.contains { $0.webProject?.entry == "pages/alternate.html" },
                        "Actual project-picker and explicit HTML entry import not completed")
            let saved = try store.load()
            try require(saved == model.library, "UI imports were not durably saved")
            try require(model.errorMessage == nil, "UI has an unresolved error")
            try await model.shutdownAndWait()
            try write(model.library, to: run.appendingPathComponent("ui-result-library.json"))
            print("PRODUCT_UI COMPLETE actual-imported-media=\(model.library.media.count) persisted=1 shutdown=1 interactionEvidence=external-AX-trace")
        } catch {
            do { try await model.shutdownAndWait() } catch { fputs("PRODUCT_UI cleanup: \(error)\n", stderr) }
            throw error
        }
    }

    @MainActor private static func snapshot(_ window: NSWindow, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw WallpaperError("Actual acceptance UI window is not available for screenshot")
        }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2); config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target),
                                                              configuration: config)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WallpaperError("Could not create UI screenshot destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "Could not write actual UI screenshot")
    }
}
