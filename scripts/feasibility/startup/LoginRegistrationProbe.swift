import AppKit
import Darwin
import ServiceManagement

@main
enum LoginRegistrationProbe {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = RegistrationDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
private final class RegistrationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { Darwin.exit(try recordRegistration() ? 0 : 1) }
        catch { fputs("Registration probe failed: \(error)\n", stderr); Darwin.exit(1) }
    }

    private func recordRegistration() throws -> Bool {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected an output JSON path") }
        guard Bundle.main.bundleIdentifier == "local.dynamicwallpaper.login-validation.20260914" else {
            fatalError("Registration is restricted to the isolated validation identity")
        }
        let service = SystemLoginItemService()
        let before = service.status
        var errors: [String] = []
        var registeredSuccessfully = false
        let mayRegister = before == .notRegistered || before == .notFound
        if mayRegister {
            do { try service.register(); registeredSuccessfully = true }
            catch { errors.append("register: \(error as NSError)") }
        } else {
            errors.append("Initial service state is not unregistered: \(before.rawValue)")
        }
        let registered = service.status
        if mayRegister && (registeredSuccessfully || registered == .enabled || registered == .requiresApproval) {
            do { try service.unregister() }
            catch { errors.append("unregister: \(error as NSError)") }
        }
        let after = service.status
        let evidence: [String: Any] = ["bundleID": Bundle.main.bundleIdentifier ?? "missing",
            "before": before.rawValue, "registered": registered.rawValue, "after": after.rawValue, "errors": errors]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .withoutOverwriting)
        print(String(decoding: data, as: UTF8.self))
        return errors.isEmpty && (registered == .enabled || registered == .requiresApproval) && after == .notRegistered
    }
}
