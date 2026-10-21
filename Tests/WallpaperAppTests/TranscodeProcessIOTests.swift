import XCTest
@testable import WallpaperApp

@MainActor
final class TranscodeProcessIOTests: XCTestCase {
    func testPipeFailureAggregationRetainsBothFailedResources() {
        let first = WeakTranscodeWitness(), second = WeakTranscodeWitness()
        var result: Error?
        do {
            let a = TranscodeResourceWitness(), b = TranscodeResourceWitness()
            first.value = a; second.value = b
            let errors = [
                TranscodeCleanupFailure(operation: "stdout", cleanup: NSError(domain: "first", code: 1), resource: a),
                TranscodeCleanupFailure(operation: "stderr", cleanup: NSError(domain: "second", code: 2), resource: b)
            ]
            do { try TranscodeProcess.requirePipeSuccess(errors); XCTFail("Both release failures must be reported") }
            catch { result = error }
        }
        withExtendedLifetime(result) {
            XCTAssertNotNil(first.value)
            XCTAssertNotNil(second.value, "Aggregating only the second error's text loses its handle")
            XCTAssertTrue(result?.localizedDescription.contains("stdout") == true)
            XCTAssertTrue(result?.localizedDescription.contains("stderr") == true)
        }
    }

    func testStreamsFullDiagnosticsWithoutRetainingProgressOrLongStderrInMemory() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let log = directory.appendingPathComponent("stderr.log")
        let lines = LineCounter()
        let result = try await TranscodeProcess().run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", #"""
            import os
            for i in range(32):
                os.write(1, b'out_time_us=1000\n')
                os.write(2, b'x' * 65536)
            os.write(1, b'progress=end\n')
            """#], captureStandardOutput: false, errorLog: log, onLine: { _ in lines.count += 1 })
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(lines.count, 33)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertEqual(result.stderrByteCount, 2_097_152)
        XCTAssertEqual(try Data(contentsOf: log), Data(repeating: 120, count: 2_097_152))
    }
}

/// Written only by the stdout reader; observed after the process and readers join.
private final class LineCounter: @unchecked Sendable { var count = 0 }

/// Identity-only witness; it contains no mutable state to race across cleanup boundaries.
final class TranscodeResourceWitness: Sendable { }
final class WeakTranscodeWitness { weak var value: TranscodeResourceWitness? }
