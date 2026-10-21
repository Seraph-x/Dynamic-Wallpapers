import AppKit
import WallpaperCore
import WallpaperNative

/// Owns native output slots only; scheduling and snapshot ownership belong to the session.
@MainActor
public final class ScreenSaverRenderer {
    public typealias SurfaceFactory = @MainActor (CGSize, ContentFit) -> any PlaybackSurface
    let view: NSView
    private let makeSurface: SurfaceFactory
    private var surfaces: [UUID: any PlaybackSurface] = [:]
    private var current: UUID?
    private var revoked = false
    var onError: ((Error) -> Void)?

    public init(view: NSView, makeSurface: @escaping SurfaceFactory = { MediaSurface(size: $0, fit: $1) }) {
        self.view = view; self.makeSurface = makeSurface
    }

    func show(item: MediaItem, entry: PlaylistEntry, fit: ContentFit, audio: ScreenSaverAudioPolicy,
              transition: Double) async throws {
        try checkActive()
        let id = UUID()
        let next = makeSurface(view.bounds.size, fit)
        surfaces[id] = next
        next.setAudioSuppressed(true)
        next.setGlobalMute(audio.isSuppressed)
        next.setAudio(entry.audio)
        next.onError = { [weak self] error in self?.onError?(error) }
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.width, .height]
        next.view.alphaValue = 0
        view.addSubview(next.view)
        try await next.prepare(item: item, scale: view.window?.backingScaleFactor ?? 1, fit: fit)
        try checkActive()
        let oldID = current
        let old = oldID.flatMap { surfaces[$0] }
        next.setTransitionGain(old == nil ? 1 : 0)
        next.setAudioSuppressed(false)
        next.play()
        try await SharedTransition.run(duration: old == nil ? 0 : transition) { progress in
            next.view.alphaValue = progress; next.setTransitionGain(progress)
            old?.view.alphaValue = 1 - progress; old?.setTransitionGain(1 - progress)
        }
        try checkActive()
        current = id
        if let oldID, let old {
            old.setAudioSuppressed(true); old.pause(); old.view.removeFromSuperview()
            try await old.close()
            surfaces.removeValue(forKey: oldID)
        }
        try checkActive()
    }

    /// Must be called synchronously from stopAnimation before awaiting any resource work.
    func revoke() {
        revoked = true
        for surface in surfaces.values {
            surface.setAudioSuppressed(true)
            surface.pause()
            surface.view.removeFromSuperview()
        }
    }

    func close() async throws {
        revoke()
        var errors: [Error] = []
        // A failed native close keeps its slot and therefore the session's reader lease.
        for (id, surface) in surfaces {
            do { try await surface.close(); surfaces.removeValue(forKey: id) }
            catch { errors.append(error) }
        }
        if !errors.isEmpty { throw WallpaperErrorGroup(errors) }
        current = nil
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if revoked { throw CancellationError() }
    }
}
