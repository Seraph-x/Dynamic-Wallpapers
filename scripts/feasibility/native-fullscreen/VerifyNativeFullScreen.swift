import AppKit

func validateWindowReport(at url: URL) throws -> [String] {
    guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw NSError(domain: "NativeFullScreenVerification", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Window report is not a JSON object"])
    }
    var failures: [String] = []
    for key in ["readinessError", "error"] {
        if let message = result[key] as? String, !message.isEmpty { failures.append(message) }
    }
    for (phase, fullScreen) in [("before", false), ("entered", true), ("final", false)] {
        guard let state = result[phase] as? [String: Any] else { failures.append("Missing \(phase) state"); continue }
        if state["policy"] as? Int != 0 { failures.append("\(phase): Open management window must retain regular activation policy") }
        if state["primary"] as? Bool != true || state["none"] as? Bool != false {
            failures.append("\(phase): Window lacks native full-screen capability")
        }
        if state["fullscreen"] as? Bool != fullScreen { failures.append("\(phase): Incorrect native full-screen state") }
        if state["attachedSheet"] as? Bool != false { failures.append("\(phase): Unexpected sheet or error alert") }
        if phase == "before" && (state["resizable"] as? Bool != true || state["zoomEnabled"] as? Bool != true) {
            failures.append("Main window is not resizable or its green button is disabled")
        }
    }
    let expectedEvents = [NSWindow.willEnterFullScreenNotification.rawValue, NSWindow.didEnterFullScreenNotification.rawValue,
                          NSWindow.willExitFullScreenNotification.rawValue, NSWindow.didExitFullScreenNotification.rawValue]
    if result["events"] as? [String] != expectedEvents { failures.append("Native full-screen notification sequence is incomplete") }
    return failures
}

guard CommandLine.arguments.count == 6 else {
    fatalError("Usage: VerifyNativeFullScreen app-path new-evidence-path hide|show probe-dylib-path validation-bundle-id")
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let mode = CommandLine.arguments[3]
let dylib = URL(fileURLWithPath: CommandLine.arguments[4]).standardizedFileURL
let identity = CommandLine.arguments[5]
guard ["hide", "show"].contains(mode), identity.hasPrefix("local.dynamicwallpaper.native-fullscreen-validation."),
      Bundle(url: appURL)?.bundleIdentifier == identity,
      NSRunningApplication.runningApplications(withBundleIdentifier: identity).isEmpty else {
    fatalError("Refusing invalid mode, identity, or already-running validation application")
}
guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Evidence directory must be new") }
let home = output.appendingPathComponent("home")
let support = home.appendingPathComponent("Library/Application Support/DynamicWallpaper")
try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
let library: [String: Any] = ["version": 3, "media": [], "playlists": [], "displays": [],
    "settings": ["pauseOnLowPower": false, "pauseOnHighTemperature": false,
                 "showDockIcon": mode == "show", "systemWallpaperSyncEnabled": false,
                 "isMuted": true, "webInteractionEnabled": false]]
try JSONSerialization.data(withJSONObject: library, options: [.prettyPrinted, .sortedKeys])
    .write(to: support.appendingPathComponent("library-extended.json"), options: .withoutOverwriting)
let report = output.appendingPathComponent("window.json")
let configuration = NSWorkspace.OpenConfiguration()
configuration.allowsRunningApplicationSubstitution = false
configuration.addsToRecentItems = false
configuration.activates = true
configuration.environment = ["CFFIXED_USER_HOME": home.path,
    "DYLD_INSERT_LIBRARIES": dylib.path, "FULLSCREEN_PROBE_ID": identity,
    "FULLSCREEN_PROBE_OUTPUT": report.path, "FULLSCREEN_PROBE_POLICY": "0"]
var launched: NSRunningApplication?
var launchError: Error?
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
    launched = application
    launchError = error
}
// Up to 10 seconds for readiness and 6 seconds for each native transition, plus launch overhead.
let deadline = Date().addingTimeInterval(30)
while launchError == nil && (!FileManager.default.fileExists(atPath: report.path) || launched == nil) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}
var failures: [String] = []
if let launchError { failures.append("Launch: \(launchError)") }
if !FileManager.default.fileExists(atPath: report.path) { failures.append("Window report did not arrive within 30 seconds") }
else {
    do { failures += try validateWindowReport(at: report) }
    catch { failures.append("Cannot read window report: \(error)") }
}
if let app = launched ?? NSRunningApplication.runningApplications(withBundleIdentifier: identity).first {
    if app.bundleURL?.standardizedFileURL != appURL { failures.append("LaunchServices substituted another application") }
    if !app.isFinishedLaunching { failures.append("Application did not finish launching") }
    if !app.terminate() { failures.append("Application refused termination") }
    let shutdownDeadline = Date().addingTimeInterval(5)
    while !app.isTerminated && Date() < shutdownDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    if !app.isTerminated {
        failures.append("Application did not terminate within 5 seconds; forced cleanup")
        if !app.forceTerminate() { failures.append("Forced cleanup was rejected") }
        let forcedDeadline = Date().addingTimeInterval(2)
        while !app.isTerminated && Date() < forcedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if !app.isTerminated { failures.append("Forced cleanup did not terminate the validation application") }
    }
} else { failures.append("Application was not launched") }
try JSONSerialization.data(withJSONObject: failures, options: [.prettyPrinted])
    .write(to: output.appendingPathComponent("failures.json"), options: .withoutOverwriting)
print("mode=\(mode) failures=\(failures)")
exit(failures.isEmpty ? 0 : 1)
