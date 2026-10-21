import AppKit
import ApplicationServices

// Read-only window/AX polling. No input observation, injection, window changes or titles.
private let duration: TimeInterval = 60
private let interval: TimeInterval = 0.1
private struct WindowRecord: Equatable {
    let id: UInt32
    let pid: Int
    let owner: String
    let layer: Int
    let rect: CGRect
    var description: String { "windowID=\(id) ownerPID=\(pid) owner=\(owner) layer=\(layer) bounds=\(rect)" }
}
private final class StopFlag {
    private let lock = NSLock()
    private var value = false
    func stop() { lock.lock(); value = true; lock.unlock() }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
private final class Watch {
    let system = AXUIElementCreateSystemWide()
    let queue = DispatchQueue(label: "local.dynamicwallpaper.feasibility.window-ax")
    let flag = StopFlag()
    let started = ProcessInfo.processInfo.systemUptime
    var previous: [UInt32: WindowRecord] = [:] // Main run-loop only.
    var polls = 0, additions = 0, changes = 0, removals = 0
    var queries = 0, cancelled = 0 // AX queue only.
    var failure = false

    func poll() {
        let observed = ProcessInfo.processInfo.systemUptime
        guard let raw = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            print("ERROR window-list-unavailable"); failure = true; stop(); return
        }
        var current: [UInt32: WindowRecord] = [:]
        for item in raw {
            guard let id = item[kCGWindowNumber as String] as? UInt32,
                  let pid = item[kCGWindowOwnerPID as String] as? Int,
                  let layer = item[kCGWindowLayer as String] as? Int,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                print("ERROR malformed-window-record"); failure = true; stop(); return
            }
            // Window owner is an application/process label; kCGWindowName is never read.
            let owner = item[kCGWindowOwnerName as String] as? String ?? "unavailable"
            current[id] = WindowRecord(id: id, pid: pid, owner: owner, layer: layer, rect: rect)
        }
        for id in current.keys.sorted() {
            let window = current[id]!
            if previous[id] == nil {
                additions += 1
                print("WINDOW kind=\(polls == 0 ? "baseline" : "appeared") observedUptime=\(observed) \(window.description)")
                queue.async { self.inspect(window, observed: observed) }
            } else if previous[id] != window {
                changes += 1
                print("WINDOW kind=changed observedUptime=\(observed) \(window.description)")
            }
        }
        for id in previous.keys.sorted() where current[id] == nil {
            removals += 1
            print("WINDOW kind=disappeared observedUptime=\(observed) \(previous[id]!.description)")
        }
        previous = current
        polls += 1
    }

    func inspect(_ window: WindowRecord, observed: Double) {
        guard !flag.stopped else { cancelled += 1; return }
        guard window.rect.width > 0, window.rect.height > 0 else {
            print("AX windowID=\(window.id) skipped=empty-bounds"); return
        }
        // Both points are derived from the observed window geometry; no claim
        // that the same window remains topmost by the time the AX query executes.
        let points = [CGPoint(x: window.rect.midX, y: window.rect.midY),
                      CGPoint(x: window.rect.midX, y: window.rect.minY + window.rect.height * 0.1)]
        for point in points {
            guard !flag.stopped else { cancelled += 1; return }
            let began = ProcessInfo.processInfo.systemUptime
            var element: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
            var lines = ["AX windowID=\(window.id) point=\(point) queryUptime=\(began) observationDelayMs=\((began - observed) * 1000) hitStatus=\(status.rawValue) snapshot=later-system-state"]
            if status == .success, var current = element {
                for depth in 0..<12 {
                    guard !flag.stopped else { break }
                    var pid: pid_t = 0
                    let pidStatus = AXUIElementGetPid(current, &pid)
                    let roles = [kAXRoleAttribute, kAXSubroleAttribute].map { key -> String in
                        var value: CFTypeRef?
                        let status = AXUIElementCopyAttributeValue(current, key as CFString, &value)
                        return "\(key)=\(status == .success ? String(describing: value) : "error:\(status.rawValue)")"
                    }
                    lines.append("ANCESTOR windowID=\(window.id) depth=\(depth) pid=\(pid) pidStatus=\(pidStatus.rawValue) \(roles.joined(separator: " "))")
                    var parent: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent)
                    guard status == .success, let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                        lines.append("AX-PARENT-END windowID=\(window.id) status=\(status.rawValue)"); break
                    }
                    current = unsafeBitCast(parent, to: AXUIElement.self)
                    if depth == 11 { lines.append("AX diagnosticAncestorLimit=12") }
                }
            }
            lines.append("AX-END windowID=\(window.id) queryDurationMs=\((ProcessInfo.processInfo.systemUptime - began) * 1000)")
            print(lines.joined(separator: "\n")); queries += 1
        }
    }

    func stop() {
        flag.stop()
        print("STOP pollingElapsedSeconds=\(ProcessInfo.processInfo.systemUptime - started)")
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
private let watch = Watch()
guard AXIsProcessTrusted() else { fputs("ERROR: Accessibility unavailable\n", stderr); exit(2) }
let status = AXUIElementSetMessagingTimeout(watch.system, 0.2)
guard status == .success else { fputs("ERROR: Cannot set AX timeout \(status.rawValue)\n", stderr); exit(3) }
print("READY windowWatch=true durationSeconds=60 pollIntervalSeconds=0.1 axTimeoutSeconds=0.2 eventTimeSnapshot=false")
watch.poll()
guard !watch.failure else { exit(4) }
let pollTimer = Timer(timeInterval: interval, repeats: true) { _ in watch.poll() }
let endTimer = Timer(timeInterval: duration, repeats: false) { _ in watch.stop() }
RunLoop.main.add(pollTimer, forMode: .common)
RunLoop.main.add(endTimer, forMode: .common)
CFRunLoopRun()
pollTimer.invalidate(); endTimer.invalidate()
watch.flag.stop()
let totals = watch.queue.sync { (watch.queries, watch.cancelled) }
print("SUMMARY polls=\(watch.polls) additionsIncludingBaseline=\(watch.additions) changes=\(watch.changes) removals=\(watch.removals) axQueries=\(totals.0) cancelled=\(totals.1) elapsedIncludingDrainSeconds=\(ProcessInfo.processInfo.systemUptime - watch.started)")
print("verdict=window-observation-only; not-an-event-time-hit-proof")
exit(watch.failure ? 4 : 0)
