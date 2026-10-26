import Combine
import CoreFoundation
import Foundation
import WallpaperCore
import WallpaperAudioSpectrum

/// Application-scoped capture demand; only acknowledged, playing preview pages join.
@MainActor final class EditorPreviewAudioController: ObservableObject {
    static let preferenceKey = "editorPreviewSystemAudioSpectrumEnabled"
    @Published private(set) var enabled = false
    @Published private(set) var status: SystemAudioSpectrumStatus
    @Published private(set) var failure: Error?
    @Published private(set) var shuttingDown = false
    let supported: Bool
    private let controller: SystemAudioSpectrumController
    private let defaults: UserDefaults
    private var preferenceFailure: Error?
    private var captureStatus: SystemAudioSpectrumStatus
    private var captureFailure: Error?
    private var observations: Set<AnyCancellable> = []
    private struct Subscriber {
        let identity = UUID()
        let deliver: (AudioSpectrum) throws -> Void
        let onFailure: (Error) -> Void
    }
    private var subscribers: [UUID: Subscriber] = [:]

    init(controller: SystemAudioSpectrumController? = nil, defaults: UserDefaults = .standard) {
        let controller = controller ?? SystemAudioSpectrumController()
        self.controller = controller; self.defaults = defaults; supported = controller.supported
        status = controller.status; captureStatus = controller.status
        controller.$status.sink { [weak self] value in self?.captureStatus = value; self?.refresh() }.store(in: &observations)
        controller.$failure.sink { [weak self] value in self?.captureFailure = value; self?.refresh() }.store(in: &observations)
        controller.onSpectrum = { [weak self] value in self?.publish(value) }
        readPreference()
    }

    private func readPreference() {
        guard let value = defaults.object(forKey: Self.preferenceKey) else {
            enabled = false; preferenceFailure = nil; controller.setEnabled(false); refresh(); return
        }
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let boolean = value as? Bool else {
            preferenceFailure = WallpaperError("Invalid Editor system-audio preference: expected a Boolean (\(Self.preferenceKey)).")
            enabled = false; refresh(); return
        }
        enabled = boolean; preferenceFailure = nil; controller.setEnabled(boolean); refresh()
    }
    private func refresh() {
        failure = preferenceFailure ?? captureFailure
        status = !supported ? .unsupported : preferenceFailure != nil ? .failed : captureStatus
    }
    func setEnabled(_ value: Bool) {
        guard !shuttingDown else { return }
        defaults.set(value, forKey: Self.preferenceKey)
        preferenceFailure = nil; enabled = value; controller.setEnabled(value); refresh()
    }
    func retry() {
        guard !shuttingDown else { return }
        if preferenceFailure != nil { readPreference() }
        else { controller.retry() }
    }
    func settled() async { await controller.settled() }

    func addSubscriber(id: UUID, deliver: @escaping (AudioSpectrum) throws -> Void, onFailure: @escaping (Error) -> Void) {
        guard !shuttingDown else { return }
        removeSubscriber(id: id)
        let subscriber = Subscriber(deliver: deliver, onFailure: onFailure)
        subscribers[id] = subscriber
        deliverValue(.zero, id: id, subscriber: subscriber)
        if subscribers[id]?.identity == subscriber.identity { controller.setPlaying(id, true) }
    }
    @discardableResult func removeSubscriber(id: UUID) -> Error? {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return nil }
        controller.setPlaying(id, false)
        do { try subscriber.deliver(.zero); return nil }
        catch { subscriber.onFailure(error); return error }
    }
    private func publish(_ value: AudioSpectrum) {
        // Delivery may synchronously retire a session; iterate a stable snapshot.
        for (id, subscriber) in subscribers { deliverValue(value, id: id, subscriber: subscriber) }
    }
    private func deliverValue(_ value: AudioSpectrum, id: UUID, subscriber: Subscriber) {
        guard subscribers[id]?.identity == subscriber.identity else { return }
        do { try subscriber.deliver(value) }
        catch {
            subscribers[id] = nil; controller.setPlaying(id, false)
            var deliveryFailure: Error = error
            if value != .zero {
                do { try subscriber.deliver(.zero) }
                catch { deliveryFailure = WallpaperErrorGroup([deliveryFailure, error]) }
            }
            subscriber.onFailure(deliveryFailure)
        }
    }
    func cancelShutdown() {
        controller.cancelShutdown(); shuttingDown = false
    }
    func shutdown() async throws {
        shuttingDown = true
        for id in Array(subscribers.keys) { removeSubscriber(id: id) }
        // A failed release remains owned and another quit attempt retries this call.
        try await controller.shutdown()
    }
}
