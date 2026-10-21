import Darwin
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class TranscodeCancellationTests: XCTestCase {
    func testCancellationReapsActualRunningChildAndBothPipes() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let signalReceipt = directory.appendingPathComponent("received-signal.txt")
        let state = CancellationObservation()
        let task = Task {
            try await TranscodeProcess().run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
            import os, pathlib, signal, sys, time
            def terminated(number, frame):
                pathlib.Path(sys.argv[1]).write_text(f'{number}:{os.getpid()}')
                sys.exit(128 + number)
            signal.signal(signal.SIGTERM, terminated)
            print(os.getpid(), flush=True)
            time.sleep(1)
            """, signalReceipt.path]) { line in
                Task { @MainActor in
                    state.pid = pid_t(line)
                    if let child = state.pid {
                        XCTAssertEqual(kill(child, 0), 0, "Child must be alive when cancellation is requested")
                    }
                    state.cancel?()
                }
            }
        }
        state.cancel = { task.cancel() }
        defer { task.cancel() }
        do { _ = try await task.value; XCTFail("Running cancellation must throw") }
        catch is CancellationError { }
        let pid = try XCTUnwrap(state.pid)
        let probeResult = kill(pid, 0), probeError = errno
        XCTAssertEqual(probeResult, -1)
        XCTAssertEqual(probeError, ESRCH, "Child must be reaped before cancellation returns")
        let receipt = try String(contentsOf: signalReceipt, encoding: .utf8)
        XCTAssertEqual(receipt, "\(SIGTERM):\(pid)",
                       "Natural exit after cancellation does not prove SIGTERM was delivered")
        print("TranscodeProcess cancellation: pid=\(pid), signalReceipt=\(receipt), probeResult=\(probeResult), probeErrno=\(probeError)")
    }

    func testRunningFFmpegCancellationRemovesOnlyItsStagingFiles() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let source = directory.appendingPathComponent("long.mkv")
        try await TranscodeTestFixtures.ffmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=30", "-c:v", "ffv1", source.path
        ])
        let original = try Data(contentsOf: source)
        let marker = directory.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: marker)
        let media = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
        let request = try TranscodeRequest(source: source, destination: directory.appendingPathComponent("cancel.mp4"),
                                          plan: TranscodePlan(media: media, preset: .original))
        let state = CancellationObservation()
        let task = Task {
            try await FFmpegJob.run(request: request, tools: TranscodeTestFixtures.tools) { progress in
                guard state.pid == nil, progress > 0, progress < 1 else { return }
                do {
                    let pid = try self.runningFFmpegChild()
                    state.pid = pid
                    XCTAssertEqual(kill(pid, 0), 0)
                    print("FFmpeg live cancel: pid=\(pid), progress=\(progress)")
                    state.cancel?()
                } catch { XCTFail(error.localizedDescription); state.cancel?() }
            }
        }
        state.cancel = { task.cancel() }
        defer { task.cancel() }
        do { _ = try await task.value; XCTFail("Must cancel an actual encoder, not just a waiting job") }
        catch is CancellationError { }
        let child = try XCTUnwrap(state.pid)
        XCTAssertEqual(kill(child, 0), -1); XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.destination.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["long.mkv", "unrelated.txt"])
    }

    private func runningFFmpegChild() throws -> pid_t {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(getpid()), "-x", "ffmpeg"]
        process.standardOutput = pipe
        try process.run()
        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        try pipe.fileHandleForReading.close()
        let ids = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard process.terminationStatus == 0, ids.count == 1, let pid = pid_t(ids[0]) else {
            throw WallpaperError("Expected exactly one running ffmpeg child of this XCTest process: \(ids)")
        }
        return pid
    }
}

@MainActor
private final class CancellationObservation {
    var pid: pid_t?
    var cancel: (() -> Void)?
}
