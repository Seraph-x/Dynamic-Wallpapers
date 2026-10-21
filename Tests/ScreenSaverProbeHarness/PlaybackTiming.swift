import AppKit

@main
struct PlaybackTiming {
    @MainActor
    static func main() async {
        do { try await run() }
        catch { fputs("PLAYBACK TIMING FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor
    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw failure("Expected fixture directory.") }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        view.wantsLayer = true
        let playback = ProbePlayback(view: view) { _, _ in }
        try playback.start(directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        defer { playback.stop() }

        // Delay actual ImageIO decoding, not a mocked clock or synthetic ready callback.
        try await Task.sleep(for: .seconds(1.15))
        try playback.tick()
        guard playback.frameCounts == ["still.png": 1], view.layer?.contents != nil else {
            throw failure("A delayed first decoded frame was removed in its first tick.")
        }
        try await Task.sleep(for: .seconds(0.2))
        try playback.tick()
        guard playback.frameCounts == ["still.png": 1], view.layer?.contents != nil else {
            throw failure("The first frame did not receive its visible hold interval.")
        }
        try await Task.sleep(for: .seconds(0.9))
        try playback.tick()
        try playback.tick()
        guard playback.frameCounts["animated.gif", default: 0] > 0 else {
            throw failure("Playback did not advance after the visible hold interval.")
        }
        playback.stop()
        guard view.layer?.contents == nil else { throw failure("Stop left image output attached.") }
        print("{\"delayedFirstFrameHoldVerified\":true,\"systemHostVerified\":false}")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ScreenSaverPlaybackTiming", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
