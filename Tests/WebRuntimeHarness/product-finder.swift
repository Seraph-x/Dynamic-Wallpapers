import AppKit
import ApplicationServices
import WallpaperCore

@MainActor
private final class FinderAcceptanceTrace {
    var failure: Error?
    var phase = "waiting-for-user"
    private(set) var forwardedBeforeMenu = 0
    private(set) var forwardedAfterMenu = 0
    private(set) var menuObserved = false
    private(set) var iconRejected = false
    private(set) var dragCompleted = false
    private var dragging = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    func status(_ value: String) {
        record(["status": value])
        if forwardedBeforeMenu > 0 && value.contains("菜单打开时不转发") { menuObserved = true }
        if forwardedAfterMenu > 0 && value.contains("未确认 Finder 桌面空白") { iconRejected = true }
    }
    func delivered() {
        if menuObserved { forwardedAfterMenu += 1 }
        else { forwardedBeforeMenu += 1 }
    }
    var operationsObserved: Bool {
        forwardedBeforeMenu > 0 && menuObserved && forwardedAfterMenu > 0 && iconRejected && dragCompleted
    }
    func record(_ fields: [String: Any]) {
        do {
            var record = fields
            record["host"] = ProductAcceptanceHarness.hostNow; record["phase"] = phase
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print("FINDER_TRACE " + String(decoding: data, as: UTF8.self))
        } catch { failure = error; fputs("FINDER_TRACE write failure: \(error)\n", stderr) }
    }
    func start() throws {
        let events: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                if let context {
                    MainActor.assumeIsolated {
                        Unmanaged<FinderAcceptanceTrace>.fromOpaque(context).takeUnretainedValue().receive(type, event)
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw WallpaperError("Could not create read-only Finder acceptance metadata tap")
        }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            failure = WallpaperError("Finder acceptance metadata tap disabled")
            return
        }
        let point = event.location
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        let covering = (windows ?? []).compactMap { row -> [String: Any]? in
            guard let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary), bounds.contains(point) else { return nil }
            return ["id": row[kCGWindowNumber as String] ?? "missing", "pid": row[kCGWindowOwnerPID as String] ?? "missing",
                    "layer": row[kCGWindowLayer as String] ?? "missing", "x": bounds.minX, "y": bounds.minY,
                    "width": bounds.width, "height": bounds.height]
        }
        record(["event": type.rawValue, "eventTimestamp": event.timestamp, "x": point.x, "y": point.y,
                "destinationPID": event.getIntegerValueField(.eventTargetUnixProcessID),
                "pointerWindow": event.getIntegerValueField(CGEventField(rawValue: 91)!),
                "handlingWindow": event.getIntegerValueField(CGEventField(rawValue: 92)!),
                "clickCount": event.getIntegerValueField(.mouseEventClickState),
                "coveringWindows": covering, "windowListAvailable": windows != nil])
        if iconRejected && type == .leftMouseDragged { dragging = true }
        if dragging && type == .leftMouseUp {
            dragCompleted = true
            record(["operationsObserved": operationsObserved, "automaticFinishRequested": true])
        }
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
}

