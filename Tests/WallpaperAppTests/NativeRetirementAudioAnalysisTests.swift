import XCTest

final class NativeRetirementAudioAnalysisTests: XCTestCase {
    private let window = NativeRetirementAudioWindow(name: "closed", start: 10, end: 10.75, expectsSilence: true)

    func testCoveredSilencePassesAndReportsEarlierTail() throws {
        var packets = samples()
        packets[2] = sample(start: 10.04, energy: 0.5, lastNonzero: 10.059)
        let report = try window.analyze(packets)
        XCTAssertEqual(report.stableRMS, 0)
        XCTAssertEqual(try XCTUnwrap(report.lastNonzeroOffset), 0.059, accuracy: 0.000001)
        XCTAssertGreaterThan(report.stablePackets, 10)
    }

    func testMissingPacketsOrWindowEdgesCannotCountAsSilence() {
        XCTAssertThrowsError(try window.analyze([]))
        XCTAssertThrowsError(try window.analyze(Array(samples().suffix(11))))
        XCTAssertThrowsError(try window.analyze(Array(samples().prefix(26))))
        XCTAssertThrowsError(try window.analyze(Array(samples().prefix(5))))
    }

    func testOneNonzeroStableSampleRejectsOldAudio() {
        var packets = samples()
        packets[25] = sample(start: 10.5, energy: 1e-12, lastNonzero: 10.519)
        XCTAssertThrowsError(try window.analyze(packets)) { error in
            XCTAssertTrue(error.localizedDescription.contains("旧声音"))
        }
    }

    func testPositiveControlCannotBeSatisfiedBySilentCapture() throws {
        let playing = NativeRetirementAudioWindow(name: "playing", start: 10, end: 10.75, expectsSilence: false)
        XCTAssertThrowsError(try playing.analyze(samples()))
        XCTAssertGreaterThan(try playing.analyze(samples(energy: 2)).stableRMS, 0.0001)
    }

    func testInvalidPacketEnergyCannotBecomeSuccessfulSilence() {
        var packets = samples()
        packets[20] = sample(start: 10.4, energy: .nan)
        XCTAssertThrowsError(try window.analyze(packets))
    }

    private func samples(energy: Double = 0) -> [SystemAudioEvidence.Packet] {
        (0..<37).map { sample(start: 10 + Double($0) * 0.02, energy: energy) }
    }
    private func sample(start: Double, energy: Double = 0, lastNonzero: Double? = nil) -> SystemAudioEvidence.Packet {
        .init(start: start, end: start + 0.02, callbackHost: start + 0.08,
              energy: energy, samples: 1920, lastNonzero: lastNonzero)
    }
}
