import AppKit
import Carbon
import SwiftUI

@MainActor
private enum Trace {
    static func record(_ message: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["STARTUP_PROBE_LOG"] else { fatalError("STARTUP_PROBE_LOG is required") }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let marker = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        let windows = NSApp.windows.map { "\($0.title):visible=\($0.isVisible)" }.joined(separator: ",")
        let line = "\(message) event=\(String(describing: event?.eventID)) marker=\(String(describing: marker)) windows=[\(windows)]\n"
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else { fatalError("Cannot create probe log") }
        }
        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch { fatalError("Probe log failed: \(error)") }
    }
}

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Trace.record("willFinish")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Trace.record("didFinish")
        if let choice = ProcessInfo.processInfo.environment["STARTUP_PROBE_POLICY"] {
            let policy: NSApplication.ActivationPolicy = choice == "accessory" ? .accessory : .regular
            guard NSApp.activationPolicy() == policy || NSApp.setActivationPolicy(policy) else {
                fatalError("Activation policy rejected")
            }
        }
        let isLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if !isLogin { NSApp.activate(ignoringOtherApps: true) }
        Trace.record("presentationApplied")
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Trace.record("reopen")
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { Trace.record("willTerminate") }
}

@main
private struct StartupProbe: App {
    @NSApplicationDelegateAdaptor(ProbeDelegate.self) private var delegate
    var body: some Scene {
        Window("Startup probe library", id: "library") {
            Text("Startup probe").frame(width: 350, height: 160).onAppear { Trace.record("libraryAppeared") }
        }
        MenuBarExtra("Startup probe", systemImage: "circle") { Text("Startup probe menu") }
        Window("Startup probe transcode", id: "transcode") { Text("Transcode").frame(width: 300, height: 150) }
        Settings { Text("Settings").frame(width: 300, height: 150) }
    }
}
