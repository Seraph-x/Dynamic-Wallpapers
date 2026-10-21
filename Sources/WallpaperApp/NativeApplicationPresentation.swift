import AppKit

@MainActor
protocol NativeApplicationPresenting {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isActive: Bool { get }
    var ownsMenuBar: Bool { get }
    var processID: pid_t { get }
    var frontmostPID: pid_t? { get }
    var dockPID: pid_t? { get }
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
    func activate()
    func activateDock(processID: pid_t) -> Bool
}

@MainActor
struct AppKitApplicationPresentation: NativeApplicationPresenting {
    var activationPolicy: NSApplication.ActivationPolicy { NSApplication.shared.activationPolicy() }
    var isActive: Bool { NSApplication.shared.isActive }
    var ownsMenuBar: Bool { NSRunningApplication.current.ownsMenuBar }
    var processID: pid_t { NSRunningApplication.current.processIdentifier }
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var dockPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        NSApplication.shared.setActivationPolicy(policy)
    }
    func activate() { NSApplication.shared.activate(ignoringOtherApps: true) }
    func activateDock(processID: pid_t) -> Bool {
        guard let dock = NSRunningApplication(processIdentifier: processID),
              dock.bundleIdentifier == "com.apple.dock" else { return false }
        NSApplication.shared.yieldActivation(to: dock)
        return dock.activate(options: [])
    }
}
