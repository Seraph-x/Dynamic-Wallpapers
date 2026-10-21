import AppKit
import ApplicationServices

// Read-only diagnostics. Does not enumerate file names or install/post events.
func value(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var result: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &result)
    return (status, result)
}
func describe(_ element: AXUIElement) -> String {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return (["pid=\(pid)"] + [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute].map {
        let (status, result) = value(element, $0)
        return "\($0)=\(status == .success ? String(describing: result!) : "error:\(status.rawValue)")"
    }).joined(separator: " ")
}
func hit(_ target: AXUIElement, label: String, point: CGPoint) {
    var result: AXUIElement?
    let status = AXUIElementCopyElementAtPosition(target, Float(point.x), Float(point.y), &result)
    print("hit target=\(label) point=\(point) status=\(status.rawValue)")
    guard status == .success, var current = result else { return }
    for depth in 0..<12 {
        print("ancestor=\(depth) \(describe(current))")
        let (status, parent) = value(current, kAXParentAttribute)
        guard status == .success, let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
        current = unsafeBitCast(parent, to: AXUIElement.self)
    }
}
let trusted = AXIsProcessTrusted()
let hitsOnly = CommandLine.arguments.contains("--hits-only")
print("time=\(ISO8601DateFormatter().string(from: Date())) accessibilityTrusted=\(trusted) listenEventAccess=\(CGPreflightListenEventAccess())")
guard trusted else { fputs("ERROR: Accessibility unavailable\n", stderr); exit(2) }
guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
    fputs("ERROR: Finder not running\n", stderr); exit(3)
}
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
    fputs("ERROR: Window list unavailable\n", stderr); exit(4)
}
print("windowOrder=front-to-back count=\(windows.count)")
for (index, window) in windows.enumerated() where !hitsOnly {
    // No window titles: only process ownership, layer and geometry.
    let fields = [kCGWindowOwnerName, kCGWindowOwnerPID, kCGWindowLayer, kCGWindowBounds, kCGWindowAlpha, kCGWindowNumber]
    print("windowIndex=\(index) " + fields.map { "\($0)=\(String(describing: window[$0 as String]))" }.joined(separator: " "))
}
let finderElement = AXUIElementCreateApplication(finder.processIdentifier)
func inspect(_ element: AXUIElement, depth: Int) {
    print("treeDepth=\(depth) \(describe(element))")
    let role = value(element, kAXRoleAttribute).1 as? String
    if role == kAXMenuBarRole || role == "AXFunctionRowTopLevelElement" {
        print("diagnostic-subtree-omitted=non-desktop-controls"); return
    }
    guard depth < 8 else { print("diagnostic-depth-limit=8"); return }
    let (status, childrenValue) = value(element, kAXChildrenAttribute)
    let children = childrenValue as? [AXUIElement]
    print("childrenStatus=\(status.rawValue) count=\(children?.count.description ?? "unavailable")")
    for child in children ?? [] { inspect(child, depth: depth + 1) }
}
if !hitsOnly { inspect(finderElement, depth: 0) }
let arguments = CommandLine.arguments.dropFirst().filter { $0 != "--hits-only" }
var points: [CGPoint] = []
if arguments.isEmpty {
    for screen in NSScreen.screens {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { exit(5) }
        let rect = CGDisplayBounds(id)
        print("display=\(id) bounds=\(rect)")
        points += [CGPoint(x: rect.midX, y: rect.midY), CGPoint(x: rect.maxX - 60, y: rect.minY + 80), CGPoint(x: rect.minX + 20, y: rect.midY)]
    }
} else if arguments.count.isMultiple(of: 2) {
    for index in stride(from: 0, to: arguments.count, by: 2) {
        guard let x = Double(arguments[index]), let y = Double(arguments[index + 1]), x.isFinite, y.isFinite else {
            fputs("ERROR: Invalid Quartz coordinate\n", stderr); exit(64)
        }
        points.append(CGPoint(x: x, y: y))
    }
} else { fputs("Usage: finder-diagnostics [--hits-only] [Quartz-x Quartz-y ...]\n", stderr); exit(64) }
guard !points.isEmpty else { fputs("ERROR: No display coordinates\n", stderr); exit(5) }
for point in points {
    hit(AXUIElementCreateSystemWide(), label: "system", point: point)
    // Finder-local hits can inspect occluded content; never imply that system clicks reach it.
    hit(finderElement, label: "finder-local-not-system-routing", point: point)
}
print("verdict=diagnostic-only; blank-desktop-not-established")
