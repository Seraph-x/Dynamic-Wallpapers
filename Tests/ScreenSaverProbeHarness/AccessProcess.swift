import Foundation
import Darwin

/// A real-process test driver; it is not compiled into the screen saver bundle.
@main
struct AccessProcess {
    static func main() {
        do { try run() }
        catch { fputs("ACCESS PROCESS FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 4 else { throw failure("Expected directory, test domain, and operation.") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let domain = CommandLine.arguments[2]
        guard domain.hasPrefix("local.dynamicwallpaper.screensaver.test."),
              let defaults = UserDefaults(suiteName: domain) else { throw failure("A private test domain is required.") }
        let access = ProbeAccess(defaults: defaults)
        switch CommandLine.arguments[3] {
        case "authorize":
            try access.authorize(root)
            print("{\"bookmarkSaved\":true}")
        case "hold":
            try hold(access)
        case "invalidate":
            defaults.set(Data("invalid bookmark".utf8), forKey: "directoryBookmark")
            guard defaults.synchronize() else { throw failure("Cannot persist invalid-bookmark negative control.") }
        case "clear":
            defaults.removePersistentDomain(forName: domain)
            guard defaults.synchronize() else { throw failure("Cannot remove test preferences.") }
        default:
            throw failure("Unknown access-process operation.")
        }
    }

    private static func hold(_ access: ProbeAccess) throws {
        let lease = try access.acquire()
        do {
            let bytes = try String(contentsOf: lease.url.appendingPathComponent("fixture.txt"), encoding: .utf8)
            guard bytes == "real local fixture" else { throw failure("Unexpected fixture bytes.") }
            print("{\"leaseHeld\":true,\"fixtureRead\":true}")
            fflush(stdout)
            guard readLine() == "close" else { throw failure("Expected explicit lease release.") }
        } catch {
            let original = error
            do { try lease.close() }
            catch { throw failure("\(original.localizedDescription); release: \(error.localizedDescription)") }
            throw original
        }
        try lease.close()
        print("{\"leaseReleased\":true}")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ScreenSaverAccessProcess", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
