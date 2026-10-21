import AppKit
import ScreenSaver
import Darwin
import AVFoundation

@main
struct ProbeHarness {
    @MainActor
    static func main() {
        do {
            try run()
        } catch {
            fputs("HARNESS FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() throws {
        guard (2...4).contains(CommandLine.arguments.count) else { throw failure("Expected bundle and optional fixture directory.") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let bundle = Bundle(path: CommandLine.arguments[1]) else { throw failure("Bundle not found.") }
        try bundle.loadAndReturnError()
        guard let identifier = bundle.bundleIdentifier,
              let preferences = ScreenSaverDefaults(forModuleWithName: identifier) else {
            throw failure("ScreenSaverDefaults unavailable.")
        }
        defer { preferences.removeObject(forKey: "directoryBookmark"); preferences.synchronize() }
        if CommandLine.arguments.count >= 3 {
            let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let bookmark = try root.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
            preferences.set(bookmark, forKey: "directoryBookmark")
            guard preferences.synchronize() else { throw failure("Cannot persist fixture bookmark.") }
        }
        guard let type = bundle.principalClass as? ScreenSaverView.Type,
              let view = type.init(frame: NSRect(x: 0, y: 0, width: 320, height: 180), isPreview: true) else {
            throw failure("Principal class is not an instantiable ScreenSaverView.")
        }
        guard view.hasConfigureSheet, view.configureSheet != nil else {
            throw failure("Probe must provide a real configuration sheet.")
        }
        guard view.responds(to: NSSelectorFromString("diagnosticState")) else {
            throw failure("Probe diagnostics are unavailable.")
        }
        view.startAnimation()
        defer { view.stopAnimation() }
        if CommandLine.arguments.count == 4 {
            guard CommandLine.arguments[3] == "--expect-failure", try state(view) == "failed", !view.isAnimating else {
                throw failure("Failed startup must stop the host timer and expose the error.")
            }
            guard let message = view.value(forKey: "diagnosticMessage") as? String, !message.isEmpty else {
                throw failure("Failed startup must preserve a readable error.")
            }
            view.animateOneFrame()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            guard try state(view) == "failed", message == view.value(forKey: "diagnosticMessage") as? String,
                  view.layer?.contents == nil else {
                throw failure("A late callback overwrote the startup failure.")
            }
            try checkLeaseReleased(CommandLine.arguments[2])
            print("{\"failureObserved\":true,\"systemHostVerified\":false}")
            return
        }
        if CommandLine.arguments.count == 3 {
            try checkPlayback(view)
            try checkLeaseReleased(CommandLine.arguments[2])
            view.startAnimation()
            try checkPlayback(view)
            try checkLeaseReleased(CommandLine.arguments[2])
            print("{\"restartVerified\":true,\"systemHostVerified\":false}")
            return
        }
        guard view.isAnimating, try state(view) == "authorizationRequired" else {
            throw failure("An unconfigured start must explicitly require authorization.")
        }
        view.stopAnimation()
        guard !view.isAnimating, try state(view) == "stopped" else {
            throw failure("Stop must release the animation lifecycle.")
        }
        print("{\"bundleLoaded\":true,\"configurationAvailable\":true,\"systemHostVerified\":false}")
    }

    @MainActor
    private static func checkPlayback(_ view: ScreenSaverView) throws {
        guard view.responds(to: NSSelectorFromString("diagnosticFrameCounts")) else {
            throw failure("Actual decoded-frame diagnostics are unavailable.")
        }
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 320, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        let expected = ["still.png": 1, "animated.gif": 2, "animated.png": 2, "video.mov": 2]
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var counts: [String: Int] = [:]
        while ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            if try state(view) == "failed" {
                throw failure("Playback failed: \(view.value(forKey: "diagnosticMessage") ?? "missing diagnostic")")
            }
            counts = view.value(forKey: "diagnosticFrameCounts") as? [String: Int] ?? [:]
            if expected.allSatisfy({ counts[$0.key, default: 0] >= $0.value }) { break }
        }
        guard expected.allSatisfy({ counts[$0.key, default: 0] >= $0.value }) else {
            throw failure("Missing real distinct frames: \(counts)")
        }
        view.stopAnimation()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        guard try state(view) == "stopped", !view.isAnimating,
              view.value(forKey: "diagnosticFrameCounts") as? [String: Int] == counts else {
            throw failure("Stop did not quiesce playback.")
        }
        guard view.layer?.contents == nil,
              !(view.layer?.sublayers ?? []).contains(where: { $0 is AVPlayerLayer }) else {
            throw failure("Stop left image or video output attached to the view.")
        }
        let result: [String: Any] = ["realMediaPlayback": true, "distinctFrames": counts, "systemHostVerified": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

    @MainActor
    private static func state(_ view: ScreenSaverView) throws -> String? {
        guard let value = view.value(forKey: "diagnosticState") as? String else {
            throw failure("Diagnostics must expose the actual lifecycle state.")
        }
        return value
    }

    private static func checkLeaseReleased(_ directory: String) throws {
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(".lease")
        let handle = try FileHandle(forReadingFrom: url)
        let acquired = flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0
        try handle.close()
        guard acquired else { throw failure("The stopped view still holds its directory lease.") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ScreenSaverProbeHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
