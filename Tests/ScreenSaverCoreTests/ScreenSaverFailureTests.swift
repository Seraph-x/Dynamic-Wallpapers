import Foundation
import XCTest
import WallpaperCore
@testable import ScreenSaverCore

final class ScreenSaverFailureTests: XCTestCase {
    func testEveryCodeHasAStableDefaultDescriptionAndIsSendable() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let source = ScreenSaverSource.media(id)
        let codes: [ScreenSaverFailure.Code] = [
            .unsupportedSchema(schema: "manifest", actualVersion: 9), .emptySource,
            .noSupportedMedia, .confirmationRequired, .missingMedia(id), .sourceMissing(source),
            .invalidSourceMetadata("clip.mov"), .missingDuration("clip.mov"), .unsupportedDuration,
            .invalidProjection, .invalidConsent, .invalidPath("../escape"),
            .nonRegularFile("media/item"), .sourceChanged("clip.mov"), .copyMismatch("clip.mov"),
            .integrityMismatch("media/item"), .unknownGeneration(id), .identityMissing,
            .identityChanged, .lockBusy, .leaseFailure(.release), .transactionConflict(.commit),
            .publicationFailed, .committedThenFailed, .settingsUnavailable, .pointerUnavailable,
            .resourceReleaseFailed, .cancelled(.publish), .applicationClosing(.shutdown),
            .bundleMetadataInvalid("Fixture.saver"), .bundleExecutableInvalid("Fixture.saver"),
            .infoPlistTooLarge("Fixture.saver"), .infoPlistInvalid("Fixture.saver"),
            .installationFailed, .previewUnavailable, .authorizationRequired, .bookmarkInvalid,
            .unexpected,
        ]
        XCTAssertEqual(codes.count, 38)
        for code in codes {
            let failure = ScreenSaverFailure(code: code)
            XCTAssertEqual(failure, failure)
            XCTAssertFalse(failure.errorDescription?.isEmpty ?? true, "\(code)")
            requireSendable(failure)
        }
    }

    func testNestedReasonsPreserveOrderAndDuplicates() {
        let first = ScreenSaverFailure(code: .lockBusy)
        let second = ScreenSaverFailure(code: .lockBusy)
        let failure = ScreenSaverFailure(code: .publicationFailed, reasons: [first, second, first])
        XCTAssertEqual(failure.reasons, [first, second, first])
        XCTAssertEqual(failure.reasons.count, 3)
    }

    func testFloatingPointDiagnosticsCanonicalizeSpecialValuesAndBits() {
        XCTAssertEqual(DiagnosticFloatingPoint(Double.nan), DiagnosticFloatingPoint(-Double.nan))
        XCTAssertEqual(DiagnosticFloatingPoint(0.0), .positiveZero)
        XCTAssertEqual(DiagnosticFloatingPoint(-0.0), .negativeZero)
        XCTAssertEqual(DiagnosticFloatingPoint(Double.infinity), .positiveInfinity)
        XCTAssertEqual(DiagnosticFloatingPoint(-Double.infinity), .negativeInfinity)
        XCTAssertEqual(DiagnosticFloatingPoint(1.5), .finite(bitPattern: 1.5.bitPattern))
    }

    func testDiagnosticCapturesScalarsCollectionsUnderlyingAndStableOrdering() throws {
        let underlying = NSError(domain: "underlying", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "inner"])
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        let error = NSError(domain: "fixture", code: 42, userInfo: [
            "z": ["two", 2] as NSArray,
            "a": ["b": true, "a": URL(fileURLWithPath: "/tmp/item")] as NSDictionary,
            "data": Data([0, 1, 2]), "date": date,
            "nan": Double.nan, "positiveZero": 0.0, "negativeZero": -0.0,
            "positiveInfinity": Double.infinity, "negativeInfinity": -Double.infinity,
            NSUnderlyingErrorKey: underlying,
        ])
        let diagnostic = FailureDiagnostic(capturing: error)
        XCTAssertEqual(diagnostic.domain, "fixture")
        XCTAssertEqual(diagnostic.code, 42)
        XCTAssertEqual(diagnostic.localizedDescription, error.localizedDescription)
        XCTAssertEqual(diagnostic.userInfo.map(\.key), diagnostic.userInfo.map(\.key).sorted())
        XCTAssertFalse(diagnostic.userInfo.contains { $0.key == NSUnderlyingErrorKey })
        XCTAssertEqual(value(named: "nan", in: diagnostic), .floating(.nan))
        XCTAssertEqual(value(named: "positiveZero", in: diagnostic), .floating(.positiveZero))
        XCTAssertEqual(value(named: "negativeZero", in: diagnostic), .floating(.negativeZero))
        XCTAssertEqual(value(named: "positiveInfinity", in: diagnostic), .floating(.positiveInfinity))
        XCTAssertEqual(value(named: "negativeInfinity", in: diagnostic), .floating(.negativeInfinity))
        guard case .error(let capturedUnderlying) = diagnostic.underlying else {
            return XCTFail("Underlying error was not captured structurally")
        }
        XCTAssertEqual(capturedUnderlying.domain, "underlying")
        XCTAssertEqual(diagnostic, diagnostic)
        requireSendable(diagnostic)
    }

    func testDiagnosticCapturesSelfAndMutualCyclesWithoutAddresses() {
        let array = NSMutableArray()
        array.add(array)
        let first = NSMutableDictionary()
        let second = NSMutableDictionary()
        first["next"] = second
        second["next"] = first
        let error = NSError(domain: "cycle", code: 1, userInfo: ["array": array, "map": first])
        let diagnostic = FailureDiagnostic(capturing: error)
        let rendered = String(describing: diagnostic)
        XCTAssertTrue(diagnostic.userInfo.contains { containsCycle($0.value) })
        XCTAssertFalse(rendered.contains("0x"))
        XCTAssertEqual(diagnostic, diagnostic)
    }

    func testDiagnosticPreservesNSNumberStorageInsteadOfConditionalBridgeTypes() {
        let cases: [(NSNumber, DiagnosticValue)] = [
            (NSNumber(value: 0), .signed(0)),
            (NSNumber(value: 1), .signed(1)),
            (NSNumber(value: -0.0), .floating(.negativeZero)),
            (NSNumber(value: 0.0), .floating(.positiveZero)),
            (NSNumber(value: 1.0), .floating(.finite(bitPattern: 1.0.bitPattern))),
            (NSNumber(value: true), .bool(true)),
            (NSNumber(value: false), .bool(false)),
            (NSNumber(value: Int64.min), .signed(Int64.min)),
            (NSNumber(value: Int64.max), .signed(Int64.max)),
            (NSNumber(value: UInt64.max), .unsigned(UInt64.max)),
            (NSNumber(value: Double.nan), .floating(.nan)),
            (NSNumber(value: Double.infinity), .floating(.positiveInfinity)),
        ]
        for (number, expected) in cases {
            let diagnostic = FailureDiagnostic(capturing: NSError(domain: "numbers", code: 1,
                userInfo: ["number": number]))
            XCTAssertEqual(value(named: "number", in: diagnostic), expected,
                "NSNumber encoding: \(String(cString: number.objCType))")
        }
    }

    func testDiagnosticPreservesNSNumberValuesInsideFoundationCollections() {
        let numbers: NSArray = [NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: -0.0),
                                NSNumber(value: true), NSNumber(value: UInt64.max)]
        let nested: NSDictionary = ["negativeZero": NSNumber(value: -0.0), "numbers": numbers,
                                    "signed": NSNumber(value: Int64.min)]
        let diagnostic = FailureDiagnostic(capturing: NSError(domain: "nested-numbers", code: 1,
            userInfo: ["nested": nested]))
        XCTAssertEqual(value(named: "nested", in: diagnostic), .map([
            DiagnosticEntry(key: "negativeZero", value: .floating(.negativeZero)),
            DiagnosticEntry(key: "numbers", value: .array([
                .signed(0), .signed(1), .floating(.negativeZero), .bool(true), .unsigned(UInt64.max),
            ])),
            DiagnosticEntry(key: "signed", value: .signed(Int64.min)),
        ]))
    }

    func testDiagnosticKeepsNativeSwiftNumericTypesWithoutNSNumberBridging() {
        let cases: [(Any, DiagnosticValue)] = [
            (Int(1), .signed(1)), (UInt(1), .unsigned(1)),
            (UInt64.max, .unsigned(UInt64.max)), (true, .bool(true)),
            (-0.0, .floating(.negativeZero)), (0.0, .floating(.positiveZero)),
            (1.0, .floating(.finite(bitPattern: 1.0.bitPattern))),
        ]
        for (number, expected) in cases {
            let diagnostic = FailureDiagnostic(capturing: NSError(domain: "swift-numbers", code: 1,
                userInfo: ["number": number]))
            XCTAssertEqual(value(named: "number", in: diagnostic), expected)
        }
    }

    func testUnsupportedObjectsCaptureOnlyStableTypeName() {
        final class UnsupportedFixture: NSObject {}
        let error = NSError(domain: "unsupported", code: 2,
            userInfo: ["object": UnsupportedFixture()])
        let diagnostic = FailureDiagnostic(capturing: error)
        let value = diagnostic.userInfo.first { $0.key == "object" }?.value
        guard case .unsupported(let type) = value else { return XCTFail("Expected unsupported token") }
        XCTAssertTrue(type.contains("UnsupportedFixture"))
        XCTAssertFalse(type.contains("0x"))
    }

    func testKnownErrorsMapWithoutFlatteningGroupedReasons() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(ScreenSaverFailure(capturing: ScreenSaverProjectionError.missingMedia(id)).code,
            .missingMedia(id))
        XCTAssertEqual(ScreenSaverFailure(capturing: ScreenSaverFileLockError.busy).code, .lockBusy)
        let group = WallpaperErrorGroup([ScreenSaverProjectionError.emptySource,
                                         ScreenSaverProjectionError.noSupportedMedia])
        let failure = ScreenSaverFailure(capturing: group, phase: .publish)
        XCTAssertEqual(failure.code, .publicationFailed)
        XCTAssertEqual(failure.reasons.map(\.code), [.emptySource, .noSupportedMedia])
    }

    func testCoreValidationBoundariesThrowSpecificFailures() throws {
        XCTAssertEqual(capturedFailure {
            _ = try ScreenSaverPaths(root: URL(string: "https://example.invalid/export")!)
        }.code, .invalidPath("/export"))

        let signature = ScreenSaverExclusionSignature(entryID: UUID(), mediaID: UUID(),
            kind: .image, backend: .native, reason: .webContent)
        XCTAssertEqual(capturedFailure { try signature.validate() }.code, .invalidConsent)

        let invalidRevision = Data(#"{"value":"not-a-sha256"}"#.utf8)
        XCTAssertEqual(capturedFailure {
            _ = try JSONDecoder().decode(ScreenSaverSourceRevision.self, from: invalidRevision)
        }.code, .integrityMismatch("sourceRevision"))
    }

    func testPublicationFailureExposesTypedAggregateAndPreservesOriginalErrors() {
        let original: [Error] = [
            ScreenSaverProjectionError.emptySource,
            ScreenSaverProjectionError.noSupportedMedia,
        ]
        let publication = ScreenSaverPublicationFailure(committed: nil, errors: original)
        XCTAssertEqual(publication.errors.count, 2)
        XCTAssertEqual(publication.failure.code, .publicationFailed)
        XCTAssertEqual(publication.failure.reasons.map(\.code), [.emptySource, .noSupportedMedia])
        XCTAssertEqual(ScreenSaverFailure(capturing: publication), publication.failure)
    }

    func testCoreBusinessValidationMapsToClosedCodes() throws {
        let storage = try StorageFixture()
        let manifest = try storage.manifest(id: UUID())
        let manifestJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any]
        )
        let settingsJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ScreenSaverSettings())) as? [String: Any]
        )
        let pointer = ScreenSaverCurrentPointer(exportID: UUID(), generationID: manifest.generationID,
            sourceRevision: manifest.sourceRevision, settingsRevision: UUID())
        let pointerJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(pointer)) as? [String: Any]
        )
        let invalidManifest = try json(manifestJSON, replacing: ["schemaVersion": 7])
        let invalidSettings = try json(settingsJSON, replacing: ["schemaVersion": 8])
        let invalidPointer = try json(pointerJSON, replacing: ["schemaVersion": 9])
        let identity = #"{"schemaVersion":2,"format":"local.dynamicwallpaper.screensaver.export","id":"11111111-2222-3333-4444-555555555555"}"#

        let cases: [(String, ScreenSaverFailure.Code, () throws -> Void)] = [
            ("library schema", .unsupportedSchema(schema: "library", actualVersion: Library.currentVersion + 1), {
                var fixture = ProjectionFixture()
                fixture.library.version = Library.currentVersion + 1
                _ = try ScreenSaverProjection(library: fixture.library, source: .media(fixture.image.id))
            }),
            ("duplicate projection IDs", .invalidProjection, {
                var fixture = ProjectionFixture()
                fixture.library.media.append(fixture.image)
                _ = try ScreenSaverProjection(library: fixture.library, source: .media(fixture.image.id))
            }),
            ("invalid media metadata", .invalidSourceMetadata("invalid"), {
                let item = MediaItem(url: URL(fileURLWithPath: "/invalid.png"), kind: .image,
                    width: 0, height: 1)
                var library = Library(); library.media = [item]
                _ = try ScreenSaverProjection(library: library, source: .media(item.id))
            }),
            ("missing duration", .missingDuration("missing"), {
                let item = MediaItem(url: URL(fileURLWithPath: "/missing.mov"), kind: .video,
                    width: 1, height: 1)
                var library = Library(); library.media = [item]
                _ = try ScreenSaverProjection(library: library, source: .media(item.id))
            }),
            ("media hash", .integrityMismatch("media/item.png"), {
                _ = try ScreenSaverMediaFile(media: storage.projection.media[0],
                    relativePath: "media/item.png", byteCount: 1, sha256: "bad")
            }),
            ("manifest schema", .unsupportedSchema(schema: "manifest", actualVersion: 7), {
                _ = try JSONDecoder().decode(ScreenSaverManifest.self, from: invalidManifest)
            }),
            ("settings schema", .unsupportedSchema(schema: "settings", actualVersion: 8), {
                _ = try JSONDecoder().decode(ScreenSaverSettings.self, from: invalidSettings)
            }),
            ("export identity", .identityChanged, {
                _ = try JSONDecoder().decode(ScreenSaverExportIdentity.self, from: Data(identity.utf8))
            }),
            ("current pointer", .pointerUnavailable, {
                _ = try JSONDecoder().decode(ScreenSaverCurrentPointer.self, from: invalidPointer)
            }),
        ]

        for (name, expected, operation) in cases {
            XCTAssertEqual(capturedFailure(operation).code, expected, name)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("failure-map-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(capturedFailure {
            _ = try ScreenSaverFileIO.openRegular(root: root, relativePath: "directory")
        }.code, .nonRegularFile("directory"))
    }

    private func requireSendable<T: Sendable>(_ value: T) { _ = value }

    private func capturedFailure(_ operation: () throws -> Void) -> ScreenSaverFailure {
        do {
            try operation()
            XCTFail("Expected operation to throw")
            return ScreenSaverFailure(code: .unexpected)
        } catch {
            return ScreenSaverFailure(capturing: error)
        }
    }

    private func json(_ original: [String: Any], replacing changes: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: original.merging(changes) { _, new in new })
    }

    private func value(named key: String, in diagnostic: FailureDiagnostic) -> DiagnosticValue? {
        diagnostic.userInfo.first { $0.key == key }?.value
    }

    private func containsCycle(_ value: DiagnosticValue) -> Bool {
        switch value {
        case .cycle: return true
        case .array(let values): return values.contains(where: containsCycle)
        case .map(let entries): return entries.contains { containsCycle($0.value) }
        case .error(let diagnostic):
            return diagnostic.userInfo.contains { containsCycle($0.value) }
                || diagnostic.underlying.map(containsCycle) == true
        default: return false
        }
    }
}
