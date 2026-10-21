import XCTest

final class PulseTimingAnalysisTests: XCTestCase {
    func testReportsObservedOffsetAndSamplingBracketWithoutDeclaringSynchronization() throws {
        let video = [sample(0, 0), sample(0.50, 0), sample(0.53, 1), sample(0.60, 0)]
        let audio = [sample(0, 0), sample(0.54, 0), sample(0.541, 0.1), sample(0.64, 0)]
        let report = try PulseTimingAnalysis.compare(video: video, audio: audio, sourceOffsets: [0.002])
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report[0].audioMinusVideo, 0.009, accuracy: 0.000001)
        XCTAssertEqual(report[0].lowerBound, 0.008, accuracy: 0.000001)
        XCTAssertEqual(report[0].upperBound, 0.039, accuracy: 0.000001)
    }

    func testAnAudioDelayIsMeasuredRatherThanNormalizedAway() throws {
        let video = [sample(0.49, 0), sample(0.50, 1), sample(0.60, 0)]
        let audio = [sample(0.749, 0), sample(0.75, 0.1), sample(0.85, 0)]
        let report = try PulseTimingAnalysis.compare(video: video, audio: audio, sourceOffsets: [0])
        XCTAssertEqual(report[0].audioMinusVideo, 0.25, accuracy: 0.000001)
    }

    func testMissingOrExtraPulsesCannotBePairedIntoSuccess() {
        let video = [sample(0, 0), sample(0.50, 1), sample(0.60, 0)]
        XCTAssertThrowsError(try PulseTimingAnalysis.compare(video: video, audio: [], sourceOffsets: [0]))
        XCTAssertThrowsError(try PulseTimingAnalysis.compare(video: video, audio: video, sourceOffsets: [0, 0]))
        XCTAssertThrowsError(try PulseTimingAnalysis.compare(video: video, audio: video, sourceOffsets: []))
    }

    func testRejectsInvalidOrOutOfOrderMeasurements() {
        for invalid in [[sample(.nan, 0)], [sample(0, .infinity)],
                        [sample(1, 0), sample(0.5, 1)], [sample(0, 0), sample(0, 1)]] {
            XCTAssertThrowsError(try PulseTimingAnalysis.risingEdges(invalid, low: 0.1, high: 0.8))
        }
    }

    func testDoesNotInventAnOnsetWhenCaptureStartsDuringPulse() throws {
        let samples = [sample(1, 1), sample(1.1, 0), sample(1.5, 1), sample(1.6, 0)]
        let edges = try PulseTimingAnalysis.risingEdges(samples, low: 0.1, high: 0.8)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].upperBound, 1.5)
    }

    func testEqualCountReplacementCannotBeDescribedAsVerifiedPulseIdentity() throws {
        let video = [sample(0.49, 0), sample(0.50, 1), sample(0.53, 0), sample(0.55, 1),
                     sample(0.60, 0), sample(2.20, 1), sample(2.30, 0)]
        let audio = video.map { PulseSample(time: $0.time + 0.001, value: $0.value) }
        let report = try PulseTimingAnalysis.compare(video: video, audio: audio, sourceOffsets: [0.001, 0.001, 0.001])
        XCTAssertTrue(report.allSatisfy { !$0.pulseIdentityVerified })
        XCTAssertTrue(report.allSatisfy { $0.association == "ordinal-count-only" })
        // Dropping the middle source pulse and adding another still gives zero ordinal offsets.
        // Such a report is NOT a synchronization acceptance result.
        for offset in report { XCTAssertEqual(offset.audioMinusVideo, 0, accuracy: 0.000001) }
    }

    func testSourceAudioBinsUseEveryFrameTimestampWithoutClosingAGap() throws {
        let samples = [Float](repeating: 0, count: 48) + [Float](repeating: 0.1, count: 48)
        let frames = [PulseTimingAnalysis.AudioFrame(time: 0, sampleCount: 48),
                      PulseTimingAnalysis.AudioFrame(time: 0.251, sampleCount: 48)]
        let bins = try PulseTimingAnalysis.audioBins(samples: samples, frames: frames)
        XCTAssertEqual(bins.count, 2)
        XCTAssertEqual(bins[1].time, 0.251, accuracy: 0.000001)
        XCTAssertEqual(bins[1].duration, 0.001, accuracy: 0.000001)
    }

    func testSourceAudioRejectsInvalidFrameTimelineAndSampleCount() {
        let samples = [Float](repeating: 0, count: 48)
        for frames in [[PulseTimingAnalysis.AudioFrame(time: .nan, sampleCount: 48)],
                       [.init(time: 0, sampleCount: 47)], [.init(time: 0, sampleCount: 49)],
                       [.init(time: 1, sampleCount: 24), .init(time: 0, sampleCount: 24)]] {
            XCTAssertThrowsError(try PulseTimingAnalysis.audioBins(samples: samples, frames: frames))
        }
    }

    func testAACFrameBinsPreserveQuantizedPTSWithoutCreatingDuplicateSampleTimes() throws {
        let frames = [PulseTimingAnalysis.AudioFrame(time: 0, sampleCount: 1024),
                      PulseTimingAnalysis.AudioFrame(time: 0.021, sampleCount: 1024)]
        let bins = try PulseTimingAnalysis.audioBins(samples: [Float](repeating: 0, count: 2048), frames: frames)
        XCTAssertNoThrow(try PulseTimingAnalysis.risingEdges(bins, low: 0.003, high: 0.015))
        XCTAssertTrue(bins.contains { $0.time == 0.021 }, "Keep the actual quantized next-frame timestamp")
    }

    private func sample(_ time: Double, _ value: Double) -> PulseSample {
        PulseSample(time: time, value: value)
    }
}
