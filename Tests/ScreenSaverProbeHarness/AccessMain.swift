import Foundation
import Darwin

@main
struct AccessHarness {
    static func main() {
        do { try run() }
        catch { fputs("ACCESS HARNESS FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    private static func run() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let domain = "local.dynamicwallpaper.screensaver.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw failure("Defaults unavailable.") }
        defer { defaults.removePersistentDomain(forName: domain); defaults.synchronize() }
        let access = ProbeAccess(defaults: defaults)
        do { _ = try access.acquire(); throw failure("Unconfigured access unexpectedly succeeded.") }
        catch ProbeAccessError.authorizationRequired { /* The expected negative control. */ }
        try access.authorize(root)
        let first = try access.acquire()
        let second = try ProbeAccess(defaults: defaults).acquire()
        let bytes = try String(contentsOf: first.url.appendingPathComponent("fixture.txt"), encoding: .utf8)
        guard bytes == "real local fixture" else { throw failure("Unexpected fixture bytes.") }
        let descriptor = open(root.appendingPathComponent(".lease").path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure("Cannot open lease file.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == -1, errno == EWOULDBLOCK else {
            throw failure("Active readers did not exclude cleanup.")
        }
        try first.close()
        guard flock(descriptor, LOCK_EX | LOCK_NB) == -1, errno == EWOULDBLOCK else {
            throw failure("Closing one reader released the other reader's lease.")
        }
        try second.close()
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw failure("Cleanup remained blocked after all readers closed.")
        }
        print("{\"securityScopedBookmark\":true,\"independentReadOnlyLeases\":true,\"systemHostVerified\":false}")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ScreenSaverAccessHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
