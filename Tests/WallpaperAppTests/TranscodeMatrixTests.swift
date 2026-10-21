@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class TranscodeMatrixTests: XCTestCase {
    func testNativeAndAllThreeExtendedContainersTranscodeWithBothPresets() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let native = try await VideoIntegrationTests.makeVideo()
        defer { do { try FileManager.default.removeItem(at: native) } catch { XCTFail("\(error)") } }
        let m4v = directory.appendingPathComponent("native.m4v")
        try await TranscodeTestFixtures.ffmpeg(["-i", native.path, "-c", "copy", "-f", "ipod", m4v.path])
        let fixtures = TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures")
        let inputs = ["h264-aac.mkv", "vp9-opus.webm", "mpeg4-mp3.avi"].map { fixtures.appendingPathComponent($0) } + [native, m4v]
        for source in inputs {
            let bytes = try Data(contentsOf: source)
            let media = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
            for preset in TranscodePreset.allCases {
                let request = try TranscodeRequest(source: source,
                    destination: directory.appendingPathComponent(source.lastPathComponent + "-" + preset.rawValue + ".mp4"),
                    plan: TranscodePlan(media: media, preset: preset))
                let output = try await FFmpegJob.run(request: request, tools: TranscodeTestFixtures.tools) { _ in }
                let actual = try await FFmpegJob.inspect(source: output, tools: TranscodeTestFixtures.tools)
                XCTAssertEqual(actual.videoCodec, "h264")
                XCTAssertEqual(actual.audioCodec, media.audioIndex == nil ? nil : "aac")
                XCTAssertEqual([actual.width, actual.height], [request.plan.width, request.plan.height])
                XCTAssertEqual(try Data(contentsOf: source), bytes)
                try await verifyNativeFirstFrame(output)
                print("Transcode containers \(source.pathExtension) \(preset.rawValue): \(actual.width)x\(actual.height), native-frame=ready")
            }
        }
    }

    func testUnselectedLongAudioTrackDoesNotDistortSelectedOutputDuration() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let source = directory.appendingPathComponent("multiple-tracks.mkv")
        try await TranscodeTestFixtures.ffmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=3",
            "-map", "0:v", "-map", "1:a", "-map", "2:a",
            "-c:v", "h264_videotoolbox", "-allow_sw", "0", "-c:a", "aac", source.path
        ])
        let media = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
        XCTAssertLessThan(media.duration, 1.2, "Progress and output checks must use selected tracks, not the 3 s excluded audio")
        let request = try TranscodeRequest(source: source, destination: directory.appendingPathComponent("selected.mp4"),
                                          plan: TranscodePlan(media: media, preset: .original))
        let output = try await FFmpegJob.run(request: request, tools: TranscodeTestFixtures.tools) { _ in }
        let actual = try await FFmpegJob.inspect(source: output, tools: TranscodeTestFixtures.tools)
        XCTAssertLessThan(actual.duration, 1.2)
        XCTAssertEqual(actual.audioIndex, 1)
        try await verifyNativeFirstFrame(output)
    }

    func testNoAudioOddDimensionsRotationAndAnamorphicOutputsDecodeNatively() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let odd = directory.appendingPathComponent("odd.mkv")
        try await TranscodeTestFixtures.ffmpeg([
            "-f", "lavfi", "-i", "testsrc=size=641x359:rate=24:duration=1",
            "-c:v", "ffv1", "-pix_fmt", "yuv444p", odd.path
        ])
        let anamorphic = directory.appendingPathComponent("anamorphic.mkv")
        try await TranscodeTestFixtures.ffmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=720x576:rate=24:duration=1",
            "-vf", "setsar=16/15", "-c:v", "ffv1", anamorphic.path
        ])
        let base = directory.appendingPathComponent("base.mp4")
        try await TranscodeTestFixtures.ffmpeg([
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=1",
            "-c:v", "h264_videotoolbox", "-allow_sw", "0", base.path
        ])
        let rotated = directory.appendingPathComponent("rotated.mp4")
        try await TranscodeTestFixtures.ffmpeg(["-display_rotation", "90", "-i", base.path, "-c", "copy", rotated.path])
        for (source, originalSize, hdSize) in [
            (odd, [642, 360], [640, 358]), (anamorphic, [768, 576], [768, 576]), (rotated, [180, 320], [180, 320])
        ] {
            let original = try Data(contentsOf: source)
            let media = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
            for preset in TranscodePreset.allCases {
                let request = try TranscodeRequest(source: source,
                    destination: directory.appendingPathComponent(source.lastPathComponent + "-" + preset.rawValue + ".mp4"),
                    plan: TranscodePlan(media: media, preset: preset))
                let output = try await FFmpegJob.run(request: request, tools: TranscodeTestFixtures.tools) { _ in }
                let actual = try await FFmpegJob.inspect(source: output, tools: TranscodeTestFixtures.tools)
                let expected = preset == .original ? originalSize : hdSize
                XCTAssertEqual([actual.width, actual.height], expected, source.lastPathComponent)
                XCTAssertEqual(actual.rotation, 0); XCTAssertEqual(actual.sampleAspectRatio, 1)
                XCTAssertEqual(actual.videoCodec, "h264"); XCTAssertNil(actual.audioIndex)
                XCTAssertEqual(actual.duration, media.duration, accuracy: 0.05)
                XCTAssertEqual(try Data(contentsOf: source), original)
                try await verifyNativeFirstFrame(output)
                print("Transcode matrix \(source.lastPathComponent) \(preset.rawValue): \(actual.width)x\(actual.height), audio=none, rotation=0, native-frame=ready")
            }
        }
    }

    private func verifyNativeFirstFrame(_ output: URL) async throws {
        _ = NSApplication.shared
        let item = try await MediaProbe.inspect(output)
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 160, height: 90),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = MediaSurface(size: CGSize(width: 160, height: 90), fit: .fit)
        surface.setAudioSuppressed(true)
        window.contentView = surface; window.orderBack(nil)
        defer { surface.dispose(); window.contentView = nil; window.close() }
        try await surface.prepare(item: item, scale: 1, fit: .fit, timeout: 3)
        XCTAssertFalse(surface.isPlaying)
        try await surface.close()
    }
}
