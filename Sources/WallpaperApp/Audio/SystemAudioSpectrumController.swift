import Combine
import Foundation
import WallpaperCore

@MainActor
protocol SystemAudioCapturing: AnyObject {
    func start() async throws
    func snapshot() throws -> AudioSpectrum
    func stop() async throws
}

enum SystemAudioSpectrumStatus: Equatable {
    case unsupported, disabled, waiting, starting, capturing, failed
}

/// One shared capture owner. Playback changes never wait for an OS permission dialog.
@MainActor
final class SystemAudioSpectrumController: ObservableObject {
    nonisolated static var isSupported: Bool { if #available(macOS 14.2, *) { true } else { false } }
    let supported: Bool
    @Published private(set) var status: SystemAudioSpectrumStatus
    @Published private(set) var failure: Error?
    var onSpectrum: ((AudioSpectrum) -> Void)?
    private let makeCapture: @MainActor () throws -> any SystemAudioCapturing
    private var capture: (any SystemAudioCapturing)?
    private var subscribers = Set<UUID>()
    private var enabled = false
    private var shuttingDown = false
    private var releaseFailed = false
    private var restartRequested = false
    private var revision = 0
    private var transition: Task<Void, Never>?
    private var timer: Timer?

    init(supported: Bool = SystemAudioSpectrumController.isSupported,
         makeCapture: @escaping @MainActor () throws -> any SystemAudioCapturing = { @MainActor in
             if #available(macOS 14.2, *) { return CoreAudioSpectrumCapture() }
             throw WallpaperError("系统音频响应需要 macOS 14.2 或更新版本。")
         }) {
        self.supported = supported; self.makeCapture = makeCapture
        status = supported ? .disabled : .unsupported
    }

    func setEnabled(_ value: Bool) {
        guard !shuttingDown, enabled != value else { return }
        enabled = value; reconcile()
    }
    func setPlaying(_ id: UUID, _ value: Bool) {
        guard !shuttingDown else { return }
        let wasWanted = wantsCapture
        let changed = value ? subscribers.insert(id).inserted : subscribers.remove(id) != nil
        // A second subscriber does not invalidate the first subscriber's pending
        // permission/start operation. Only a change in capture demand does.
        if changed, wasWanted != wantsCapture { reconcile() }
    }
    func retry() {
        guard !shuttingDown, failure != nil else { return }
        failure = nil; releaseFailed = false; restartRequested = true
        reconcile()
    }
    func settled() async { await transition?.value }

    private var wantsCapture: Bool { supported && enabled && !subscribers.isEmpty && !shuttingDown && failure == nil }
    private func clear() { timer?.invalidate(); timer = nil; onSpectrum?(.zero) }

    private func reconcile() {
        revision += 1
        let request = revision, previous = transition
        if !wantsCapture { clear() }
        transition = Task { @MainActor [self] in
            await previous?.value
            guard request == revision, !releaseFailed else { return }
            do {
                if capture != nil, !wantsCapture || restartRequested { try await stopCapture() }
                restartRequested = false
                guard request == revision else { return }
                guard wantsCapture else { updateIdleStatus(); return }
                guard capture == nil else { return }
                let next = try makeCapture()
                capture = next; status = .starting
                try await next.start()
                guard request == revision, wantsCapture else { try await stopCapture(); return }
                status = .capturing
                timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publishLatest() }
                }
            } catch { await fail(error) }
        }
    }

    private func updateIdleStatus() {
        status = !supported ? .unsupported : failure != nil ? .failed : enabled && !shuttingDown ? .waiting : .disabled
    }
    private func stopCapture() async throws {
        clear()
        guard let capture else { return }
        do { try await capture.stop(); self.capture = nil; releaseFailed = false }
        catch { releaseFailed = true; throw error }
    }
    private func fail(_ error: Error) async {
        clear(); failure = error; status = .failed
        // An earlier failed release stays owned until explicit Retry or shutdown.
        guard !releaseFailed else { return }
        do { try await stopCapture() }
        catch { failure = WallpaperErrorGroup([self.failure!, error]) }
    }
    private func publishLatest() {
        guard wantsCapture, let capture else { return }
        do { onSpectrum?(try capture.snapshot()) }
        catch {
            clear(); failure = error; status = .failed
            reconcile()
        }
    }
    func shutdown() async throws {
        shuttingDown = true; revision += 1; clear()
        await transition?.value
        do { try await stopCapture(); updateIdleStatus() }
        catch { failure = error; status = .failed; throw error }
    }
}
