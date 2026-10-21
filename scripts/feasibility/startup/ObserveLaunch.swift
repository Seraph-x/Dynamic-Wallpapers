import AppKit
import Carbon

guard CommandLine.arguments.count == 5,
      ["manual", "login"].contains(CommandLine.arguments[3]),
      ["baseline", "accessory", "regular"].contains(CommandLine.arguments[4]) else {
    fatalError("Usage: ObserveLaunch.swift app-path log-path manual|login baseline|accessory|regular")
}
let applicationURL = URL(fileURLWithPath: CommandLine.arguments[1])
let logPath = CommandLine.arguments[2]
let login = CommandLine.arguments[3] == "login"
guard let bundleID = Bundle(url: applicationURL)?.bundleIdentifier,
      bundleID == "local.dynamicwallpaper.startup-probe.20260914" else { fatalError("Not the isolated startup probe") }
guard !FileManager.default.fileExists(atPath: logPath) else { fatalError("Probe log must be new") }
guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
    fatalError("Probe identity is already running; refusing to interfere")
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.allowsRunningApplicationSubstitution = false
configuration.addsToRecentItems = false
configuration.activates = !login
configuration.environment = ["STARTUP_PROBE_LOG": logPath]
if ["accessory", "regular"].contains(CommandLine.arguments[4]) {
    configuration.environment["STARTUP_PROBE_POLICY"] = CommandLine.arguments[4]
}
if login {
    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
    configuration.appleEvent = event
}
var application: NSRunningApplication?
var launchError: Error?
NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { app, error in
    application = app
    launchError = error
}
let observationDuration: TimeInterval = 3
let deadline = Date().addingTimeInterval(observationDuration)
var observed = Set<String>()
var managementWasVisible = false
var wasActive = false
while Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
        fatalError("Window query failed")
    }
    let titles = windows.filter {
        ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier)
            && ($0[kCGWindowLayer as String] as? Int) == 0
    }.compactMap { $0[kCGWindowName as String] as? String }.filter { !$0.isEmpty }.sorted()
    managementWasVisible = managementWasVisible || !titles.isEmpty
    wasActive = wasActive || app.isActive
    observed.insert("active=\(app.isActive) policy=\(app.activationPolicy.rawValue) visible=\(titles)")
}
if let launchError { fatalError("Launch failed: \(launchError)") }
guard let app = application else { fatalError("Launch did not complete within observation interval") }
guard app.terminate() else { fatalError("Probe refused termination") }
let cleanupDeadline = Date().addingTimeInterval(3)
while !app.isTerminated && Date() < cleanupDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
guard app.isTerminated else { fatalError("Probe cleanup did not complete") }
for sample in observed.sorted() { print(sample) }
print(try String(contentsOfFile: logPath, encoding: .utf8))
let expectedVisible = !login
print("expectedManagementVisible=\(expectedVisible) observedManagementVisible=\(managementWasVisible)")
print("expectedActive=\(!login) observedActive=\(wasActive)")
exit(expectedVisible == managementWasVisible && wasActive == !login ? 0 : 1)
