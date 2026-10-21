import AppKit
import AVFoundation
import Darwin
import ScreenSaver

private struct BookmarkRecord: Codable {
    let schemaVersion = 1
    let exportID: UUID
    let bookmark: Data
}

@main
struct ScreenSaverBundleHarness {
    @MainActor
    static func main() {
        do { try run() }
        catch { fputs("BUNDLE HARNESS FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor
    private static func run() throws {
        guard CommandLine.arguments.count == 4 else { throw failure("Expected bundle, export and mode.") }
        _ = NSApplication.shared
        let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let export = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let mode = CommandLine.arguments[3]
        let startsAtZeroSize = mode == "zero-sized-unconfigured"
        let isUnconfigured = mode == "unconfigured" || startsAtZeroSize
        guard let bundle = Bundle(url: bundleURL), let identifier = bundle.bundleIdentifier,
              let defaults = ScreenSaverDefaults(forModuleWithName: identifier) else {
            throw failure("Bundle or ScreenSaverDefaults unavailable.")
        }
        defaults.removeObject(forKey: "exportDirectoryBookmark")
        defer { defaults.removeObject(forKey: "exportDirectoryBookmark"); defaults.synchronize() }
        if !isUnconfigured {
            let identity = try JSONDecoder().decode(Identity.self,
                from: Data(contentsOf: export.appendingPathComponent("export.json")))
            let bookmark = try export.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
            let expected = mode == "wrong-identity" ? UUID() : identity.id
            defaults.set(try JSONEncoder().encode(BookmarkRecord(exportID: expected, bookmark: bookmark)),
                         forKey: "exportDirectoryBookmark")
            guard defaults.synchronize() else { throw failure("Cannot persist harness bookmark.") }
        }
        try bundle.loadAndReturnError()
        let initialFrame = startsAtZeroSize ? NSRect.zero : NSRect(x: 0, y: 0, width: 128, height: 72)
        guard let type = bundle.principalClass as? ScreenSaverView.Type,
              let view = type.init(frame: initialFrame, isPreview: true) else {
            throw failure("Principal class is not an instantiable ScreenSaverView.")
        }
        let windowFrame = startsAtZeroSize ? NSRect(x: 50, y: 50, width: 0, height: 0)
            : NSRect(x: 50, y: 50, width: 128, height: 72)
        let window = NSWindow(contentRect: windowFrame,
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
        defer { view.stopAnimation(); window.close() }
        if startsAtZeroSize {
            let requiredInsets = requiredNonzeroLayoutConstants(in: view)
            guard requiredInsets.isEmpty else {
                throw failure("Zero-sized host contains required inset constraints: \(requiredInsets)")
            }
            view.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: 128, height: 72))
            view.layoutSubtreeIfNeeded()
        }
        view.startAnimation()

        if mode == "configured" || mode == "configured-power-cycle" {
            try wait(view, state: "playing")
            guard containsActualImage(view) else { throw failure("No actual decoded image is displayed.") }
            let generation = view.value(forKey: "diagnosticGenerationID") as? String
            view.startAnimation()
            try wait(view, state: "playing")
            guard view.value(forKey: "diagnosticGenerationID") as? String == generation,
                  containsActualImage(view) else {
                throw failure("Repeated start did not preserve the active run and displayed frame.")
            }
            if mode == "configured-power-cycle" {
                let center = NSWorkspace.shared.notificationCenter
                // Notify only this harness process; the machine itself stays awake.
                for (sleep, wake) in [(NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
                                      (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification)] {
                    center.post(name: sleep, object: nil)
                    guard !containsActualImage(view) else { throw failure("Sleep did not revoke output synchronously.") }
                    try wait(view, state: "stopped")
                    try requireLeaseReleased(export)
                    center.post(name: wake, object: nil)
                    try wait(view, state: "playing")
                    guard containsActualImage(view) else { throw failure("Wake did not restore actual pixels.") }
                }
            }
            view.stopAnimation()
            try wait(view, state: "stopped")
            guard !containsActualImage(view), !(view.layer?.sublayers ?? []).contains(where: { $0 is AVPlayerLayer }) else {
                throw failure("Stopped screen saver retained native output.")
            }
            try requireLeaseReleased(export)
            if mode == "configured-power-cycle" {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                guard view.value(forKey: "diagnosticState") as? String == "stopped", !containsActualImage(view) else {
                    throw failure("Wake restarted playback after the host stopped.")
                }
            }
            print("{\"bundleLoaded\":true,\"actualPixels\":true,\"stopped\":true,\"powerCycle\":\(mode == "configured-power-cycle")}")
        } else {
            let expected = isUnconfigured ? "authorizationRequired" : "failed"
            try wait(view, state: expected)
            guard let message = view.value(forKey: "diagnosticMessage") as? String, !message.isEmpty,
                  !containsActualImage(view) else { throw failure("Failure is not explicit or rendered output survived.") }
            guard view.isAnimating else {
                throw failure("The host animation was stopped, so the static recovery message cannot remain visible.")
            }
            guard containsVisibleLabel(view, text: message) else {
                throw failure("The recovery message is not present in a visible label within the screen saver view.")
            }
            if mode == "damaged-media" && !message.contains("media/fixture.png") {
                throw failure("Damaged media was presented as a generic authorization failure: \(message)")
            }
            print("{\"bundleLoaded\":true,\"explicitFailure\":true,\"state\":\"\(expected)\"}")
        }
    }

    @MainActor
    private static func wait(_ view: ScreenSaverView, state expected: String) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            if view.value(forKey: "diagnosticState") as? String == expected { return }
        }
        throw failure("Timed out waiting for \(expected); got \(view.value(forKey: "diagnosticState") ?? "nil"): \(view.value(forKey: "diagnosticMessage") ?? "nil")")
    }

    @MainActor
    private static func containsActualImage(_ view: NSView) -> Bool {
        if let contents = view.layer?.contents,
           CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { return true }
        return view.subviews.contains(where: containsActualImage)
    }

    @MainActor
    private static func containsVisibleLabel(_ view: NSView, text: String) -> Bool {
        view.layoutSubtreeIfNeeded()
        if let label = view as? NSTextField, !label.isHidden, label.stringValue == text,
           !label.frame.isEmpty, label.window != nil { return true }
        return view.subviews.contains { containsVisibleLabel($0, text: text) }
    }

    @MainActor
    private static func requiredNonzeroLayoutConstants(in view: NSView) -> [CGFloat] {
        view.subviews.flatMap { child in
            child.constraints.compactMap { constraint -> CGFloat? in
                guard constraint.isActive, constraint.priority == .required,
                      constraint.constant != 0 else { return nil }
                return constraint.constant
            }
        }
    }

    private static func requireLeaseReleased(_ root: URL) throws {
        let generation = try JSONDecoder().decode(Current.self,
            from: Data(contentsOf: root.appendingPathComponent("current.json"))).generationID
        let handle = try FileHandle(forReadingFrom: root.appendingPathComponent("generations/\(generation.uuidString)/.lease"))
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw failure("Snapshot lease remains held.") }
    }

    private struct Identity: Codable { let id: UUID }
    private struct Current: Codable { let generationID: UUID }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ScreenSaverBundleHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
