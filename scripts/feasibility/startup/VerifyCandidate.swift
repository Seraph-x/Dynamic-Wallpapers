import AppKit
import Carbon
import ImageIO

// External lifecycle probe. Only run against a separately identified validation copy.
guard (CommandLine.arguments.count == 4 || CommandLine.arguments.count == 5),
      ["show", "hide"].contains(CommandLine.arguments[3]),
      CommandLine.arguments.count == 4 || CommandLine.arguments[4] == "--check-external-hide" else {
    fatalError("Usage: swift VerifyCandidate.swift validation-app-path new-evidence-directory show|hide [--check-external-hide]")
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let showDock = CommandLine.arguments[3] == "show"
let checkExternalHide = CommandLine.arguments.contains("--check-external-hide")
let identity = "local.dynamicwallpaper.window-validation.20260914"
guard Bundle(url: appURL)?.bundleIdentifier == identity else { fatalError("Not the isolated validation identity") }
guard NSRunningApplication.runningApplications(withBundleIdentifier: identity).isEmpty else {
    fatalError("Validation identity is already running")
}
guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Evidence directory must be new") }
guard CGPreflightScreenCaptureAccess() else { fatalError("Window observation requires existing Screen Recording access") }
let home = output.appendingPathComponent("home")
let support = home.appendingPathComponent("Library/Application Support/DynamicWallpaper")
try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "CandidateVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func prepareLibrary() throws {
    let png = output.appendingPathComponent("wallpaper.png")
    guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "CandidateFixture", code: 1)
    }
    context.setFillColor(CGColor(red: 0.12, green: 0.26, blue: 0.42, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    guard let image = context.makeImage() else { throw NSError(domain: "CandidateFixture", code: 2) }
    CGImageDestinationAddImage(destination, image, nil)
    try require(CGImageDestinationFinalize(destination), "PNG fixture could not be written")
    let mediaID = UUID().uuidString
    let bindings = try NSScreen.screens.map { screen -> [String: Any] in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            throw NSError(domain: "CandidateFixture", code: 3)
        }
        return ["id": CFUUIDCreateString(nil, uuid) as String, "groupID": UUID().uuidString, "fit": "fill",
            "source": ["kind": "media", "mediaID": mediaID, "audio": ["isMuted": true, "volume": 0.0]]]
    }
    try require(!bindings.isEmpty, "No display is available")
    let library: [String: Any] = ["version": 3, "playlists": [], "displays": bindings,
        "media": [["id": mediaID, "url": png.absoluteString, "kind": "image", "width": 32,
                   "height": 32, "backend": "native", "isFavorite": false]],
        "settings": ["pauseOnLowPower": false, "pauseOnHighTemperature": false, "isMuted": true,
                     "showDockIcon": showDock, "webInteractionEnabled": false]]
    let data = try JSONSerialization.data(withJSONObject: library, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: support.appendingPathComponent("library-extended.json"), options: .withoutOverwriting)
}

struct Snapshot: Codable, Equatable {
    struct Window: Codable, Equatable {
        let id: Int
        let layer: Int
        let title: String
    }
    let pid: Int32
    let policy: Int
    let active: Bool
    let hidden: Bool
    let finishedLaunching: Bool
    let windows: [Window]
    var management: [Window] { windows.filter { $0.layer == 0 } }
    var desktopIDs: [Int] { windows.filter { $0.layer < 0 }.map(\.id).sorted() }
}

func snapshot(_ application: NSRunningApplication) throws -> Snapshot {
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
        throw NSError(domain: "CandidateWindowQuery", code: 1)
    }
    let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == application.processIdentifier }
    let visible = try owned.map { window -> Snapshot.Window in
        guard let id = window[kCGWindowNumber as String] as? Int,
              let layer = window[kCGWindowLayer as String] as? Int else {
            throw NSError(domain: "CandidateWindowQuery", code: 2)
        }
        return Snapshot.Window(id: id, layer: layer, title: window[kCGWindowName as String] as? String ?? "")
    }.sorted { $0.id < $1.id }
    return Snapshot(pid: application.processIdentifier, policy: application.activationPolicy.rawValue,
        active: application.isActive, hidden: application.isHidden,
        finishedLaunching: application.isFinishedLaunching, windows: visible)
}

var evidence: [String: [Snapshot]] = [:]
var running: NSRunningApplication?

func observe(_ phase: String, launching: Bool = false) throws -> Snapshot {
    // A cold signed bundle can spend seconds in xpcproxy before AppKit starts.
    // Observe from the request, then keep sampling for one second after real launch completion.
    let deadline = Date().addingTimeInterval(launching ? 10 : 1)
    var samples: [Snapshot] = []
    var finishedAt: Date?
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        if let application = NSRunningApplication.runningApplications(withBundleIdentifier: identity).first {
            let sample = try snapshot(application)
            if samples.last != sample { samples.append(sample) }
            if launching && sample.finishedLaunching {
                if finishedAt == nil { finishedAt = Date() }
                if Date().timeIntervalSince(finishedAt!) >= 1 { break }
            }
        }
    }
    evidence[phase] = samples
    guard let last = samples.last else { throw NSError(domain: "CandidateNotRunning", code: 1) }
    try require(!launching || last.finishedLaunching, "AppKit launch did not finish within 10 seconds")
    return last
}

