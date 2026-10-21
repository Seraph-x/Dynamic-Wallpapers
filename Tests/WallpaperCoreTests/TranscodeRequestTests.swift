import XCTest
@testable import WallpaperCore

final class TranscodeRequestTests: XCTestCase {
    private func probe(width: Int = 1920, height: Int = 1080, fps: String = "24000/1001",
                       rotation: Int = 0, audio: Bool = true, sar: String = "1:1") throws -> TranscodeMedia {
        let audioJSON = audio ? ",{\"index\":3,\"codec_type\":\"audio\",\"codec_name\":\"opus\"}" : ""
        return try TranscodeMedia(json: Data("""
        {"streams":[
          {"index":0,"codec_type":"video","codec_name":"mjpeg","width":600,"height":600,"disposition":{"attached_pic":1}},
          {"index":2,"codec_type":"video","codec_name":"h264","width":\(width),"height":\(height),"avg_frame_rate":"\(fps)","sample_aspect_ratio":"\(sar)","side_data_list":[{"rotation":\(rotation)}]}
          \(audioJSON)],"format":{"duration":"4.0","format_name":"matroska,webm"}}
        """.utf8))
    }
    func testSelectsFirstNonCoverVideoAndFirstAudioByStreamIndex() throws {
        let media = try probe()
        XCTAssertEqual(media.videoIndex, 2)
        XCTAssertEqual(media.audioIndex, 3)
        XCTAssertEqual(media.duration, 4)
    }
    func testOriginalKeepsFractionalFrameRateAndNoAudioIsValid() throws {
        let request = try TranscodePlan(media: probe(audio: false), preset: .original)
        XCTAssertEqual(request.width, 1920); XCTAssertEqual(request.height, 1080)
        XCTAssertNil(request.frameRateLimit)
        XCTAssertNil(request.media.audioIndex)
    }
    func testHDDoesNotUpscaleOrIncreaseLowFrameRate() throws {
        let plan = try TranscodePlan(media: probe(width: 640, height: 360, fps: "24/1"), preset: .hd1080)
        XCTAssertEqual(plan.width, 640); XCTAssertEqual(plan.height, 360)
        XCTAssertEqual(plan.frameRateLimit, 30, "Low average rate does not exclude a high-rate VFR segment")
        let arguments = try plan.arguments(source: URL(fileURLWithPath: "/tmp/input.mkv"),
                                          stagedOutput: URL(fileURLWithPath: "/tmp/output.mp4"))
        XCTAssertFalse(arguments.contains("-fpsmax"), "fpsmax would select CFR and duplicate low-rate frames")
        XCTAssertFalse(arguments.contains("-r"))
    }
    func testHDHighRateAndPortraitFitInsideTargetRectangle() throws {
        let plan = try TranscodePlan(media: probe(width: 3840, height: 2160, fps: "60000/1001", rotation: 90), preset: .hd1080)
        XCTAssertEqual(plan.width, 606); XCTAssertEqual(plan.height, 1080)
        XCTAssertEqual(plan.frameRateLimit, 30)
    }
    func testOriginalPadsOddDimensionsWithoutCropping() throws {
        let plan = try TranscodePlan(media: probe(width: 641, height: 359), preset: .original)
        XCTAssertEqual(plan.width, 642); XCTAssertEqual(plan.height, 360)
        XCTAssertTrue(plan.videoFilter.contains("pad=642:360"))
    }
    func testAnamorphicDisplayGeometryIsPreserved() throws {
        let plan = try TranscodePlan(media: probe(width: 720, height: 576, sar: "16:15"), preset: .original)
        XCTAssertEqual(plan.width, 768); XCTAssertEqual(plan.height, 576)
        XCTAssertTrue(plan.videoFilter.contains("setsar=1"))
    }
    func testRejectsUnusableMetadataRatherThanInventingDefaults() throws {
        for fps in ["0/0", "N/A", "1/0", "-1/1", "nan"] {
            XCTAssertThrowsError(try probe(fps: fps), fps)
        }
        XCTAssertThrowsError(try probe(width: 0))
        XCTAssertThrowsError(try probe(rotation: 45))
        XCTAssertThrowsError(try probe(sar: "0:1"))
        XCTAssertThrowsError(try TranscodeMedia(json: Data("{\"streams\":[],\"format\":{\"duration\":\"4\"}}".utf8)))
    }
    func testArgumentsUseLocalExplicitStreamsAndNoShellOrAudioGain() throws {
        let plan = try TranscodePlan(media: probe(), preset: .original)
        let source = URL(fileURLWithPath: "/tmp/源 ' ; $(false).mkv")
        let target = URL(fileURLWithPath: "/tmp/输出 ' ;.mp4")
        let arguments = try plan.arguments(source: source, stagedOutput: target)
        XCTAssertTrue(arguments.contains(source.path)); XCTAssertTrue(arguments.contains(target.path))
        XCTAssertTrue(arguments.contains("0:2")); XCTAssertTrue(arguments.contains("0:3"))
        XCTAssertTrue(arguments.contains("h264_videotoolbox")); XCTAssertTrue(arguments.contains("aac"))
        XCTAssertTrue(arguments.contains("-n")); XCTAssertFalse(arguments.contains("-y"))
        XCTAssertFalse(arguments.contains("-af")); XCTAssertFalse(arguments.contains("-re"))
        XCTAssertThrowsError(try plan.arguments(source: URL(string: "https://example.test/input.mkv")!, stagedOutput: target))
        XCTAssertThrowsError(try plan.arguments(source: source, stagedOutput: source))
    }
}
