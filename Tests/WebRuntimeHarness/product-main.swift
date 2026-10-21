import AppKit
import CoreMedia
import WallpaperCore
import WebWallpaperBridge
import Darwin

@main
struct ProductAcceptanceHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw WallpaperError(message) }
    }
    static var hostNow: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .withoutOverwriting)
    }
    @MainActor static func wait(_ description: String, failure: () -> Error?, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if let error = failure() { throw error }
            try require(ContinuousClock.now < deadline, description)
            try await Task.sleep(for: .milliseconds(20))
        }
        if let error = failure() { throw error }
    }
    @MainActor static func main() {
        DWWebCreateApplication(); NSApp.setActivationPolicy(.accessory)
        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                if !(try await HarnessAuthorization.runIfRequested()) {
                    try require(CommandLine.arguments.count == 3, "Expected mode and isolated run directory")
                    let run = URL(fileURLWithPath: CommandLine.arguments[2])
                    switch CommandLine.arguments[1] {
                    case "audio": try await runAudio(run)
                    case "finder": try await runFinder(run)
                    case "ui": try await runUI(run)
                    default: throw WallpaperError("Unknown product acceptance mode")
                    }
                }
                Darwin.exit(0)
            } catch {
                fputs("PRODUCT_ACCEPTANCE FAILED \(error)\n", stderr)
                Darwin.exit(1)
            }
        }
        NSApp.run()
    }
}
