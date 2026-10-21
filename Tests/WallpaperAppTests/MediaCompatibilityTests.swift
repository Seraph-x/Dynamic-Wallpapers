import AppKit
import AVFoundation
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class MediaCompatibilityTests: XCTestCase {
    func testRealFFV1IncompatibleNativeFixtureExposesAnActualAVFoundationDiagnostic() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Compatibility fixture cleanup failed: \(error)") }
        }
        let source = directory.appendingPathComponent("unsupported-codec.mov")
        try await TranscodeTestFixtures.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10",
            "-t", "0.5", "-c:v", "ffv1", "-strict", "experimental", source.path])
        let item = MediaItem(url: source, kind: .video, width: 64, height: 64)
        do {
            _ = try await MediaThumbnail.load(item)
            XCTFail("The actual native decoder must reject this fixture, not a mocked compatibility result")
        } catch {
            let diagnostic = error as NSError
            print("Real native compatibility diagnostic: \(diagnostic)")
            XCTAssertEqual(diagnostic.domain, AVFoundationErrorDomain)
        }
        let tracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .video)
        let decodable = try await XCTUnwrap(tracks.first).load(.isDecodable)
        print("Real native video track isDecodable: \(decodable)")
        XCTAssertFalse(decodable)
        let media = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
        XCTAssertEqual(media.videoCodec, "ffv1")
        XCTAssertEqual(media.width, 64)
        let inspection = try await MediaCompatibility.inspect(item)
        XCTAssertNotNil(inspection.transcodeReason, "Actual incompatibility plus full decode must enable the suggestion")
        XCTAssertNil(inspection.image)
    }

    func testHealthyNativeAndExtendedVideosDoNotNeedTranscoding() async throws {
        let nativeURL = try await VideoIntegrationTests.makeVideo()
        defer {
            do { try FileManager.default.removeItem(at: nativeURL) }
            catch { XCTFail("Native fixture cleanup failed: \(error)") }
        }
        let native = try await MediaProbe.inspect(nativeURL)
        let extended = MediaItem(url: TranscodeTestFixtures.root
            .appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv"),
            kind: .video, width: 320, height: 180, backend: .extended)
        for item in [native, extended] {
            let result = try await MediaCompatibility.inspect(item, validateTranscode: { _ in
                XCTFail("A healthy source must not run a transcoding probe")
            })
            XCTAssertNotNil(result.image)
            XCTAssertNil(result.transcodeReason)
        }
    }

    func testDisabledUnsupportedTrackDoesNotMisclassifyTheEnabledPlayableTrack() async throws {
        let directory = try TranscodeTestFixtures.directory()
        let generated = try await VideoIntegrationTests.makeVideo()
        defer {
            do { try FileManager.default.removeItem(at: directory); try FileManager.default.removeItem(at: generated) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }
        let source = directory.appendingPathComponent("disabled-ffv1-enabled-h264.mov")
        try await TranscodeTestFixtures.ffmpeg(["-i", generated.path, "-map", "0:v", "-map", "0:v",
            "-c:v:0", "ffv1", "-c:v:1", "copy", "-disposition:v:0", "0", "-disposition:v:1", "default",
            "-strict", "experimental", source.path])
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 2)
        let firstEnabled = try await tracks[0].load(.isEnabled)
        let secondEnabled = try await tracks[1].load(.isEnabled)
        XCTAssertFalse(firstEnabled)
        XCTAssertTrue(secondEnabled)
        let actual = try await AVAssetImageGenerator(asset: asset).image(at: .zero).image
        XCTAssertEqual(actual.width, 64, "The real native thumbnail path is playable")
        let item = MediaItem(url: source, kind: .video, width: 64, height: 64)
        let result = try await MediaCompatibility.inspect(item)
        XCTAssertNotNil(result.image)
        XCTAssertNil(result.transcodeReason, "A disabled codec is not the wallpaper's playback incompatibility")
    }

    func testMissingAndCorruptMediaAreErrorsNotRecommendations() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }
        for name in ["missing.mov", "corrupt.mp4"] {
            let url = directory.appendingPathComponent(name)
            if name == "corrupt.mp4" { try Data("not a video".utf8).write(to: url) }
            do {
                _ = try await MediaCompatibility.inspect(MediaItem(url: url, kind: .video, width: 64, height: 64))
                XCTFail("Unusable files cannot produce a recommendation or a success state")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    func testDiagnosticClassificationUsesStructuredBackendSpecificEvidence() {
        let unknown = NSError(domain: "DynamicWallpaper.MPV", code: -17)
        XCTAssertNotNil(MediaCompatibility.reason(for: unknown, backend: .extended))
        XCTAssertNil(MediaCompatibility.reason(for: unknown, backend: .native))
        let missingDecoder = NSError(domain: AVFoundationErrorDomain, code: AVError.decoderNotFound.rawValue)
        XCTAssertNotNil(MediaCompatibility.reason(for: missingDecoder, backend: .native))
        XCTAssertNil(MediaCompatibility.reason(for: missingDecoder, backend: .extended))
        let wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: missingDecoder])
        XCTAssertNotNil(MediaCompatibility.reason(for: wrapped, backend: .native))
        let errors = [
            NSError(domain: "DynamicWallpaper.MPV", code: -20),
            NSError(domain: "DynamicWallpaper.MPV", code: -13),
            NSError(domain: "DynamicWallpaper.MPV", code: -18),
            NSError(domain: AVFoundationErrorDomain, code: AVError.decoderTemporarilyUnavailable.rawValue),
            NSError(domain: AVFoundationErrorDomain, code: AVError.contentIsProtected.rawValue),
            NSError(domain: AVFoundationErrorDomain, code: AVError.decodeFailed.rawValue),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            NSError(domain: "unknown", code: -17, userInfo: [NSLocalizedDescriptionKey: "decoder not found"])
        ]
        for error in errors {
            XCTAssertNil(MediaCompatibility.reason(for: error, backend: .native), "\(error)")
            XCTAssertNil(MediaCompatibility.reason(for: error, backend: .extended), "\(error)")
        }
    }

    func testKnownIncompatibilityStillRequiresSuccessfulTranscodeValidation() async throws {
        let source = try await VideoIntegrationTests.makeVideo()
        defer {
            do { try FileManager.default.removeItem(at: source) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }
        let item = try await MediaProbe.inspect(source)
        var validated = false
        do {
            _ = try await MediaCompatibility.inspect(item, thumbnail: { _ in
                throw NSError(domain: AVFoundationErrorDomain, code: AVError.decoderNotFound.rawValue)
            }, validateTranscode: { _ in
                validated = true
                throw WallpaperError("transcoder cannot decode this input")
            })
            XCTFail("A diagnostic alone is not a transcode recommendation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("transcoder cannot decode this input")) }
        XCTAssertTrue(validated)
    }

    func testSourceReplacementDuringDiagnosisRejectsStaleRecommendation() async throws {
        let source = try await VideoIntegrationTests.makeVideo()
        defer {
            do { try FileManager.default.removeItem(at: source) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }
        let item = try await MediaProbe.inspect(source)
        do {
            _ = try await MediaCompatibility.inspect(item, thumbnail: { _ in
                try Data("changed".utf8).write(to: source, options: .atomic)
                throw NSError(domain: AVFoundationErrorDomain, code: AVError.decoderNotFound.rawValue)
            }, validateTranscode: { _ in XCTFail("Do not assess a replacement using an old decode failure") })
            XCTFail("Stale diagnosis must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("发生变化")) }
    }
}
