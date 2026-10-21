import AppKit
import ApplicationServices

// Read-only diagnostic: never installs an event tap or posts synthetic input.
let requestPermission = CommandLine.arguments.contains("--request-permission")
let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: requestPermission] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(options)
print("accessibilityTrusted=\(trusted) listenEventAccess=\(CGPreflightListenEventAccess())")
guard trusted else {
    fputs("ERROR: Accessibility permission unavailable; real Finder hit testing cannot be verified.\n", stderr)
    exit(2)
}
let system = AXUIElementCreateSystemWide()
if CommandLine.arguments.contains("--finder-tree") {
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
        fputs("ERROR: Finder is not running\n", stderr); exit(4)
    }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return status == .success ? value : nil
    }
    func inspect(_ element: AXUIElement, depth: Int) {
        let role = attribute(element, kAXRoleAttribute) as? String ?? "unavailable"
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? "unavailable"
        print("depth=\(depth) role=\(role) subrole=\(subrole) position=\(String(describing: attribute(element, kAXPositionAttribute))) size=\(String(describing: attribute(element, kAXSizeAttribute)))")
        // Diagnostic traversal only; no file names or contents are collected.
        guard depth < 8 else { print("diagnostic-depth-limit=8"); return }
        if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children { inspect(child, depth: depth + 1) }
        }
    }
    inspect(AXUIElementCreateApplication(finder.processIdentifier), depth: 0)
    exit(0)
}
let points: [CGPoint]
let coordinates = CommandLine.arguments.dropFirst().filter { $0 != "--request-permission" }
if coordinates.count == 2, let x = Double(coordinates[0]), let y = Double(coordinates[1]), x.isFinite, y.isFinite {
    points = [CGPoint(x: x, y: y)]
} else if coordinates.isEmpty {
    points = NSScreen.screens.flatMap { screen in
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let rect = CGDisplayBounds(id)
        return [CGPoint(x: rect.midX, y: rect.midY), CGPoint(x: rect.maxX - 60, y: rect.minY + 80)]
    }
} else {
    fputs("Usage: desktop-hit-test [--request-permission] [Quartz-x Quartz-y]\n", stderr)
    exit(64)
}
for point in points {
    var element: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
    print("point=\(point) result=\(result.rawValue)")
    guard result == .success, var current = element else { exit(3) }
    // Limit diagnostic ancestor traversal; this is not the product's hit decision.
    for depth in 0..<12 {
        var pid: pid_t = 0
        AXUIElementGetPid(current, &pid)
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXDescriptionAttribute]
        let values = attributes.map { key -> String in
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(current, key as CFString, &value)
            return "\(key)=\(status == .success ? String(describing: value!) : "error:\(status.rawValue)")"
        }
        print("depth=\(depth) pid=\(pid) \(values.joined(separator: " "))")
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
              let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
        current = unsafeBitCast(parent, to: AXUIElement.self)
    }
}
