import AppKit
import WebWallpaperBridge

@MainActor
final class QuitHarnessDelegate: NSObject, NSApplicationDelegate {
    let mode: String
    let preparation = ApplicationQuitPreparation()
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 200),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    var cancelledSheets = 0
    var shutdownFinished = false
    var termination: ApplicationTermination!

    init(mode: String) {
        self.mode = mode
        super.init()
        window.isReleasedWhenClosed = false
        termination = ApplicationTermination(shutdown: { [self] in
            require(window.attachedSheet == nil, "Shutdown started with a modal sheet")
            try await Task.sleep(for: .milliseconds(50))
            shutdownFinished = true
        }, reply: { [self] allowed in
            require(allowed && shutdownFinished, "Quit did not wait for resource cleanup")
            preparation.complete(allowed: allowed)
            NSApp.reply(toApplicationShouldTerminate: allowed)
        }, report: { error in fail("Shutdown failed: \(error)") },
        needsConfirmation: { mode == "decline" }, confirmCancellation: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                require(!self.shutdownFinished, "Declining quit started shutdown")
                print("QUIT_HARNESS PASS declined, process remains running")
                exit(0)
            }
            return false
        })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("QUIT_HARNESS didFinishLaunching")
        preparation.installQuitAppleEventHandler()
        window.makeKeyAndOrderFront(nil)
        if mode != "plain" && mode != "modal" {
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            window.beginSheet(sheet) { [self] response in
                require(response == .cancel, "Quit confirmed an unfinished operation")
                cancelledSheets += 1
            }
            if mode == "hidden" { window.orderOut(nil); sheet.orderOut(nil) }
        }
        if mode == "modal" {
            let panel = NSOpenPanel()
            let ready = Timer(timeInterval: 0.1, repeats: false) { _ in print("QUIT_HARNESS READY") }
            RunLoop.main.add(ready, forMode: .modalPanel)
            let response = panel.runModal()
            require(response == .cancel, "Quit did not cancel the native file chooser")
        } else { print("QUIT_HARNESS READY") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            fail("Quit timed out: mode=\(self.mode), attachedSheet=\(self.window.attachedSheet != nil), cleanup=\(self.shutdownFinished)")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let result = termination.request()
        if result != .terminateLater { preparation.complete(allowed: result == .terminateNow) }
        return result
    }

    func applicationWillTerminate(_ notification: Notification) {
        require(shutdownFinished, "Application exited before cleanup finished")
        require(cancelledSheets == (["plain", "modal"].contains(mode) ? 0 : 1), "Not every pending sheet was cancelled")
        print("QUIT_HARNESS PASS \(mode), sheets=\(cancelledSheets), cleanup complete")
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}
private func fail(_ message: String) -> Never {
    fputs("QUIT_HARNESS FAILED: \(message)\n", stderr)
    exit(1)
}

@main enum QuitHarness {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2,
              ["plain", "sheet", "hidden", "decline", "modal"].contains(CommandLine.arguments[1]) else {
            fail("Expected plain, sheet, hidden, decline or modal")
        }
        setbuf(stdout, nil)
        print("QUIT_HARNESS creating application")
        DWWebCreateApplication()
        NSApp.setActivationPolicy(.accessory)
        let delegate = QuitHarnessDelegate(mode: CommandLine.arguments[1])
        print("QUIT_HARNESS installing delegate")
        NSApp.delegate = delegate
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { fail("Application launch/run-loop did not complete") }
        withExtendedLifetime(delegate) { NSApp.run() }
    }
}
