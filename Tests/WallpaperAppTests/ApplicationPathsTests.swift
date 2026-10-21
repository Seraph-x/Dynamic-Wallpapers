import Foundation
import XCTest
@testable import WallpaperApp

final class ApplicationPathsTests: XCTestCase {
    private let productionID = "local.dynamicwallpaper.app"

    func testProductionRejectsEveryValidationArgument() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        for argument in ["--validation-data-root", "--print-validation-paths", "--validation-evidence"] {
            XCTAssertThrowsError(try ApplicationPaths.resolve(arguments: [argument, root.path],
                bundleIdentifier: productionID, configuredBundleIdentifier: productionID))
        }
        for invalid in [productionID + ".validation.", productionID + ".validation.bad.value",
                        productionID + ".validation.bad/value"] {
            XCTAssertThrowsError(try ApplicationPaths.resolve(arguments: [], bundleIdentifier: invalid,
                configuredBundleIdentifier: productionID))
        }
    }

    func testValidationPathsAreAllInsideCanonicalRootAndStableInEvidence() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Home"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Temp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let temporary = root.appendingPathComponent("Temp")
        let evidence = root.appendingPathComponent("evidence/events.jsonl")
        let paths = try ApplicationPaths.resolve(arguments: ["--validation-data-root", root.path,
                "--print-validation-paths", "--validation-evidence", evidence.path],
            bundleIdentifier: productionID + ".validation.test", configuredBundleIdentifier: productionID,
            environment: ["CFFIXED_USER_HOME": home.path, "TMPDIR": temporary.path])
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(Set(paths.writablePaths.keys), ["applicationSupport", "library", "legacyLibrary",
            "screenSaverExport", "media", "systemWallpapers", "cefCache", "transcodeTemporary",
            "transcodeDiagnostics", "preferences", "logs", "evidence"])
        for path in paths.writablePaths.values {
            XCTAssertTrue(path.standardizedFileURL.pathComponents.starts(with: canonical.pathComponents), path.path)
        }
        XCTAssertEqual(paths.writablePaths["preferences"]?.standardizedFileURL.path,
            home.appendingPathComponent("Library/Preferences").resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(paths.writablePaths["evidence"]?.standardizedFileURL.path,
            evidence.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(paths.preflightRecord().bundleIdentifier, productionID + ".validation.test")
        XCTAssertEqual(paths.startupRecord().paths, paths.preflightRecord().paths)
    }

    func testValidationRejectsSymlinkComponentAndCanonicalEscape() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Home"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Temp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        XCTAssertThrowsError(try ApplicationPaths.resolve(arguments: ["--validation-data-root", root.path],
            bundleIdentifier: productionID + ".validation.test", configuredBundleIdentifier: productionID,
            environment: ["CFFIXED_USER_HOME": root.appendingPathComponent("Home").path,
                          "TMPDIR": root.appendingPathComponent("Temp").path]))
    }

    func testValidationRejectsParentTraversal() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("Home")
        let temporary = root.appendingPathComponent("Temp")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ApplicationPaths.resolve(arguments: ["--validation-data-root", root.path,
                "--validation-evidence", root.path + "/evidence/../escape.jsonl"],
            bundleIdentifier: productionID + ".validation.test", configuredBundleIdentifier: productionID,
            environment: ["CFFIXED_USER_HOME": home.path, "TMPDIR": temporary.path]))
    }

    func testEvidenceIsExclusiveAndContainsSamePathsAsPreflight() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("Home")
        let temporary = root.appendingPathComponent("Temp")
        let evidence = root.appendingPathComponent("evidence/events.jsonl")
        for directory in [home, temporary, evidence.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try ApplicationPaths.resolve(arguments: ["--validation-data-root", root.path,
            "--validation-evidence", evidence.path], bundleIdentifier: productionID + ".validation.test",
            configuredBundleIdentifier: productionID,
            environment: ["CFFIXED_USER_HOME": home.path, "TMPDIR": temporary.path])
        try paths.appendEvidence(event: "startup")
        try paths.appendEvidence(event: "reopen")
        try paths.appendEvidence(event: "shutdown")
        XCTAssertThrowsError(try paths.appendEvidence(event: "startup"))
        let lines = try String(contentsOf: evidence, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let decoder = JSONDecoder()
        let records = try lines.map { try decoder.decode(ApplicationPaths.Record.self, from: Data($0.utf8)) }
        XCTAssertEqual(records.map(\.event), ["startup", "reopen", "shutdown"])
        XCTAssertEqual(records[0].paths, paths.preflightRecord().paths)
    }
}
