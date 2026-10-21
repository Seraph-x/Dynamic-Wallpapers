import Foundation
import ScreenSaverCore
import XCTest
@testable import WallpaperApp

@MainActor
final class ScreenSaverInstallationTests: XCTestCase {
    func testInstallerRefusalHasExplicitCode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = try makeBundle(at: root.appendingPathComponent("Bundled.saver"), version: "2")
        let service = ScreenSaverInstallation(bundledURL: bundled, product: ProductMetadataTestSupport.product,
            operations: ScreenSaverInstallationOperations(open: { _ in false }, installedBundles: { [] }))

        XCTAssertThrowsError(try service.install()) { error in
            XCTAssertEqual((error as? ScreenSaverFailure)?.code, .installationFailed)
        }
    }

    func testExpectedSaverIdentityComesFromInjectedProduct() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var info = try ProductMetadataTestSupport.information()
        info["DWScreenSaverBundleIdentifier"] = "test.custom.screen.saver"
        let productBundle = try ProductMetadataTestSupport.makeBundle(in: root, information: info)
        let product = try ProductBundleMetadata(bundle: productBundle)
        let bundled = try makeBundle(at: root.appendingPathComponent("Bundled.saver"), version: "2",
                                     identifier: product.screenSaverBundleIdentifier)
        let service = ScreenSaverInstallation(bundledURL: bundled, product: product,
            operations: ScreenSaverInstallationOperations(open: { _ in true }, installedBundles: { [] }))
        XCTAssertEqual(try service.refresh(), .notInstalled(bundledVersion: "2"))
    }

    func testOpeningInstallerDoesNotClaimInstallationWithoutInstalledBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = try makeBundle(at: root.appendingPathComponent("Bundled.saver"), version: "2")
        var opened: [URL] = []
        let service = ScreenSaverInstallation(
            bundledURL: bundled, product: ProductMetadataTestSupport.product,
            operations: ScreenSaverInstallationOperations(
                open: { opened.append($0); return true },
                installedBundles: { [] }))

        XCTAssertEqual(try service.refresh(), .notInstalled(bundledVersion: "2"))
        XCTAssertEqual(try service.install(), .notInstalled(bundledVersion: "2"))
        XCTAssertEqual(opened, [bundled])
    }

    func testInstalledStatusRequiresMatchingBundleIdentifierAndReadsVersionBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = try makeBundle(at: root.appendingPathComponent("Bundled.saver"), version: "2")
        let wrong = try makeBundle(at: root.appendingPathComponent("Wrong.saver"), version: "99",
                                   identifier: "example.wrong")
        let old = try makeBundle(at: root.appendingPathComponent("Installed.saver"), version: "1")
        let service = ScreenSaverInstallation(
            bundledURL: bundled, product: ProductMetadataTestSupport.product,
            operations: ScreenSaverInstallationOperations(open: { _ in true }, installedBundles: { [wrong, old] }))

        XCTAssertEqual(try service.refresh(), .updateAvailable(installedVersion: "1", bundledVersion: "2", url: old))
    }

    func testFailedRefreshCannotKeepAnEarlierInstalledStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = try makeBundle(at: root.appendingPathComponent("Bundled.saver"), version: "2")
        let installed = try makeBundle(at: root.appendingPathComponent("Installed.saver"), version: "2")
        var failScan = false
        let service = ScreenSaverInstallation(bundledURL: bundled, product: ProductMetadataTestSupport.product,
            operations: ScreenSaverInstallationOperations(
            open: { _ in true }, installedBundles: {
                if failScan { throw CocoaError(.fileReadNoPermission) }
                return [installed]
            }))

        XCTAssertEqual(try service.refresh(), .installed(version: "2", url: installed))
        failScan = true
        XCTAssertThrowsError(try service.refresh())
        XCTAssertNil(service.status)
    }

    func testMissingInstalledExecutableCannotBeReportedAsInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = try makeBundle(at: root.appendingPathComponent("Bundled.saver"), version: "2")
        let installed = try makeBundle(at: root.appendingPathComponent("Installed.saver"), version: "2")
        try FileManager.default.removeItem(at: installed.appendingPathComponent("Contents/MacOS/TestSaver"))
        let service = ScreenSaverInstallation(bundledURL: bundled, product: ProductMetadataTestSupport.product,
            operations: ScreenSaverInstallationOperations(
            open: { _ in true }, installedBundles: { [installed] }))

        XCTAssertThrowsError(try service.refresh())
        XCTAssertNil(service.status)
    }

    func testUnrelatedLegacySaverDoesNotBlockOurInstallationStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = try makeBundle(at: root.appendingPathComponent("Bundled.saver"), version: "2")
        let legacy = try makeBundle(at: root.appendingPathComponent("Legacy.saver"), version: "1",
                                    identifier: "example.legacy")
        let info = legacy.appendingPathComponent("Contents/Info.plist")
        let bytes = try PropertyListSerialization.data(fromPropertyList:
            ["CFBundleIdentifier": "example.legacy"], format: .xml, options: 0)
        try bytes.write(to: info)
        try FileManager.default.removeItem(at: legacy.appendingPathComponent("Contents/MacOS/TestSaver"))
        let service = ScreenSaverInstallation(bundledURL: bundled, product: ProductMetadataTestSupport.product,
            operations: ScreenSaverInstallationOperations(
            open: { _ in true }, installedBundles: { [legacy] }))

        XCTAssertEqual(try service.refresh(), .notInstalled(bundledVersion: "2"))
    }

    private func makeBundle(at url: URL, version: String,
                            identifier: String = ProductMetadataTestSupport.product.screenSaverBundleIdentifier) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                   "CFBundleVersion": version, "CFBundlePackageType": "BNDL",
                                   "CFBundleExecutable": "TestSaver"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/TestSaver")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test bundle executable".utf8).write(to: executable)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }
}
