import Foundation
import OSLog

public struct ScreenSaverPowerState: Equatable, Sendable {
    public var lidClosed: Bool
    public var displaySleeping: Bool
    public var systemSleeping: Bool
    public init(lidClosed: Bool = false, displaySleeping: Bool = false, systemSleeping: Bool = false) {
        self.lidClosed = lidClosed
        self.displaySleeping = displaySleeping
        self.systemSleeping = systemSleeping
    }
    public var preventsPlayback: Bool { lidClosed || displaySleeping || systemSleeping }
}

@MainActor
public protocol ScreenSaverPowerObserving: AnyObject {
    var onChange: ((ScreenSaverPowerState) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start() throws -> ScreenSaverPowerState
    func stop()
}

@MainActor
public final class ScreenSaverPlaybackLifecycle {
    private static let logger = Logger(subsystem: "local.dynamicwallpaper.screensaver", category: "power")
    public var onError: ((Error) -> Void)?
    public var onStart: ((ScreenSaverSessionStart) -> Void)?
    private let session: ScreenSaverSession
    private let power: any ScreenSaverPowerObserving
    private var hostRequested = false
    private var failed = false
    private var state = ScreenSaverPowerState()
    private var releaseID: UUID?

    public init(session: ScreenSaverSession, power: any ScreenSaverPowerObserving) {
        self.session = session
        self.power = power
    }

    public func start() {
        guard !hostRequested else { return }
        hostRequested = true
        let retryRelease = failed
        failed = false
        if retryRelease { _ = releasePlayback() }
        power.onChange = { [weak self] state in self?.receive(state) }
        power.onError = { [weak self] error in self?.observationFailed(error) }
        do {
            state = try power.start()
            logPowerState()
            resumeIfReady()
        } catch { observationFailed(error) }
    }

    @discardableResult
    public func stop() -> Task<Void, Error> {
        hostRequested = false
        power.stop()
        power.onChange = nil
        power.onError = nil
        return releasePlayback()
    }

    private func receive(_ state: ScreenSaverPowerState) {
        let changed = self.state != state
        self.state = state
        if changed { logPowerState() }
        if state.preventsPlayback {
            if !failed, releaseID == nil { _ = releasePlayback() }
        } else { resumeIfReady() }
    }

    private func resumeIfReady() {
        guard hostRequested, !failed, !state.preventsPlayback, releaseID == nil else { return }
        let start = session.start()
        onStart?(start)
    }

    private func observationFailed(_ error: Error) {
        failed = true
        hostRequested = false
        power.stop()
        power.onChange = nil
        power.onError = nil
        _ = releasePlayback()
        Self.logger.error("Power observation failed: \(error.localizedDescription, privacy: .public)")
        onError?(error)
    }

    private func logPowerState() {
        Self.logger.notice("lidClosed=\(self.state.lidClosed) displaySleeping=\(self.state.displaySleeping) systemSleeping=\(self.state.systemSleeping) hostRequested=\(self.hostRequested)")
    }

    /// stop() revokes audio/video synchronously. Resume must wait for the native
    /// close and directory lease barrier, even if wake arrives in the meantime.
    private func releasePlayback() -> Task<Void, Error> {
        let id = UUID()
        releaseID = id
        let barrier = session.stop()
        Task { @MainActor [weak self] in
            let result = await barrier.result
            guard let self, self.releaseID == id else { return }
            self.releaseID = nil
            switch result {
            case .success: self.resumeIfReady()
            case .failure(let error):
                self.failed = true
                self.onError?(error)
            }
        }
        return barrier
    }
}
