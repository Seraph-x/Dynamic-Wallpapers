import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class TranscodeJobTests: XCTestCase {
    private var tools: TranscodeTools {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/dependencies/ffmpeg/install/bin")
        return TranscodeTools(directory: root)
    }
    private var source: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
    }
    func testRealEncodeProbeAndExclusivePublish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let original = try Data(contentsOf: source)
        let media = try await FFmpegJob.inspect(source: source, tools: tools)
        let request = try TranscodeRequest(source: source, destination: directory.appendingPathComponent("输出 ' ;.mp4"),
                                          plan: TranscodePlan(media: media, preset: .original))
        var progress: [Double] = []
        let output = try await FFmpegJob.run(request: request, tools: tools) { progress.append($0) }
        XCTAssertEqual(output, request.destination)
        let result = try await FFmpegJob.inspect(source: output, tools: tools)
        XCTAssertEqual(result.videoCodec, "h264"); XCTAssertEqual(result.audioCodec, "aac")
        XCTAssertEqual(result.width, 320); XCTAssertEqual(result.height, 180)
        XCTAssertEqual(result.duration, media.duration, accuracy: 0.1)
        XCTAssertTrue(progress.contains { $0 > 0 })
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [output.lastPathComponent])
        let saved = try Data(contentsOf: output)
        do { _ = try await FFmpegJob.run(request: request, tools: tools) { _ in }; XCTFail("Must reject existing output") }
        catch { XCTAssertTrue(error.localizedDescription.contains("存在")) }
        XCTAssertEqual(try Data(contentsOf: output), saved)
    }
    func testTargetCreatedAfterEncodingStartsIsNeverOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let media = try await FFmpegJob.inspect(source: source, tools: tools)
        let output = directory.appendingPathComponent("race.mp4")
        let request = try TranscodeRequest(source: source, destination: output, plan: TranscodePlan(media: media, preset: .original))
        var created = false
        do {
            _ = try await FFmpegJob.run(request: request, tools: tools) { _ in
                if !created {
                    do { try Data("other writer".utf8).write(to: output, options: .withoutOverwriting); created = true }
                    catch { XCTFail("\(error)") }
                }
            }
            XCTFail("Concurrent target must win")
        } catch { XCTAssertTrue(error.localizedDescription.contains("未覆盖"), error.localizedDescription) }
        XCTAssertTrue(created)
        XCTAssertEqual(try Data(contentsOf: output), Data("other writer".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["race.mp4"])
    }
    func testPreCancelledJobDoesNotCreateOutputAndMissingToolIsExplicit() async throws {
        let media = try await FFmpegJob.inspect(source: source, tools: tools)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let request = try TranscodeRequest(source: source, destination: output, plan: TranscodePlan(media: media, preset: .original))
        let task = Task { try await FFmpegJob.run(request: request, tools: tools) { _ in } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must not succeed") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        do {
            _ = try await FFmpegJob.inspect(source: source, tools: TranscodeTools(directory: output))
            XCTFail("No PATH/Homebrew fallback")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
}
