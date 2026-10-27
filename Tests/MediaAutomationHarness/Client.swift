import Foundation
import WallpaperCore
import WallpaperMediaIntegration

struct Failure: Error, CustomStringConvertible { let description: String }
func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }

@main
struct Client {
    static func main() async {
        let arguments = CommandLine.arguments
        let resultURL = arguments.firstIndex(of: "--result-file").map { URL(fileURLWithPath: arguments[$0 + 1]) }
        func record(_ status: String, error: String? = nil) throws {
            guard let resultURL else { return }
            var value: [String: Any] = ["status": status, "pid": ProcessInfo.processInfo.processIdentifier]
            if let error { value["error"] = error }
            try JSONSerialization.data(withJSONObject: value).write(to: resultURL, options: .atomic)
        }
        do {
            try record("running")
            try await run()
            try record("passed")
        } catch {
            fputs("MEDIA_AUTOMATION FAILED: \(error)\n", stderr)
            do { try record("failed", error: String(describing: error)) }
            catch { fputs("MEDIA_AUTOMATION result recording failed: \(error)\n", stderr) }
            exit(1)
        }
    }

    static func run() async throws {
        guard CommandLine.arguments.count >= 4, let pid = Int32(CommandLine.arguments[1]),
              let source = SystemMediaSource(rawValue: CommandLine.arguments[2]), source != .disabled else {
            throw Failure(description: "client needs owned fixture PID, music/spotify, directory")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let authorize = CommandLine.arguments.contains("--authorize-owned-fixture")
        let service = AppleEventMediaService(eventTimeout: 0.15, resolveProcess: { _ in pid })
        if CommandLine.arguments.contains("--expect-exited") {
            let value = try await service.read(source: source, requestAuthorization: false)
            try require(value == .applicationNotRunning, "Exited fixture must be unavailable: \(value)")
            print("MEDIA_AUTOMATION exited_process_pass source=\(source.rawValue)"); return
        }
        try setMode("normal", directory)
        let initial = try await service.read(source: source, requestAuthorization: authorize)
        let first = try current(initial)
        try require(first.trackID == "owned-0" && first.title == "Owned 雪 \"é🎵", "Metadata/Unicode mismatch")
        try require(first.source == source && first.position == 12.5 && first.duration == 180.25, "Provider/timeline units mismatch")
        try require(first.albumArtist == (source == .music ? "Owned Ensemble" : nil), "Album artist semantics mismatch")
        try await service.perform(.pause, source: source)
        try require(try current(await service.read(source: source, requestAuthorization: false)).state == .paused, "Pause did not reach owned process")
        try await service.perform(.play, source: source)
        try require(try current(await service.read(source: source, requestAuthorization: false)).state == .playing, "Play did not reach owned process")
        try await service.perform(.playPause, source: source)
        try require(try current(await service.read(source: source, requestAuthorization: false)).state == .paused, "Toggle did not reach owned process")
        try await service.perform(.skipNext, source: source)
        try require(try current(await service.read(source: source, requestAuthorization: false)).trackID == "owned-1", "Next did not reach owned process")
        try await service.perform(.skipPrevious, source: source)
        try require(try current(await service.read(source: source, requestAuthorization: false)).trackID == "owned-0", "Previous did not reach owned process")
        let receipts = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("receipts.json"))) as? [String]
        try require(receipts == ["Paus", "Play", "PlPs", "Next", "Prev"], "Actual event receipt order mismatch")
        try setMode("missing", directory)
        let missing = try await service.read(source: source, requestAuthorization: false)
        try require(missing == .noCurrentItem, "Missing item must be explicit")
        for mode in ["malformed", "error", "track-change", "timeout"] {
            try setMode(mode, directory)
            do {
                _ = try await service.read(source: source, requestAuthorization: false)
                throw Failure(description: "Expected actual \(mode) failure")
            } catch let error as SystemMediaError {
                switch (mode, error) {
                case ("malformed", .invalidResponse), ("error", .appleEvent(code: -50, message: _)),
                     ("track-change", .trackChangedDuringRead), ("timeout", .appleEvent(code: -1712, message: _)): break
                default: throw Failure(description: "Wrong \(mode) error: \(error)")
                }
            }
            if mode == "timeout" { try await Task.sleep(for: .milliseconds(600)) }
        }
        try setMode("transport-error", directory)
        do { try await service.perform(.pause, source: source); throw Failure(description: "Expected actual transport failure") }
        catch let error as SystemMediaError {
            guard case .appleEvent(code: -1708, message: _) = error else { throw error }
        }
        print("MEDIA_AUTOMATION PASS source=\(source.rawValue) metadata=real-AppleEvents controls=5 malformed/error/track-change/timeout/transport-error=observed")
    }

    static func setMode(_ value: String, _ directory: URL) throws {
        try value.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }
    static func current(_ result: SystemMediaReadResult) throws -> SystemMediaSnapshot {
        guard case .current(let value) = result else { throw Failure(description: "Expected actual owned fixture snapshot, received \(result)") }
        return value
    }
}
