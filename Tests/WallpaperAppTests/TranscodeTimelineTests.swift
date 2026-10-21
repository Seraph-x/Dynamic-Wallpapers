import XCTest
import WallpaperCore
@testable import WallpaperApp

final class TranscodeTimelineTests: XCTestCase {
    func testSelectedPacketSpanIgnoresOtherTracksAndHandlesPresentationReordering() throws {
        let scanner = TranscodePacketTimeline(media: try media())
        scanner.accept("stream_index=5|pts_time=0|duration_time=10")
        scanner.accept("stream_index=2|pts_time=0.08|duration_time=0.04")
        scanner.accept("stream_index=2|pts_time=0|duration_time=0.04")
        scanner.accept("stream_index=3|pts_time=-0.02|duration_time=0.02")
        let timeline = try scanner.finish()
        XCTAssertEqual(timeline.duration, 0.14, accuracy: 0.000001)
        XCTAssertEqual(timeline.maxAudioPacketDuration, 0.02)
        XCTAssertEqual(timeline.video.duration, 0.12, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(timeline.audio).duration, 0.02)
    }

    func testMissingOrInvalidSelectedPacketsCannotInventDuration() throws {
        for line in ["stream_index=2|pts_time=N/A|duration_time=0.04", "stream_index=2|pts_time=0|duration_time=0"] {
            let scanner = TranscodePacketTimeline(media: try media())
            scanner.accept(line)
            XCTAssertThrowsError(try scanner.finish())
        }
        XCTAssertThrowsError(try TranscodePacketTimeline(media: media()).finish())
    }

    private func media() throws -> TranscodeMedia {
        try TranscodeMedia(json: Data("""
        {"streams":[{"index":2,"codec_type":"video","codec_name":"h264","width":320,"height":180,"avg_frame_rate":"25/1","time_base":"1/1000"},{"index":3,"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"10"}}
        """.utf8))
    }
}
