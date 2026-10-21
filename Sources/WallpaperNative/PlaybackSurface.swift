import AppKit
import WallpaperCore

/// Backend state is observable independently of the playlist's paused clock.
/// A backend which must tear down on pause remains `pausing` until teardown completes.
public enum PlaybackSurfaceState: Equatable {
    case idle, preparing, ready, playing, pausing, paused, closing, closed, failed
}

@MainActor
public protocol PlaybackSurface: AnyObject, Sendable {
    var view: NSView { get }
    var state: PlaybackSurfaceState { get }
    /// Includes asynchronous teardown performed by pause, before host close().
    var releaseFailure: Error? { get }
    var onError: ((Error) -> Void)? { get set }
    /// Returns only after a real displayable frame is committed to `view`, always silent.
    func prepare(item: MediaItem, scale: CGFloat, fit: ContentFit) async throws
    /// Playback intent; asynchronous pause backends expose progress through `state`.
    func play()
    func pause()
    /// Prepare the paused display for a group commit without enabling output.
    func prepareToResume() async throws
    /// Revoke a prepared resume, retaining the paused frame until resources stop.
    func cancelResumePreparation() async throws
    func setAudio(_ value: AudioSettings)
    /// Runtime linear amplitude weight, independent of persisted entry settings.
    func setTransitionGain(_ value: Double)
    func setGlobalMute(_ value: Bool)
    /// Must gate audio synchronously, before any asynchronous release work.
    func setAudioSuppressed(_ value: Bool)
    /// Completes only once all backend activity and output have stopped. A failure
    /// must throw; the host retains its resource slot until successful completion.
    /// Invalidated prepare/draw callbacks must not recreate resources after close.
    func close() async throws
}

public extension PlaybackSurface {
    // Synchronous pause backends do not release resources until close().
    var releaseFailure: Error? { nil }
}
