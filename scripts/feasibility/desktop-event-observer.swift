import AppKit
import ApplicationServices

// Mouse-only, listen-only feasibility probe. No event posting or event mutation.
private let durationSeconds: TimeInterval = {
    let arguments = CommandLine.arguments.dropFirst()
    guard !arguments.isEmpty else { return 60 }
    guard arguments.count == 1, let duration = Double(arguments.first!), duration.isFinite, duration > 0 else {
        fputs("Usage: desktop-event-observer [positive-duration-seconds]\n", stderr)
        exit(64)
    }
    return duration
}()
private let axMessageTimeout: Float = 0.2
private let observedTypes: [CGEventType] = [
    .leftMouseDown, .leftMouseUp, .leftMouseDragged,
    .rightMouseDown, .rightMouseUp, .rightMouseDragged
]

private struct MouseRecord {
    let sequence: Int
    let type: CGEventType
    let point: CGPoint
    let clickCount: Int64
    let eventTimeNanoseconds: UInt64
    let callbackUptimeNanoseconds: UInt64
    let callbackOrder: Int
    let lastMenuNotification: String
    let menuNotificationOrder: Int
    let windowUnderPointer: Int64
    let handlingWindow: Int64
}

private final class Cancellation {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}

private final class Observer {
    let system = AXUIElementCreateSystemWide()
    let queue = DispatchQueue(label: "local.dynamicwallpaper.feasibility.mouse-ax")
    let cancellation = Cancellation()
    var tap: CFMachPort?
    var menuObserver: AXObserver?
    var finderElement: AXUIElement?
    let menuNotifications = [kAXMenuOpenedNotification, kAXMenuClosedNotification]
    let logQueue = DispatchQueue(label: "local.dynamicwallpaper.feasibility.timeline-log")
    // All timeline state is accessed on the main run loop, shared by both sources.
    var callbackOrder = 0
    var lastMenuNotification = "unknown-at-start"
    var menuNotificationOrder = 0
    var menuNotificationCount = 0
    var counts: [UInt32: Int] = [:] // Main run-loop only.
    var scheduled = 0
    var completed = 0 // AX queue only.
    var cancelled = 0 // AX queue only.
    var stopped = false
    var failed = false
    let started = ProcessInfo.processInfo.systemUptime

    func installMenuObserver(context: UnsafeMutableRawPointer) throws {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw NSError(domain: "Finder-not-running", code: 1)
        }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        finderElement = app
        var result: AXObserver?
        let status = AXObserverCreate(finder.processIdentifier, { _, _, notification, info in
            guard let info else { return }
            Unmanaged<Observer>.fromOpaque(info).takeUnretainedValue().receiveMenu(notification as String)
        }, &result)
        guard status == .success, let result else {
            throw NSError(domain: "AXObserverCreate", code: Int(status.rawValue))
        }
        menuObserver = result
        for name in menuNotifications {
            let status = AXObserverAddNotification(result, app, name as CFString, context)
            print("MENU-REGISTER pid=\(finder.processIdentifier) notification=\(name) status=\(status.rawValue)")
            guard status == .success else {
                throw NSError(domain: "AXObserverAddNotification-\(name)", code: Int(status.rawValue))
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
    }

    func receiveMenu(_ notification: String) {
        guard !stopped else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        callbackOrder += 1
        menuNotificationOrder = callbackOrder
        menuNotificationCount += 1
        lastMenuNotification = notification
        let line = "MENU callbackOrder=\(callbackOrder) notification=\(notification) callbackUptimeNs=\(now) sourceTime=unavailable scope=Finder-only"
        logQueue.async { print(line); fflush(stdout) }
    }

    func removeMenuObserver() {
        guard let menuObserver, let finderElement else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(menuObserver), .commonModes)
        for name in menuNotifications {
            let status = AXObserverRemoveNotification(menuObserver, finderElement, name as CFString)
            print("MENU-UNREGISTER notification=\(name) status=\(status.rawValue)")
            if status != .success { failed = true }
        }
    }

