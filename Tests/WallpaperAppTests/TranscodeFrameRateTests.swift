import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class TranscodeFrameRateTests: XCTestCase {
    func testLowFixedRatesKeepAllFramesIncludingMillisecondTimebase() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        for rate in ["24000/1001", "30000/1001", "30"] {
            for container in ["mp4", "mkv"] {
                let name = rate.replacingOccurrences(of: "/", with: "-") + "-" + container
                let source = directory.appendingPathComponent(name + "." + container)
                try await TranscodeTestFixtures.ffmpeg([
                    "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=\(rate):duration=2",
                    "-c:v", "h264_videotoolbox", "-allow_sw", "0", "-an", source.path
                ])
                let media = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
                let request = try TranscodeRequest(source: source,
                    destination: directory.appendingPathComponent(name + "-output.mp4"),
                    plan: TranscodePlan(media: media, preset: .hd1080))
                let output = try await FFmpegJob.run(request: request, tools: TranscodeTestFixtures.tools) { _ in }
                let inputFrames = try await TranscodeTestFixtures.frameTimes(source)
                let frames = try await TranscodeTestFixtures.frameTimes(output)
                XCTAssertEqual(frames.count, inputFrames.count, name)
                for (actual, expected) in zip(frames, inputFrames) {
                    XCTAssertEqual(actual, expected, accuracy: 0.000002, name)
                }
                print("Fixed-rate product \(name): input=\(inputFrames.count) output=\(frames.count)")
            }
        }
    }

    func testVFRLowAverageCapsHighSegmentWithoutDuplicatingLowSegment() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let source = directory.appendingPathComponent("variable.mp4")
        try await TranscodeTestFixtures.ffmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=60:duration=2",
            "-vf", "setpts='if(lt(N,60),N,60+(N-60)*6)'", "-fps_mode:v", "passthrough",
            "-c:v", "h264_videotoolbox", "-allow_sw", "0", "-an", source.path
        ])
        let tools = TranscodeTestFixtures.tools
        let media = try await FFmpegJob.inspect(source: source, tools: tools)
        let inputFrames = try await TranscodeTestFixtures.frameTimes(source)
        XCTAssertLessThan(media.frameRate, 30)
        XCTAssertEqual(inputFrames.count, 120)
        XCTAssertEqual(inputFrames.filter { $0 < 1 }.count, 60)
        for preset in TranscodePreset.allCases {
            let request = try TranscodeRequest(source: source,
                destination: directory.appendingPathComponent("\(preset.rawValue).mp4"),
                plan: TranscodePlan(media: media, preset: preset))
            let output = try await FFmpegJob.run(request: request, tools: tools) { _ in }
            let frames = try await TranscodeTestFixtures.frameTimes(output)
            let expected = inputFrames.enumerated().filter {
                preset == .original || $0.element >= 1 || $0.offset.isMultiple(of: 2)
            }.map(\.element)
            XCTAssertEqual(frames.count, expected.count, preset.rawValue)
            XCTAssertEqual(frames.filter { $0 >= 1 }.count, 60, "No low-rate duplication: \(preset)")
            for (actual, expected) in zip(frames, expected) {
                XCTAssertEqual(actual, expected, accuracy: 0.000002, preset.rawValue)
            }
            let actual = try await FFmpegJob.inspect(source: output, tools: tools)
            XCTAssertEqual(actual.duration, media.duration, accuracy: 0.02)
            print("VFR product \(preset.rawValue): input=\(inputFrames.count) output=\(frames.count) high=\(frames.filter { $0 < 1 }.count) low=\(frames.filter { $0 >= 1 }.count) duration=\(actual.duration)")
        }
    }
}
