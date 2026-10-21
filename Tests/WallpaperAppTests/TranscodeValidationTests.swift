import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class TranscodeValidationTests: XCTestCase {
    func testOneShortTrackCannotHideBehindTheOtherCompleteTrack() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let source = TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
        let expected = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
        for (flag, filter, track) in [("-vf", "trim=duration=0.5", "视频"), ("-af", "atrim=duration=0.5", "音频")] {
            let output = directory.appendingPathComponent(flag + ".mp4")
            try await TranscodeTestFixtures.ffmpeg([
                "-i", source.path, flag, filter,
                "-c:v", "h264_videotoolbox", "-allow_sw", "0", "-c:a", "aac", output.path
            ])
            let actual = try await FFmpegJob.inspect(source: output, tools: TranscodeTestFixtures.tools)
            XCTAssertGreaterThan(actual.duration, 1.8, "The aggregate duration still looks complete")
            XCTAssertThrowsError(try FFmpegJob.validateOutput(actual, plan: TranscodePlan(media: expected, preset: .original))) {
                XCTAssertTrue($0.localizedDescription.contains(track), $0.localizedDescription)
            }
        }
    }

    func testRelativeAudioShiftCannotHideInsideLongerVideoSpan() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let original = TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
        let source = directory.appendingPathComponent("short-audio.mp4")
        try await TranscodeTestFixtures.ffmpeg([
            "-i", original.path, "-af", "atrim=duration=0.8", "-c:v", "copy", "-c:a", "aac", source.path
        ])
        let shifted = directory.appendingPathComponent("shifted.mp4")
        try await TranscodeTestFixtures.ffmpeg([
            "-i", source.path, "-af", "asetpts=PTS+0.3/TB", "-c:v", "copy", "-c:a", "aac", shifted.path
        ])
        let expected = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
        let actual = try await FFmpegJob.inspect(source: shifted, tools: TranscodeTestFixtures.tools)
        XCTAssertEqual(actual.duration, expected.duration, accuracy: 0.05)
        XCTAssertThrowsError(try FFmpegJob.validateOutput(actual, plan: TranscodePlan(media: expected, preset: .original))) {
            XCTAssertTrue($0.localizedDescription.contains("相对起点"), $0.localizedDescription)
        }
    }

    func testOutputValidationRejectsShortenedButOtherwiseValidMP4() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let source = TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
        let short = directory.appendingPathComponent("short.mp4")
        try await TranscodeTestFixtures.ffmpeg([
            "-i", source.path, "-t", "0.5", "-c:v", "h264_videotoolbox", "-allow_sw", "0", "-c:a", "aac", short.path
        ])
        let expected = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
        let actual = try await FFmpegJob.inspect(source: short, tools: TranscodeTestFixtures.tools)
        XCTAssertEqual(actual.videoCodec, "h264"); XCTAssertEqual(actual.audioCodec, "aac")
        XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
        XCTAssertLessThan(actual.duration, 0.7)
        XCTAssertThrowsError(try FFmpegJob.validateOutput(actual, plan: TranscodePlan(media: expected, preset: .original))) {
            XCTAssertTrue($0.localizedDescription.contains("时长"), $0.localizedDescription)
        }
    }

    func testDiagnosticCopyFailureKeepsOriginalReadableLog() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let original = TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
        let source = directory.appendingPathComponent("truncated.mkv")
        try Data(contentsOf: original).prefix(37_431).write(to: source)
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocked)
        let tools = TranscodeTools(directory: TranscodeTestFixtures.tools.directory, diagnosticsDirectory: blocked)
        do {
            let media = try await FFmpegJob.inspect(source: source, tools: tools)
            let request = try TranscodeRequest(source: source, destination: directory.appendingPathComponent("output.mp4"),
                                              plan: TranscodePlan(media: media, preset: .original))
            _ = try await FFmpegJob.run(request: request, tools: tools) { _ in }
            XCTFail("Truncated input must fail")
        } catch {
            let message = error.localizedDescription
            let logLine = message.split(separator: "\n").first { $0.hasPrefix("file://") }
            XCTAssertNotNil(logLine, "Diagnostic-copy failure must identify a retained original log: \(message)")
            if let logLine, let log = URL(string: String(logLine)) {
                XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("File ended prematurely"))
                // The deliberately retained diagnostic belongs only to this test.
                if !log.path.hasPrefix(directory.path + "/") {
                    try FileManager.default.removeItem(at: log.deletingLastPathComponent())
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("output.mp4").path))
        XCTAssertEqual(try Data(contentsOf: blocked), Data("keep".utf8))
    }

    func testChangedSourceCannotUseStaleDimensionsAndPublish() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let source = directory.appendingPathComponent("source.mkv")
        try await TranscodeTestFixtures.ffmpeg([
            "-f", "lavfi", "-i", "color=c=red:size=160x90:rate=24:duration=1", "-c:v", "ffv1", source.path
        ])
        let media = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
        let request = try TranscodeRequest(source: source, destination: directory.appendingPathComponent("output.mp4"),
                                          plan: TranscodePlan(media: media, preset: .original))
        let replacement = TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
        try Data(contentsOf: replacement).write(to: source, options: .atomic)
        let replacedBytes = try Data(contentsOf: source)
        do {
            _ = try await FFmpegJob.run(request: request, tools: TranscodeTestFixtures.tools) { _ in }
            XCTFail("Changed input must not be silently stretched using a stale plan")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.destination.path))
        XCTAssertEqual(try Data(contentsOf: source), replacedBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.mkv"])
    }

    func testTruncatedMediaWithSuccessfulToolExitCannotPublishPartialOutput() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let original = TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
        let source = directory.appendingPathComponent("truncated.mkv")
        let bytes = try Data(contentsOf: original).prefix(37_431) // Complete EBML blocks; header still declares 2.021 s.
        try bytes.write(to: source)
        let destination = directory.appendingPathComponent("output.mp4")
        do {
            let media = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
            let request = try TranscodeRequest(source: source, destination: destination,
                                              plan: TranscodePlan(media: media, preset: .original))
            let output = try await FFmpegJob.run(request: request, tools: TranscodeTestFixtures.tools) { _ in }
            let actual = try await FFmpegJob.inspect(source: output, tools: TranscodeTestFixtures.tools)
            print("Truncated product: declared=\(media.duration), published=\(actual.duration)")
            XCTFail("A zero tool exit cannot turn a truncated decode into success")
        } catch { print("Truncated product rejected: \(error.localizedDescription)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), Data(bytes))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["truncated.mkv"])
    }
}