    func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            failed = true
            stop(reason: "tap-disabled-type-\(type.rawValue)")
            return
        }
        guard !stopped else { return }
        scheduled += 1
        callbackOrder += 1
        counts[type.rawValue, default: 0] += 1
        let record = MouseRecord(sequence: scheduled, type: type, point: event.location,
                                 clickCount: event.getIntegerValueField(.mouseEventClickState),
                                 eventTimeNanoseconds: event.timestamp,
                                 callbackUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                 callbackOrder: callbackOrder, lastMenuNotification: lastMenuNotification,
                                 menuNotificationOrder: menuNotificationOrder,
                                 windowUnderPointer: event.getIntegerValueField(.mouseEventWindowUnderMousePointer),
                                 handlingWindow: event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent))
        let timeline = "MOUSE callbackOrder=\(record.callbackOrder) sequence=\(record.sequence) type=\(type.rawValue) eventTimeNs=\(record.eventTimeNanoseconds) callbackUptimeNs=\(record.callbackUptimeNanoseconds) lastMenuNotification=\(record.lastMenuNotification) menuNotificationOrder=\(record.menuNotificationOrder) windowUnderPointer=\(record.windowUnderPointer) handlingWindow=\(record.handlingWindow) stateMeaning=last-delivered-notification-not-atomic-menu-state eventWindowMeaning=raw-unverified"
        logQueue.async { print(timeline); fflush(stdout) }
        // No AX queries, logging I/O, or waiting for the AX queue in this callback.
        queue.async { self.inspect(record) }
    }

    func stop(reason: String) {
        guard !stopped else { return }
        stopped = true
        cancellation.stop()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        print("STOP reason=\(reason) elapsedSeconds=\(ProcessInfo.processInfo.systemUptime - started)")
        CFRunLoopStop(CFRunLoopGetMain())
    }

    func inspect(_ record: MouseRecord) {
        let eventLine = "EVENT sequence=\(record.sequence) type=\(record.type.rawValue) point=\(record.point) clickCount=\(record.clickCount) eventTimeNs=\(record.eventTimeNanoseconds) callbackUptimeNs=\(record.callbackUptimeNanoseconds)"
        guard !cancellation.isStopped else {
            print("\(eventLine)\nAX-CANCELLED sequence=\(record.sequence) reason=observer-stopped-before-query")
            cancelled += 1; return
        }
        let began = DispatchTime.now().uptimeNanoseconds
        let queueDelay = Double(began - record.callbackUptimeNanoseconds) / 1_000_000
        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(system, Float(record.point.x), Float(record.point.y), &element)
        var lines = [eventLine,
                     "AX sequence=\(record.sequence) hitStatus=\(status.rawValue) queryBeginUptimeNs=\(began) queryDelayMs=\(queueDelay) snapshot=after-event-not-event-time"]
        if status == .success, let element {
            appendAncestors(element, sequence: record.sequence, to: &lines)
        }
        let ended = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(ended - began) / 1_000_000
        lines.append("AX-END sequence=\(record.sequence) queryEndUptimeNs=\(ended) queryDurationMs=\(elapsed) cancelledDuringQuery=\(cancellation.isStopped)")
        print(lines.joined(separator: "\n"))
        completed += 1
    }

    func appendAncestors(_ element: AXUIElement, sequence: Int, to lines: inout [String]) {
        var current = element
        for depth in 0..<12 {
            guard !cancellation.isStopped else { return }
            var pid: pid_t = 0
            let pidStatus = AXUIElementGetPid(current, &pid)
            let roles = [kAXRoleAttribute, kAXSubroleAttribute].map { name -> String in
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(current, name as CFString, &value)
                return "\(name)=\(status == .success ? String(describing: value) : "error:\(status.rawValue)")"
            }
            lines.append("ANCESTOR sequence=\(sequence) depth=\(depth) pid=\(pid) pidStatus=\(pidStatus.rawValue) \(roles.joined(separator: " "))")
            var parent: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
            guard status == .success, let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                lines.append("AX-PARENT-END sequence=\(sequence) status=\(status.rawValue)")
                return
            }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        lines.append("AX sequence=\(sequence) diagnosticAncestorLimit=12")
    }
}

private let observer = Observer()
let trusted = AXIsProcessTrusted()
let listening = CGPreflightListenEventAccess()
print("permissions accessibilityTrusted=\(trusted) listenEventAccess=\(listening)")
guard trusted && listening else {
    fputs("ERROR: Existing Accessibility/Input Monitoring access unavailable.\n", stderr)
    exit(2)
}
let timeoutStatus = AXUIElementSetMessagingTimeout(observer.system, axMessageTimeout)
guard timeoutStatus == .success else {
    fputs("ERROR: Cannot set bounded AX messaging timeout: \(timeoutStatus.rawValue)\n", stderr)
    exit(3)
}
let mask = observedTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
let context = Unmanaged.passUnretained(observer).toOpaque()
do { try observer.installMenuObserver(context: context) }
catch {
    fputs("ERROR: Finder menu notifications unavailable: \(error)\n", stderr)
    exit(6)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                  options: .listenOnly, eventsOfInterest: mask,
                                  callback: { _, type, event, info in
    if let info { Unmanaged<Observer>.fromOpaque(info).takeUnretainedValue().receive(type, event) }
    return Unmanaged.passUnretained(event)
}, userInfo: context) else {
    fputs("ERROR: Unable to create listen-only mouse event tap.\n", stderr)
    exit(4)
}
observer.tap = tap
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
let timer = Timer(timeInterval: durationSeconds, repeats: false) { _ in
    observer.stop(reason: "\(durationSeconds)-second-observation-complete")
}
RunLoop.main.add(timer, forMode: .common)
CGEvent.tapEnable(tap: tap, enable: true)
print("READY listenOnly=true durationSeconds=\(durationSeconds) mouseTypes=leftDown,leftUp,leftDrag,rightDown,rightUp,rightDrag axTimeoutSeconds=\(axMessageTimeout) menuNotifications=Finder-open,Finder-close initialMenuState=unknown")
fflush(stdout)
CFRunLoopRun()
timer.invalidate()
CGEvent.tapEnable(tap: tap, enable: false)
CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
CFMachPortInvalidate(tap)
observer.removeMenuObserver()
// Pending queries observe cancellation immediately. An in-flight AX message may
// finish after the tap stops; report this drain separately from listening time.
observer.cancellation.stop()
let totals = observer.queue.sync { (observer.completed, observer.cancelled) }
observer.logQueue.sync {}
print("MENU-SUMMARY notifications=\(observer.menuNotificationCount) callbackOrder=\(observer.callbackOrder) lastNotification=\(observer.lastMenuNotification) causalOrdering=unverified-notifications-have-no-source-timestamp")
print("SUMMARY scheduled=\(observer.scheduled) axCompleted=\(totals.0) axCancelled=\(totals.1) counts=\(observer.counts) elapsedIncludingAXDrainSeconds=\(ProcessInfo.processInfo.systemUptime - observer.started)")
print("verdict=observation-only; no-CEF-forwarding; product-interaction-not-verified")
exit(observer.failed ? 5 : 0)