extension ProductAcceptanceHarness {
    @MainActor static func runFinder(_ run: URL) async throws {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw WallpaperError("No physical display for Finder acceptance")
        }
        let screenID = number.stringValue
        let geometry = FinderScreenGeometry(quartzBounds: CGDisplayBounds(number.uint32Value), appKitFrame: screen.frame)
        let runtime = CEFApplicationRuntime()
        let window = DesktopWindow(screen: screen, surfaceFactory: SurfaceFactory(webPages: runtime))
        let project = WebProjectReference(root: run.appendingPathComponent("fixtures/click"), entry: "index.html")
        let item = try WebProjectProbe.inspect(project)
        let trace = FinderAcceptanceTrace()
        var playbackFailure: Error?, forwarded = 0, lastCount = -1
        let parent = getppid()
        window.onPlaybackError = { playbackFailure = $0 }
        func target(_ point: CGPoint) -> FinderClickTarget? {
            guard let appKit = geometry.appKitPoint(for: point), window.desktopClickPoint(atScreenPoint: appKit) != nil else { return nil }
            return window.desktopClickTarget(screenID: screenID)
        }
        let observer = FinderDesktopClickObserver(targetAtPoint: target)
        observer.onStatus = { trace.status($0.diagnosticDescription) }
        observer.onClick = { point, count, identity in
            guard target(point) == identity, let local = geometry.appKitPoint(for: point) else {
                throw WallpaperError("Finder acceptance target changed")
            }
            let delivered = try window.sendDesktopClick(atScreenPoint: local, clickCount: count, target: identity)
            if delivered { forwarded += 1; trace.delivered() }
            trace.record(["deliveryAccepted": delivered, "forwarded": forwarded, "page": identity.pageID.uuidString,
                          "x": point.x, "y": point.y, "clickCount": count])
            return delivered
        }
        do {
            try await window.prepare(item: item, fit: .fill, entry: PlaylistEntry(mediaID: item.id))
            let transition = await window.transition(duration: 0, paused: false)
            try require(transition.didDisplay, "Finder test wallpaper did not display")
            if let error = transition.error { throw error }
            guard let surface = window.contentView?.subviews.first as? WebSurface else {
                throw WallpaperError("Finder test wallpaper view missing")
            }
            try await wait("Actual Finder click fixture did not paint", failure: { playbackFailure }) { clickCount(surface) == 0 }
            try observer.start(); try trace.start()
            while !observer.isReady {
                if let failure = playbackFailure ?? trace.failure { throw failure }
                try require(getppid() == parent, "Finder acceptance controller exited")
                try await Task.sleep(for: .milliseconds(100))
            }
            trace.record(["ready": true, "pid": getpid(), "window": window.windowNumber,
                          "cursorLevel": CGWindowLevelForKey(.cursorWindow), "noEventsPosted": true,
                          "physicalDisplays": 1])
            try Data("FINDER READY actualPage=1 observerReady=1 executionTimer=running autoFinish=after-observed-sequence\n".utf8)
                .write(to: run.appendingPathComponent("READY"), options: .withoutOverwriting)
            while !trace.operationsObserved && !FileManager.default.fileExists(atPath: run.appendingPathComponent("END").path) {
                if let failure = playbackFailure ?? trace.failure { throw failure }
                try require(getppid() == parent, "Finder acceptance controller exited")
                let phaseFile = run.appendingPathComponent("PHASE")
                if FileManager.default.fileExists(atPath: phaseFile.path) {
                    trace.phase = try String(contentsOf: phaseFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let count = clickCount(surface), count != lastCount {
                    lastCount = count
                    trace.record(["actualDOMClicks": count, "forwarded": forwarded])
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            observer.stop(); trace.stop()
            try await Task.sleep(for: .milliseconds(150))
            let finalCount = clickCount(surface)
            try write(["forwarded": forwarded, "actualDOMClicks": finalCount ?? -1,
                       "beforeMenu": trace.forwardedBeforeMenu, "afterMenu": trace.forwardedAfterMenu,
                       "menuObserved": trace.menuObserved ? 1 : 0, "iconRejected": trace.iconRejected ? 1 : 0,
                       "dragCompleted": trace.dragCompleted ? 1 : 0],
                      to: run.appendingPathComponent("finder-result.json"))
            try require(trace.operationsObserved, "Finder interaction sequence is incomplete; inspect the raw trace")
            try require(finalCount == forwarded && forwarded > 0, "No confirmed Finder-to-DOM positive control, or delivery count differs")
            window.shutdown(); try await window.waitForClosing(); try await runtime.shutdown()
            print("FINDER_LIVE COMPLETE actual-DOM-clicks=\(forwarded) originalEvents=untouched physicalDisplays=one negativeCases=see-annotated-trace")
        } catch {
            observer.stop(); trace.stop(); window.shutdown()
            do { try await window.waitForClosing(); try await runtime.shutdown() }
            catch { fputs("FINDER_LIVE cleanup: \(error)\n", stderr) }
            throw error
        }
    }

    @MainActor private static func clickCount(_ surface: WebSurface) -> Int? {
        guard let value = surface.subviews.first?.layer?.contents as AnyObject?, CFGetTypeID(value) == CGImage.typeID else { return nil }
        let frame = value as! CGImage
        var count = 0
        for bit in 0..<8 {
            let x = (Double(bit) + 0.5) * Double(frame.width) / 8
            guard let crop = frame.cropping(to: CGRect(x: x, y: Double(frame.height) * 0.75, width: 1, height: 1)) else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            let known = pixel.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if bytes[0] > 230 && bytes[1] > 230 && bytes[2] > 230 { count |= 1 << bit; return true }
                return bytes[0] < 60 && (70...140).contains(bytes[1]) && (20...90).contains(bytes[2])
            }
            if !known { return nil }
        }
        return count
    }
}
