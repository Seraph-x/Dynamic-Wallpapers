import Foundation

enum WebInteractionControlFailure: Error {
    case persistence(Error, runtimeWasForcedOff: Bool)
    case settings(Error)
    case shuttingDown
}

struct WebInteractionControlOutcome {
    let result: WebInteractionSettingResult
    let failure: WebInteractionControlFailure?
}

@MainActor
final class WebInteractionController {
    private static let pollInterval: TimeInterval = 2
    private let permissionService: any WebInteractionPermissionServicing
    private let setRuntimeEnabled: (Bool) -> Void
    private let refreshRuntimeStatus: () -> Void
    private var permissionTimer: Timer?
    private var isShuttingDown = false
    var onPoll: (() -> Void)?

    init(permissionService: any WebInteractionPermissionServicing,
         setRuntimeEnabled: @escaping (Bool) -> Void,
         refreshRuntimeStatus: @escaping () -> Void) {
        self.permissionService = permissionService
        self.setRuntimeEnabled = setRuntimeEnabled
        self.refreshRuntimeStatus = refreshRuntimeStatus
    }

    func setEnabled(_ enabled: Bool, currentEnabled: Bool,
                    persistAndPublish: (Bool) throws -> Void,
                    forcePublish: (Bool) -> Void) -> WebInteractionControlOutcome {
        guard !isShuttingDown else {
            return WebInteractionControlOutcome(result: .failed, failure: .shuttingDown)
        }
        let missing = permissionService.missingPermissions
        if !missing.isEmpty {
            if currentEnabled {
                let failure = revoke(persistAndPublish: persistAndPublish, forcePublish: forcePublish)
                let result: WebInteractionSettingResult = enabled ? .needsPermissions(missing)
                    : (failure == nil ? .updated : .failed)
                return WebInteractionControlOutcome(result: result, failure: failure)
            }
            guard !enabled else {
                return WebInteractionControlOutcome(result: .needsPermissions(missing), failure: nil)
            }
        }
        do { try persistAndPublish(enabled) }
        catch {
            return WebInteractionControlOutcome(result: .failed,
                failure: .persistence(error, runtimeWasForcedOff: false))
        }
        applyRuntime(enabled)
        if enabled {
            let missing = permissionService.missingPermissions
            if !missing.isEmpty {
                let failure = revoke(persistAndPublish: persistAndPublish, forcePublish: forcePublish)
                return WebInteractionControlOutcome(result: .needsPermissions(missing), failure: failure)
            }
        }
        return WebInteractionControlOutcome(result: .updated, failure: nil)
    }

    func requestPermission(_ permission: WebInteractionPermission) -> WebInteractionControlFailure? {
        guard !isShuttingDown else { return .shuttingDown }
        permissionService.request(permission)
        do { try permissionService.openSettings(for: permission); return nil }
        catch { return .settings(error) }
    }

    func refresh(currentEnabled: Bool, persistAndPublish: (Bool) throws -> Void,
                 forcePublish: (Bool) -> Void) -> WebInteractionControlFailure? {
        guard !isShuttingDown else { return nil }
        let failure = currentEnabled && !permissionService.missingPermissions.isEmpty
            ? revoke(persistAndPublish: persistAndPublish, forcePublish: forcePublish) : nil
        refreshRuntimeStatus()
        return failure
    }

    func restore(currentEnabled: Bool, persistAndPublish: (Bool) throws -> Void,
                 forcePublish: (Bool) -> Void) -> WebInteractionControlFailure? {
        guard !isShuttingDown, currentEnabled else { return nil }
        if permissionService.missingPermissions.isEmpty {
            applyRuntime(true)
            refreshRuntimeStatus()
            return nil
        }
        return revoke(persistAndPublish: persistAndPublish, forcePublish: forcePublish)
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    func disableRuntime() {
        guard !isShuttingDown else { return }
        applyRuntime(false)
    }

    private func revoke(persistAndPublish: (Bool) throws -> Void,
                        forcePublish: (Bool) -> Void) -> WebInteractionControlFailure? {
        applyRuntime(false)
        forcePublish(false)
        do { try persistAndPublish(false); return nil }
        catch { return .persistence(error, runtimeWasForcedOff: true) }
    }

    private func applyRuntime(_ enabled: Bool) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        setRuntimeEnabled(enabled)
        guard enabled else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else { return }
                self.onPoll?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }
}
