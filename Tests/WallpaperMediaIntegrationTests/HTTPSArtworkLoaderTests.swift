import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration

final class HTTPSArtworkLoaderTests: XCTestCase {
    func testActualTLSRequestsRedirectsErrorsCertificatesTimeoutAndCancellation() async throws {
        let fixture = ArtworkImageDecoderTests.fixtureURL.deletingLastPathComponent().deletingLastPathComponent()
        let root = fixture.deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".build/verification/public-media/tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [fixture.appendingPathComponent("https-artwork-server.py").path, directory.path]
        let log = directory.appendingPathComponent("server.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let output = try FileHandle(forWritingTo: log)
        server.standardOutput = output; server.standardError = output
        try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit(); output.closeFile() }
        let ready = directory.appendingPathComponent("server.json")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard server.isRunning, ContinuousClock.now < deadline else { return XCTFail("Owned TLS fixture startup failed: \(log.path)") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: String])
        let base = try XCTUnwrap(info["url"])
        let anchor = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(info["ca"])))
        let loader = HTTPSArtworkLoader(timeout: 3, testTrust: ArtworkTestTrust(anchorDER: anchor, hostname: "localhost"))
        let identity = ArtworkImageDecoderTests.identity
        func source(_ path: String) throws -> SystemMediaArtworkSource { .remote(try SystemMediaArtworkURL(base + path)) }
        for path in ["/image", "/redirect", "/image"] {
            let artifact = try await loader.load(source(path), for: identity)
            XCTAssertEqual(artifact.width, 2); XCTAssertEqual(artifact.height, 1)
            XCTAssertEqual(try ArtworkImageDecoderTests.pixels(artifact.pngData), [255, 0, 0, 255, 0, 0, 255, 255])
        }
        for path in ["/redirect-http", "/redirect-credentials"] {
            do { _ = try await loader.load(source(path), for: identity); XCTFail("Expected rejected redirect") }
            catch { guard case SystemMediaArtworkError.invalidURL = error else { return XCTFail("Unexpected redirect error: \(error)") } }
        }
        do { _ = try await loader.load(source("/error"), for: identity); XCTFail("Expected HTTP failure") }
        catch { XCTAssertEqual(error as? SystemMediaArtworkError, .httpStatus(503)) }
        do { _ = try await loader.load(source("/invalid"), for: identity); XCTFail("Expected image failure") }
        catch { guard case SystemMediaArtworkError.invalidImage = error else { return XCTFail("Unexpected decode error: \(error)") } }
        for (candidate, url) in [
            (HTTPSArtworkLoader(timeout: 3), base + "/image"),
            (loader, base.replacingOccurrences(of: "localhost", with: "127.0.0.1") + "/image"),
        ] {
            do { _ = try await candidate.load(.remote(SystemMediaArtworkURL(url)), for: identity); XCTFail("Expected trust failure") }
            catch { guard case SystemMediaArtworkError.network = error else { return XCTFail("Unexpected TLS error: \(error)") } }
        }
        let timeout = HTTPSArtworkLoader(timeout: 0.1, testTrust: ArtworkTestTrust(anchorDER: anchor, hostname: "localhost"))
        do { _ = try await timeout.load(source("/slow"), for: identity); XCTFail("Expected timeout") }
        catch { guard case SystemMediaArtworkError.network(code: NSURLErrorTimedOut, message: _) = error else { return XCTFail("Unexpected timeout: \(error)") } }
        let task = Task { try await loader.load(source("/slow"), for: identity) }
        try await Task.sleep(for: .milliseconds(40)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected cancellation: \(error)") }
        let requests = try String(contentsOf: directory.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertFalse(requests.contains("cookie=owned="), "Ephemeral artwork requests must not retain cookies")
        XCTAssertFalse(requests.contains("/image cookie=user"))
    }
}