func launch(login: Bool, phase: String, typeCodeMarker: Bool = false) throws -> Snapshot {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.allowsRunningApplicationSubstitution = false
    configuration.addsToRecentItems = false
    configuration.activates = !login
    configuration.environment = ["CFFIXED_USER_HOME": home.path]
    if login {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let marker = typeCodeMarker
            ? NSAppleEventDescriptor(typeCode: OSType(keyAELaunchedAsLogInItem))
            : NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem))
        event.setParam(marker, forKeyword: AEKeyword(keyAEPropData))
        configuration.appleEvent = event
    }
    var finished = false
    var error: Error?
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, failure in
        running = application
        error = failure
        finished = true
    }
    let state: Snapshot
    do { state = try observe(phase, launching: true) }
    catch let observationError {
        if let error { throw error }
        throw observationError
    }
    if let error { throw error }
    try require(finished && running != nil, "Launch callback did not complete")
    try require(running?.bundleURL?.standardizedFileURL == appURL, "LaunchServices substituted another application copy")
    try require(state.policy == (showDock || !login ? 0 : 1), "Dock policy does not match the preference and management-window state")
    try require(!state.desktopIDs.isEmpty, "Isolated saved wallpaper was not restored")
    return state
}

func terminate() throws {
    guard let application = running else { return }
    try require(application.terminate(), "Validation application refused termination")
    let deadline = Date().addingTimeInterval(5)
    while !application.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    try require(application.isTerminated, "Validation application did not complete shutdown")
    running = nil
}

var failures: [String] = []
do {
    try prepareLibrary()
    let manual = try launch(login: false, phase: "manual")
    try require(manual.management.count == 1 && manual.active, "Manual launch must show and activate the library")
    try terminate()
    let login = try launch(login: true, phase: "login")
    try require(evidence["login"]!.allSatisfy { $0.management.isEmpty && !$0.active }, "Login launch showed management UI or stole focus")
    let reopen = try launch(login: false, phase: "reopen")
    try require(reopen.pid == login.pid && reopen.desktopIDs == login.desktopIDs, "Reopen recreated the process or desktop")
    try require(reopen.management.count == 1 && reopen.active, "Reopen did not show the library when desktop windows were already visible")
    if checkExternalHide {
        // This remote API is not Cmd-H / NSApplication.hide(_:). The host may reject it.
        // Keep that result as a failure, rather than substituting a successful hide.
        try require(running!.hide(), "External NSRunningApplication.hide() was rejected; in-app hide is a separate test")
        let hidden = try observe("hidden")
        try require(hidden.hidden && hidden.management.isEmpty, "Hide did not hide the management interface")
        try require(hidden.desktopIDs == login.desktopIDs, "Hide removed the official wallpaper from the screen")
    }
    let reopenedAgain = try launch(login: false, phase: "repeatedReopen")
    try require(reopenedAgain.pid == login.pid && reopenedAgain.management.count == 1, "Repeated reopen lost or duplicated the library")
    try require(reopenedAgain.desktopIDs == login.desktopIDs, "Repeated reopen recreated the desktop")
    try terminate()
    let typeCodeLogin = try launch(login: true, phase: "loginTypeCode", typeCodeMarker: true)
    try require(evidence["loginTypeCode"]!.allSatisfy { $0.management.isEmpty && !$0.active },
                "Type-code login launch showed management UI or stole focus")
    let typeCodeReopen = try launch(login: false, phase: "reopenAfterTypeCodeLogin")
    try require(typeCodeReopen.pid == typeCodeLogin.pid && typeCodeReopen.desktopIDs == typeCodeLogin.desktopIDs,
                "Reopen after type-code login recreated the process or desktop")
    try require(typeCodeReopen.management.count == 1 && typeCodeReopen.active,
                "Reopen after type-code login did not show the library")
} catch { failures.append(String(describing: error)) }
do { try terminate() } catch { failures.append("Cleanup failed: \(error)") }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(evidence).write(to: output.appendingPathComponent("windows.json"), options: .withoutOverwriting)
try encoder.encode(failures).write(to: output.appendingPathComponent("failures.json"), options: .withoutOverwriting)
print("mode=\(showDock ? "regular" : "accessory") externalHide=\(checkExternalHide) phases=\(evidence.keys.sorted()) failures=\(failures)")
exit(failures.isEmpty ? 0 : 1)
