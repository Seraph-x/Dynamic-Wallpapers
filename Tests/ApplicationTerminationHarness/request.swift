import AppKit
import Carbon

guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]),
      let application = NSRunningApplication(processIdentifier: pid),
      application.bundleIdentifier == "local.dynamicwallpaper.quit-harness" else {
    fatalError("Expected the PID of the isolated quit harness")
}
if CommandLine.arguments.last == "--expect-cancel" {
    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
        targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid), returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID))
    do {
        let reply = try event.sendEvent(options: [.waitForReply], timeout: 5)
        guard reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value == Int32(userCanceledErr) else {
            fatalError("Declined quit did not reply with userCanceledErr: \(reply)")
        }
    } catch let error as NSError {
        guard error.code == userCanceledErr else { fatalError("Unexpected quit reply error: \(error)") }
    }
    guard !application.isTerminated else { fatalError("Declined quit terminated the application") }
    print("QUIT_REPLY PASS userCanceledErr, application remains running")
} else {
    guard application.terminate() else { fatalError("Quit AppleEvent was rejected") }
}
