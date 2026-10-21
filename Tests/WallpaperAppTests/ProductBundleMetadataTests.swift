import Foundation
import XCTest
@testable import WallpaperApp

final class ProductBundleMetadataTests: XCTestCase {
    func testConfiguredFixtureProvidesRuntimeIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ProductMetadataTestSupport.makeBundle(
            in: directory, information: ProductMetadataTestSupport.information())
        let product = try ProductBundleMetadata(bundle: bundle)
        let configuration = try ProductMetadataTestSupport.configuration()
        let application = try XCTUnwrap(configuration["application"] as? [String: String])
        let screenSaver = try XCTUnwrap(configuration["screen_saver"] as? [String: String])
        XCTAssertEqual(product.displayName, application["display_name"])
        XCTAssertEqual(product.applicationBundleIdentifier, application["bundle_identifier"])
        XCTAssertEqual(product.screenSaverBundleIdentifier, screenSaver["bundle_identifier"])
        XCTAssertEqual(product.screenSaverBundleName, screenSaver["bundle_name"])
    }

    func testMissingOrMismatchedIdentityFailsExplicitly() throws {
        let original = try ProductMetadataTestSupport.information()
        for (key, replacement) in [
            ("DWApplicationBundleIdentifier", "other.application"),
            ("DWScreenSaverBundleIdentifier", ""),
            ("DWScreenSaverBundleName", "../Other.saver"),
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var info = original
            info[key] = replacement
            let bundle = try ProductMetadataTestSupport.makeBundle(in: directory, information: info)
            XCTAssertThrowsError(try ProductBundleMetadata(bundle: bundle), key)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var missing = original
        missing.removeValue(forKey: "DWScreenSaverBundleIdentifier")
        let bundle = try ProductMetadataTestSupport.makeBundle(in: directory, information: missing)
        XCTAssertThrowsError(try ProductBundleMetadata(bundle: bundle))
    }

    func testXCTestMainBundleCannotSupplyProductMetadata() {
        XCTAssertThrowsError(try ProductBundleMetadata(bundle: .main))
    }

    func testValidationCopyMayChangeOnlyBundleIdentifier() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var info = try ProductMetadataTestSupport.information()
        let configured = try XCTUnwrap(info["DWApplicationBundleIdentifier"] as? String)
        info["CFBundleIdentifier"] = configured + ".validation.test"
        let bundle = try ProductMetadataTestSupport.makeBundle(in: directory, information: info)
        XCTAssertEqual(try ProductBundleMetadata(bundle: bundle).applicationBundleIdentifier,
            configured + ".validation.test")
        for invalid in [configured + ".validation.", configured + ".validation.bad.value",
                        configured + ".validation.bad/value"] {
            info["CFBundleIdentifier"] = invalid
            let invalidBundle = try ProductMetadataTestSupport.makeBundle(
                in: directory.appendingPathComponent(UUID().uuidString), information: info)
            XCTAssertThrowsError(try ProductBundleMetadata(bundle: invalidBundle))
        }
    }
}
