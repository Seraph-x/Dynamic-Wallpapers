import AppKit
import Carbon
import WebWallpaperBridge

extension Notification.Name {
    static let cancelPendingPresentationsForQuit = Notification.Name("DynamicWallpaper.cancelPendingPresentationsForQuit")
}

/// Cancel unconfirmed sheet operations before AppKit's modal check. Resource cleanup
/// and the active-transcode confirmation still belong to applicationShouldTerminate.
@MainActor
final class ApplicationQuitPreparation: NSObject {
    private var pendingReplies: [NSAppleEventManager.SuspensionID] = []

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(prepare(_:)),
            name: .DWApplicationWillRequestTermination, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func installQuitAppleEventHandler() {
        // AppKit's default Quit AppleEvent handler checks sheets without calling
        // terminate(_:). Route external quits through the same preflight as the menu.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        if let suspension = NSAppleEventManager.shared().suspendCurrentAppleEvent() {
            pendingReplies.append(suspension)
        }
        NSApp.terminate(nil)
    }

    func complete(allowed: Bool) {
        let replies = pendingReplies
        pendingReplies.removeAll()
        let manager = NSAppleEventManager.shared()
        for suspension in replies {
            if !allowed {
                manager.replyAppleEvent(forSuspensionID: suspension).setParam(
                    NSAppleEventDescriptor(int32: Int32(userCanceledErr)), forKeyword: AEKeyword(keyErrorNumber))
            }
            manager.resume(withSuspensionID: suspension)
        }
    }

    @objc private func prepare(_ notification: Notification) {
        guard let application = notification.object as? NSApplication else { return }
        if let modal = application.modalWindow {
            if let panel = modal as? NSSavePanel { panel.cancel(nil) }
            else { application.stopModal(withCode: .cancel) }
            modal.orderOut(nil)
        }
        // Let each SwiftUI presentation clear its binding before detaching native sheets.
        NotificationCenter.default.post(name: .cancelPendingPresentationsForQuit, object: application)
        for window in application.windows where window.sheetParent == nil {
            cancelSheets(attachedTo: window)
        }
    }

    private func cancelSheets(attachedTo window: NSWindow) {
        for sheet in window.sheets {
            cancelSheets(attachedTo: sheet)
            window.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
    }
}
