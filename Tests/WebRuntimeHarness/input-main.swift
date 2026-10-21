import AppKit
import WallpaperCore
import WebWallpaperBridge
import Darwin

@main
struct WebInputHarness {
    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw WallpaperError("Expected isolated click project") }
        let project = WebProjectReference(root: URL(fileURLWithPath: CommandLine.arguments[1]), entry: "index.html")
        let runtime = CEFApplicationRuntime()
        let surface = WebSurface(size: CGSize(width: 320, height: 180), fit: .fit, pageFactory: runtime)
        let window = NSWindow(contentRect: surface.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DynamicWallpaper isolated webpage click test"
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        var failure: Error?
        surface.onError = { failure = $0 }
        do {
            let item = MediaItem(url: project.entryURL, kind: .web, width: 320, height: 180,
                                 backend: .web, webProject: project)
            try await surface.prepare(item: item, scale: 1, fit: .fit)
            surface.play()
            try await waitForColor(surface, blue: false, failure: { failure })
            print("WEB_INPUT READY actualPage=1")
            let point = surface.convert(NSPoint(x: 160, y: 90), to: nil)
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: index + 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                    throw WallpaperError("Could not create the AppKit click event")
                }
                window.sendEvent(event)
            }
            try await waitForColor(surface, blue: true, failure: { failure })
            try await surface.close()
            try await runtime.shutdown()
            if let failure { throw failure }
            print("WEB_INPUT PASS AppKit-dispatch=1 actual-DOM-click=1 close=1 shutdown=1 hardwareInput=unverified")
        } catch {
            do { try await surface.close(); try await runtime.shutdown() }
            catch { fputs("WEB_INPUT cleanup failure: \(error)\n", stderr) }
            throw error
        }
    }

    @MainActor static func waitForColor(_ surface: WebSurface, blue: Bool, failure: () -> Error?) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            if let failure = failure() { throw failure }
            if let contents = surface.subviews.first?.layer?.contents as AnyObject?, CFGetTypeID(contents) == CGImage.typeID {
                let frame = contents as! CGImage
                var pixel = [UInt8](repeating: 0, count: 4)
                let matches = pixel.withUnsafeMutableBytes { bytes -> Bool in
                    guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    return bytes[0] < 20 && (blue ? bytes[2] > 220 && bytes[1] < 20 : bytes[1] > 220 && bytes[2] < 20)
                }
                if matches { return }
            }
            guard ContinuousClock.now < deadline else {
                throw WallpaperError(blue ? "AppKit click never reached the actual webpage DOM" : "Actual webpage did not paint its ready frame")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor static func main() {
        DWWebCreateApplication(); NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                if !(try await HarnessAuthorization.runIfRequested()) { try await run() }
                Darwin.exit(0)
            }
            catch { fputs("WEB_INPUT FAILED \(error)\n", stderr); Darwin.exit(1) }
        }
        NSApp.run()
    }
}
