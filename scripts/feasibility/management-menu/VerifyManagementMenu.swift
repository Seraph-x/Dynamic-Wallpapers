import AppKit
import ApplicationServices
import Carbon

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw NSError(domain: "ManagementMenuVerification", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func attribute(_ element: AXUIElement, _ name: String, optional: Bool = false) throws -> CFTypeRef? {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    if optional && (status == .noValue || status == .attributeUnsupported) { return nil }
    try require(status == .success, "AX read \(name) failed: \(status.rawValue)")
    return value
}

func children(_ element: AXUIElement) throws -> [AXUIElement] {
    try attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func title(_ element: AXUIElement) throws -> String {
    try attribute(element, kAXTitleAttribute, optional: true) as? String ?? ""
}

func waitFor(_ message: String, condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(10)
    while try !condition() {
        try require(Date() < deadline, "Timed out after 10 seconds: \(message)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

let flags = Array(CommandLine.arguments.dropFirst(3))
guard (3...5).contains(CommandLine.arguments.count), Set(flags).count == flags.count,
      flags.allSatisfy({ ["--show-dock", "--cold-start"].contains($0) }) else {
    fatalError("Usage: VerifyManagementMenu validation-app-path new-evidence-directory [--show-dock] [--cold-start]")
}
let showDockIcon = flags.contains("--show-dock")
let coldStart = flags.contains("--cold-start")
let backgroundPolicy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
let originalPointer = CGEvent(source: nil)?.location
let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
guard let identity = Bundle(url: appURL)?.bundleIdentifier,
      identity.hasPrefix("local.dynamicwallpaper.menu-validation."),
      NSRunningApplication.runningApplications(withBundleIdentifier: identity).isEmpty else {
    fatalError("Expected a non-running, separately identified menu-validation app")
}
guard AXIsProcessTrusted() else { fatalError("Existing Accessibility permission is required") }
guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Evidence directory must be new") }
let home = output.appendingPathComponent("home")
let support = home.appendingPathComponent("Library/Application Support/DynamicWallpaper")
try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
let libraryURL = support.appendingPathComponent("library-extended.json")
let library: [String: Any] = ["version": 3, "media": [], "playlists": [], "displays": [],
    "settings": ["showDockIcon": showDockIcon, "language": "en", "isMuted": true,
                 "pauseOnLowPower": false, "pauseOnHighTemperature": false,
                 "systemWallpaperSyncEnabled": false, "webInteractionEnabled": false]]
let originalLibrary = try JSONSerialization.data(withJSONObject: library, options: [.prettyPrinted, .sortedKeys])
try originalLibrary.write(to: libraryURL, options: .withoutOverwriting)
var application: NSRunningApplication?
var evidence: [[String: Any]] = []

func appElement() throws -> AXUIElement {
    guard let application else { throw NSError(domain: "ApplicationNotLaunched", code: 1) }
    return AXUIElementCreateApplication(application.processIdentifier)
}

func managementWindows() throws -> [AXUIElement] {
    let windows = try attribute(appElement(), kAXWindowsAttribute) as? [AXUIElement] ?? []
    return try windows.filter { try attribute($0, kAXCloseButtonAttribute, optional: true) != nil }
}

func menuItems() throws -> [AXUIElement] {
    guard let value = try attribute(appElement(), kAXMenuBarAttribute) else {
        throw NSError(domain: "MissingApplicationMenu", code: 1)
    }
    return try children(value as! AXUIElement)
}

func snapshot(_ phase: String) throws {
    guard let application else { return }
    let windows = try managementWindows().map { try title($0) }
    let menus = try menuItems().map { item -> [String: Any] in
        guard let value = try attribute(item, kAXSizeAttribute) else {
            throw NSError(domain: "MissingMenuGeometry", code: 1)
        }
        var size = CGSize.zero
        try require(AXValueGetValue(value as! AXValue, .cgSize, &size), "Invalid menu item size")
        return ["title": try title(item), "width": size.width, "height": size.height]
    }
    evidence.append(["phase": phase, "pid": application.processIdentifier,
        "policy": application.activationPolicy.rawValue, "active": application.isActive,
        "ownsMenuBar": application.ownsMenuBar, "windows": windows, "menus": menus])
}

func launch(login: Bool) throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.allowsRunningApplicationSubstitution = false
    configuration.addsToRecentItems = false
    configuration.activates = !login
    configuration.arguments = ["-AppleLanguages", "(en)"]
    configuration.environment = ["CFFIXED_USER_HOME": home.path]
    if login {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(typeCode: OSType(keyAELaunchedAsLogInItem)),
                       forKeyword: AEKeyword(keyAEPropData))
        configuration.appleEvent = event
    }
    var completed = false
    var launchError: Error?
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
        application = app
        launchError = error
        completed = true
    }
    try waitFor("launch callback") { completed }
    if let launchError { throw launchError }
    try waitFor("AppKit launch completion") { application?.isFinishedLaunching == true }
    try require(application?.bundleURL?.standardizedFileURL == appURL, "LaunchServices substituted another app")
}

func expectMenus(_ phase: String) throws {
    try waitFor("active regular application owning its menu bar") {
        application?.activationPolicy == .regular && application?.isActive == true && application?.ownsMenuBar == true
    }
    // A system-wide auto-hidden menu bar has zero AX geometry until revealed.
    // Hover the actual screen edge; do not change the user's menu-bar preferences.
    let screen = CGDisplayBounds(CGMainDisplayID())
    try movePointer(to: CGPoint(x: screen.minX + 15, y: screen.minY + 1))
    try waitFor("native menu rendering") {
        let items = try menuItems()
        guard !items.isEmpty else { return false }
        for item in items {
            guard let value = try attribute(item, kAXSizeAttribute) else { return false }
            var size = CGSize.zero
            try require(AXValueGetValue(value as! AXValue, .cgSize, &size), "Invalid menu size")
            if size.width <= 0 || size.height <= 0 { return false }
        }
        return true
    }
    let menus = try menuItems()
    let titles = try menus.map { try title($0) }
    for expected in ["File", "Edit", "View", "Window", "Help"] {
        try require(titles.contains(expected), "Missing native menu: \(expected)")
    }
    for item in menus {
        guard let value = try attribute(item, kAXSizeAttribute) else {
            throw NSError(domain: "MissingMenuGeometry", code: 1)
        }
        var size = CGSize.zero
        try require(AXValueGetValue(value as! AXValue, .cgSize, &size), "Invalid menu size")
        try require(size.width > 0 && size.height > 0, "Menu exists but is not rendered: \(try title(item))")
    }
    try snapshot(phase)
}

func movePointer(to point: CGPoint) throws {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: point, mouseButton: .left) else {
        throw NSError(domain: "MissingMouseEvent", code: 1)
    }
    event.post(tap: .cghidEventTap)
}

func pressMenu(_ section: String, item itemTitle: String) throws {
    guard let menu = try menuItems().first(where: { try title($0) == section }) else {
        throw NSError(domain: "MissingMenuSection", code: 1, userInfo: [NSLocalizedDescriptionKey: section])
    }
    try require(AXUIElementPerformAction(menu, kAXPressAction as CFString) == .success, "Cannot open \(section) menu")
    let items = try children(menu).flatMap { try children($0) }
    guard let item = try items.first(where: { try title($0) == itemTitle }) else {
        throw NSError(domain: "MissingMenuItem", code: 1, userInfo: [NSLocalizedDescriptionKey: itemTitle])
    }
    try require(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success, "Cannot select \(itemTitle)")
}

func closeWindow(_ window: AXUIElement) throws {
    guard let value = try attribute(window, kAXCloseButtonAttribute) else {
        throw NSError(domain: "MissingCloseButton", code: 1)
    }
    try require(AXUIElementPerformAction(value as! AXUIElement, kAXPressAction as CFString) == .success,
                "Window close action failed")
}

func setMinimized(_ window: AXUIElement, _ minimized: Bool) throws {
    try require(AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                           minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success,
                "Cannot change the window's minimized state")
    try waitFor("minimized=\(minimized)") {
        try attribute(window, kAXMinimizedAttribute) as? Bool == minimized
    }
}

func terminate() throws {
    guard let application else { return }
    try require(application.terminate(), "Validation app rejected termination")
    try waitFor("validation app termination") { application.isTerminated }
}

var failures: [String] = []
do {
    try launch(login: !coldStart)
    let pid = application!.processIdentifier
    if !coldStart {
        try waitFor("saved Dock policy applied without UI") {
            try require(application?.isActive == false, "Login activated before preference readiness")
            try require(managementWindows().isEmpty, "Login opened UI before preference readiness")
            return application?.activationPolicy == backgroundPolicy
        }
        let loginDeadline = Date().addingTimeInterval(1)
        while Date() < loginDeadline {
            try require(application?.activationPolicy == backgroundPolicy && application?.isActive == false,
                        "Login unexpectedly promoted or activated the app")
            try require(managementWindows().isEmpty, "Login opened management UI")
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        try snapshot("login")
        try launch(login: false)
        try require(application?.processIdentifier == pid, "Reopen replaced the process")
    }
    try expectMenus(coldStart ? "cold-library" : "library")
    let mainWindow = try managementWindows()[0]
    try setMinimized(mainWindow, true)
    try require(application?.activationPolicy == .regular, "Minimizing the window removed its Dock icon")
    try snapshot("minimized")
    try setMinimized(mainWindow, false)
    try expectMenus("restored")
    let appMenu = try title(menuItems()[1])
    try pressMenu(appMenu, item: "Hide \(appMenu)")
    try waitFor("native Hide command") { application?.isHidden == true }
    try require(application?.activationPolicy == .regular, "Hiding the app changed the open-window policy")
    try snapshot("hidden")
    try launch(login: false)
    try expectMenus("unhidden")
    for (section, item, count) in [(appMenu, "Settings…", 2), ("Window", "Video Transcoding", 3), ("Help", "User Guide", 4)] {
        try pressMenu(section, item: item)
        try waitFor("\(count) management windows after \(item)") { try managementWindows().count == count }
        try expectMenus(item)
    }
    for remaining in stride(from: 3, through: 0, by: -1) {
        try closeWindow(managementWindows()[0])
        try waitFor("\(remaining) remaining windows") { try managementWindows().count == remaining }
        if remaining > 0 {
            try require(application?.activationPolicy == .regular, "Closing one window removed other windows' menus")
        } else {
            try waitFor("background Dock policy") { application?.activationPolicy == backgroundPolicy }
        }
        try snapshot("remaining-\(remaining)")
    }
    try launch(login: false)
    try expectMenus("reopened")
    try require(application?.processIdentifier == pid, "Repeated reopen replaced the process")
    try require(Data(contentsOf: libraryURL) == originalLibrary, "Window lifecycle changed the saved library")
} catch {
    failures.append(String(describing: error))
    do { try snapshot("failure") } catch { failures.append("Failure snapshot: \(error)") }
}
do { try terminate() } catch { failures.append("Cleanup: \(error)") }
if let originalPointer {
    do { try movePointer(to: originalPointer) } catch { failures.append("Pointer cleanup: \(error)") }
}
let report: [String: Any] = ["application": appURL.path, "evidence": evidence, "failures": failures]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("menus.json"), options: .withoutOverwriting)
print("Management menu verification: phases=\(evidence.count), failures=\(failures)")
exit(failures.isEmpty ? 0 : 1)
