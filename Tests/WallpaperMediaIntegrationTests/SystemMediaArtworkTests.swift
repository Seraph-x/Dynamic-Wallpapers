import Carbon
import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration

final class SystemMediaArtworkTests: XCTestCase {
    func testArtworkURLRequiresHTTPSHostAndNoCredentials() throws {
        XCTAssertEqual(try SystemMediaArtworkURL("https://i.scdn.co/image/actual").url.absoluteString,
                       "https://i.scdn.co/image/actual")
        for value in ["http://example.com/a", "file:///a", "https:///", "https://user:pass@artwork.example.com/a", "https://user@artwork.example.com/a"] {
            XCTAssertThrowsError(try SystemMediaArtworkURL(value), value)
        }
    }

    func testActualRawDataAndURLArePreservedAndMissingIsUnavailable() throws {
        let bytes = Data([0, 255, 1, 3])
        let raw = try XCTUnwrap(NSAppleEventDescriptor(descriptorType: MediaAE.code("PNGf"), data: bytes))
        XCTAssertEqual(try MediaArtworkSourceDecoder.decodeMusic(raw), .embedded(bytes))
        XCTAssertEqual(try MediaArtworkSourceDecoder.decodeMusic(.null()), .unavailable)
        let missing = NSAppleEventDescriptor(typeCode: MediaAE.code("msng"))
        XCTAssertEqual(try MediaArtworkSourceDecoder.decodeMusic(missing), .unavailable)
        XCTAssertThrowsError(try MediaArtworkSourceDecoder.decodeMusic(NSAppleEventDescriptor(string: "wrong type")))
        XCTAssertEqual(try MediaArtworkSourceDecoder.decodeSpotify(NSAppleEventDescriptor(string: "https://example.com/cover")),
                       .remote(try SystemMediaArtworkURL("https://example.com/cover")))
        XCTAssertEqual(try MediaArtworkSourceDecoder.decodeSpotify(NSAppleEventDescriptor(string: "")), .unavailable)
        XCTAssertEqual(try MediaArtworkSourceDecoder.decodeSpotify(.null()), .unavailable)
        XCTAssertThrowsError(try MediaArtworkSourceDecoder.decodeSpotify(NSAppleEventDescriptor(int32: 12)))
    }

    func testMusicRawDataDoesNotRestrictTheOriginalImageFormatToAKnownDescriptorList() throws {
        let bytes = try Data(contentsOf: ArtworkImageDecoderTests.fixtureURL)
        let original = try XCTUnwrap(NSAppleEventDescriptor(descriptorType: MediaAE.code("heic"), data: bytes))
        XCTAssertEqual(try MediaArtworkSourceDecoder.decodeMusic(original), .embedded(bytes))
    }

    func testArtworkReadMissingProcessIsAnExplicitSourceFailure() async throws {
        let service = AppleEventMediaService(resolveProcess: { _ in nil })
        do {
            _ = try await service.readArtwork(for: SystemMediaArtworkIdentity(source: .music, trackID: "actual"))
            XCTFail("Expected an explicit unavailable process error")
        } catch { XCTAssertEqual(error as? SystemMediaError, .applicationNotRunning) }
    }
}
