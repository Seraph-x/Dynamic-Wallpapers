import AppKit
import MPVBridge
import XCTest
@testable import WallpaperApp

@MainActor
final class MPVBridgeContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    private var fixture: URL {
        repositoryRoot.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
    }

    func testFirstFrameCarriesActualDecodedFrameProvenance() async throws {
        let outcome = await firstOutcome(at: fixture)
        let metadata = try XCTUnwrap(outcome).get()
        let flags = try XCTUnwrap(metadata["firstDecodedFrameFlags"] as? NSNumber).uint64Value
        XCTAssertNotEqual(flags & 1, 0, "The initial decoded frame must have PRESENT set.")
        XCTAssertEqual(flags & (2 | 4), 0, "REDRAW and REPEAT are not proof of an initial decoded frame.")
        XCTAssertEqual(metadata["hardwareDecoder"] as? String, "videotoolbox-copy",
                       "Pinned H.264 fixture must use actual VideoToolbox decoding on this host")
    }

    func testRenderingAndSynchronousCoreCommandsUseIndependentQueues() async throws {
        let outcome = await firstOutcome(at: fixture)
        let metadata = try XCTUnwrap(outcome).get()
        let renderQueue = metadata["renderQueueLabel"] as? String
        let controlQueue = metadata["controlQueueLabel"] as? String
        XCTAssertNotNil(renderQueue, "Record the actual queue executing render API calls.")
        XCTAssertNotNil(controlQueue, "Record the actual queue executing synchronous core API calls.")
        XCTAssertNotEqual(renderQueue, controlQueue, "The renderer must not wait behind synchronous core calls.")
    }

    func testBridgeRejectsAnActualMOVContainerDisguisedAsMKV() async throws {
        let original = try await VideoIntegrationTests.makeVideo()
        let disguised = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mkv")
        defer {
            for url in [original, disguised] {
                do { try FileManager.default.removeItem(at: url) }
                catch { XCTFail(error.localizedDescription) }
            }
        }
        try FileManager.default.copyItem(at: original, to: disguised)
        let result = await firstOutcome(at: disguised)
        let outcome = try XCTUnwrap(result)
        switch outcome {
        case .success: XCTFail("The native bridge must enforce its actual container whitelist, not just trust the path.")
        case .failure(let error): XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testCloseFromFrameCallbackStopsFurtherCallbacksAndRemainsIdempotent() async throws {
        let bridge = DWMPVBridge(width: 64, height: 64, fill: false)
        let closed = expectation(description: "native resources closed from callback")
        var closeRequested = false
        var frameCount = 0
        bridge.startPath(fixture.path, frame: { _, _ in
            frameCount += 1
            guard !closeRequested else { XCTFail("Frame arrived after close was requested"); return }
            closeRequested = true
            bridge.close { closed.fulfill() }
        }, failure: { error in
            XCTFail(error.localizedDescription)
            if !closeRequested {
                closeRequested = true
                bridge.close { closed.fulfill() }
            }
        })
        await fulfillment(of: [closed], timeout: 10)
        XCTAssertEqual(frameCount, 1)
        XCTAssertThrowsError(try bridge.setMuted(true, volume: 0))
        XCTAssertThrowsError(try bridge.setPaused(false))
        await close(bridge)
        XCTAssertEqual(frameCount, 1)
    }

    func testARealVideoWithoutAnAudioTrackPrepares() async throws {
        let url = try remux(stream: "0:v:0")
        defer { remove(url) }
        let outcome = await firstOutcome(at: url)
        let metadata = try XCTUnwrap(outcome).get()
        XCTAssertEqual(metadata["width"] as? Int, 320)
        XCTAssertEqual(metadata["height"] as? Int, 180)
    }

    func testAnAudioOnlyContainerFailsExplicitlyBeforeWaitingForVideo() async throws {
        let url = try remux(stream: "0:a:0")
        defer { remove(url) }
        let result = await firstOutcome(at: url)
        switch try XCTUnwrap(result) {
        case .success: XCTFail("Audio-only Matroska is not an extended video.")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("video track"), error.localizedDescription)
        }
    }

    func testRealRenderDimensionFailureStillAllowsSynchronousMuteAndClose() async throws {
        let source = fixture.deletingLastPathComponent().appendingPathComponent("vp9-opus.webm")
        let url = try remux(stream: "0:v:0", source: source, extra: ["-aspect", "255:1", "-write_crc32", "0"])
        defer { remove(url) }
        try setExtremeMatroskaAspect(url)
        // First inspect through the real renderer in fit mode, where this costs at most 64 x 64 pixels.
        let first = await firstOutcome(at: url)
        let metadata = try XCTUnwrap(first).get()
        let width = try XCTUnwrap(metadata["width"] as? NSNumber).doubleValue
        let height = try XCTUnwrap(metadata["height"] as? NSNumber).doubleValue
        let aspect = width / height
        guard aspect > 1_000 else { XCTFail("Fixture did not retain its extreme display aspect: \(aspect)"); return }
        let renderHeight = Int(ceil(Double(Int32.max) / aspect)) + 1
        let bridge = DWMPVBridge(width: 1, height: renderHeight, fill: true)
        let closed = expectation(description: "real render error followed by synchronous mute and close")
        var requestedClose = false
        var renderError: Error?
        bridge.startPath(url.path, frame: { _, _ in
            XCTFail("Overflowing render width must not publish a frame.")
            if !requestedClose { requestedClose = true; bridge.close { closed.fulfill() } }
        }, failure: { error in
            renderError = error
            do { try bridge.setMuted(true, volume: 0); try bridge.setPaused(true) }
            catch { XCTFail("Control after render failure: \(error.localizedDescription)") }
            if !requestedClose { requestedClose = true; bridge.close { closed.fulfill() } }
        })
        await fulfillment(of: [closed], timeout: 10)
        XCTAssertTrue(try XCTUnwrap(renderError).localizedDescription.contains("Invalid render dimensions"))
        await close(bridge)
    }

    private func remux(stream: String, source: URL? = nil, extra: [String] = []) throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mkv")
        let process = Process(), errors = Pipe()
        process.executableURL = repositoryRoot.appendingPathComponent(".build/dependencies/ffmpeg/install/bin/ffmpeg")
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-protocol_whitelist", "file",
                             "-i", (source ?? fixture).path, "-map", stream, "-c", "copy"] + extra + ["-n", output.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            if FileManager.default.fileExists(atPath: output.path) { remove(output) }
            throw NSError(domain: "MPVBridgeContractTests.Fixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: diagnostic, as: UTF8.self)])
        }
        return output
    }

    private func setExtremeMatroskaAspect(_ url: URL) throws {
        // FFmpeg CLI limits -aspect to 255:1. Replace only same-size, CRC-free Video metadata:
        // DisplayWidth 255 -> 10,000,000; the optional colour-range element becomes a Void.
        // Parent sizes, media bytes and seek offsets stay unchanged.
        let original = Data([0x54, 0xb0, 0x81, 0xff, 0x54, 0xba, 0x81, 1, 0x54, 0xb2, 0x81, 3,
                             0x55, 0xb0, 0x84, 0x55, 0xb9, 0x81, 1])
        let replacement = Data([0x54, 0xb0, 0x84, 0, 0x98, 0x96, 0x80, 0x54, 0xba, 0x81, 1,
                                0x54, 0xb2, 0x81, 3, 0xec, 0x82, 0, 0])
        var data = try Data(contentsOf: url)
        let range = try XCTUnwrap(data.range(of: original), "Pinned Matroska metadata layout changed")
        data.replaceSubrange(range, with: replacement)
        try data.write(to: url)
    }

    private func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { XCTFail(error.localizedDescription) }
    }

    private func firstOutcome(at url: URL) async -> Result<[String: Any], Error>? {
        let bridge = DWMPVBridge(width: 64, height: 64, fill: false)
        let ready = expectation(description: "decoded first frame or explicit failure")
        var outcome: Result<[String: Any], Error>?
        bridge.startPath(url.path, frame: { _, metadata in
            guard outcome == nil else { return }
            outcome = .success(metadata)
            ready.fulfill()
        }, failure: { error in
            guard outcome == nil else { return }
            outcome = .failure(error)
            ready.fulfill()
        })
        await fulfillment(of: [ready], timeout: 10)
        await close(bridge)
        return outcome
    }

    private func close(_ bridge: DWMPVBridge) async {
        await withCheckedContinuation { continuation in
            bridge.close { continuation.resume() }
        }
    }
}
