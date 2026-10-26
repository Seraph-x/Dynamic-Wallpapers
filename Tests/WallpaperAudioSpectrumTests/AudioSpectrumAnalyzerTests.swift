import XCTest
@testable import WallpaperAudioSpectrum

final class AudioSpectrumAnalyzerTests: XCTestCase {
    private func tone(_ frequency: Double, amplitude: Float = 1, count: Int = 4096) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / 48000)) }
    }

    func testStereoTonesStayInTheirFrequencyBands() throws {
        let analyzer = try AudioSpectrumAnalyzer(sampleRate: 48000)
        let spectrum = try XCTUnwrap(analyzer.append(left: tone(1000), right: tone(4000)))
        let leftPeak = try XCTUnwrap(spectrum.left.indices.max { spectrum.left[$0] < spectrum.left[$1] })
        let rightPeak = try XCTUnwrap(spectrum.right.indices.max { spectrum.right[$0] < spectrum.right[$1] })
        XCTAssertEqual(leftPeak, analyzer.band(for: 1000))
        XCTAssertEqual(rightPeak, analyzer.band(for: 4000))
        XCTAssertGreaterThan(spectrum.left[leftPeak], 0.75)
        XCTAssertLessThan(spectrum.left[rightPeak], 0.01)
        XCTAssertLessThan(spectrum.right[leftPeak], 0.01)
        XCTAssertEqual(spectrum.left.count, 64)
        XCTAssertEqual(spectrum.right.count, 64)
    }

    func testHalfAmplitudeProducesHalfMagnitudeAndSilenceIsZero() throws {
        let full = try AudioSpectrumAnalyzer(sampleRate: 48000)
        let half = try AudioSpectrumAnalyzer(sampleRate: 48000)
        let a = try XCTUnwrap(full.append(left: tone(1000), right: tone(1000)))
        let b = try XCTUnwrap(half.append(left: tone(1000, amplitude: 0.5), right: tone(1000, amplitude: 0.5)))
        XCTAssertEqual(b.left.max()! / a.left.max()!, 0.5, accuracy: 0.001)
        let zero = [Float](repeating: 0, count: 4096)
        let silence = try XCTUnwrap(full.append(left: zero, right: zero))
        XCTAssertEqual(silence.left, [Float](repeating: 0, count: 64))
        XCTAssertEqual(silence.right, silence.left)
    }

    func testPartialPacketsEqualContiguousInput() throws {
        let a = try AudioSpectrumAnalyzer(sampleRate: 48000)
        let b = try AudioSpectrumAnalyzer(sampleRate: 48000)
        let samples = tone(2000)
        let expected = try a.append(left: samples, right: samples)
        XCTAssertNil(try b.append(left: Array(samples.prefix(500)), right: Array(samples.prefix(500))))
        let actual = try b.append(left: Array(samples.dropFirst(500)), right: Array(samples.dropFirst(500)))
        XCTAssertEqual(actual, expected)
    }

    func testInvalidInputIsExplicitAndCannotPoisonTheNextWindow() throws {
        XCTAssertThrowsError(try AudioSpectrumAnalyzer(sampleRate: 0))
        XCTAssertThrowsError(try AudioSpectrumAnalyzer(sampleRate: .nan))
        let analyzer = try AudioSpectrumAnalyzer(sampleRate: 48000)
        XCTAssertThrowsError(try analyzer.append(left: [0], right: []))
        XCTAssertThrowsError(try analyzer.append(left: [.nan], right: [0]))
        let zero = [Float](repeating: 0, count: 2048)
        XCTAssertEqual(try analyzer.append(left: zero, right: zero)?.left, [Float](repeating: 0, count: 64))
    }
}
