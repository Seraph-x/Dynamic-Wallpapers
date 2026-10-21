import XCTest
import WallpaperCore
import ScreenSaverCore

final class ConsentTests: XCTestCase {
    func testMixedProjectionRequiresExplicitConsentAndRetainsEveryReason() throws {
        let fixture = ProjectionFixture()
        let projection = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
        XCTAssertEqual(projection.unconfirmedExclusions(consent: nil), projection.exclusions)
        XCTAssertThrowsError(try projection.validateForPublication(consent: nil)) {
            XCTAssertEqual($0 as? ScreenSaverProjectionError, .confirmationRequired)
        }
        let consent = ScreenSaverConsent(acknowledging: projection)
        try projection.validateForPublication(consent: consent)
        XCTAssertEqual(consent.signatures, projection.exclusions.map(\.signature))
        XCTAssertEqual(try JSONDecoder().decode(ScreenSaverConsent.self, from: JSONEncoder().encode(consent)), consent)
    }

    func testConfirmedSubsetReorderingAndSupportedTimingEditsRemainApproved() throws {
        var fixture = ProjectionFixture()
        let before = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
        let consent = ScreenSaverConsent(acknowledging: before)
        fixture.library.playlists[0].entries[0].timing.seconds = 47
        fixture.library.playlists[0].entries.reverse()
        let excludedID = fixture.extended.id
        fixture.library.playlists[0].entries.removeAll { $0.mediaID == excludedID }
        let after = try ScreenSaverProjection(library: fixture.library, source: before.source)
        XCTAssertTrue(after.unconfirmedExclusions(consent: consent).isEmpty)
        XCTAssertEqual(after.entries.last?.timing.seconds, 47)
        try after.validateForPublication(consent: consent)
    }

    func testEditsDuringConfirmationOnlyAuthorizeTheDisplayedSignatures() throws {
        var fixture = ProjectionFixture()
        let displayed = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
        let displayedConsent = ScreenSaverConsent(acknowledging: displayed)
        let newEntry = PlaylistEntry(mediaID: fixture.web.id)
        fixture.library.playlists[0].entries.append(newEntry)
        fixture.library.playlists[0].entries[0].timing.seconds = 71
        let settings = try ScreenSaverSettings(source: displayed.source).confirming(displayedConsent)
        let latest = try ScreenSaverProjection(library: fixture.library, source: displayed.source)
        XCTAssertEqual(latest.unconfirmedExclusions(consent: settings.consent).map(\.signature.entryID), [newEntry.id])
        XCTAssertEqual(latest.entries[0].timing.seconds, 71)
        XCTAssertThrowsError(try latest.validateForPublication(consent: settings.consent))
        let confirmed = try settings.confirming(ScreenSaverConsent(acknowledging: latest))
        try latest.validateForPublication(consent: confirmed.consent)
    }

    func testEverySignatureFieldAndSourceIdentityParticipatesInApproval() throws {
        let fixture = ProjectionFixture()
        let projection = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
        let consent = ScreenSaverConsent(acknowledging: projection)
        let signature = try XCTUnwrap(consent.signatures.first)
        let changed = [
            ScreenSaverExclusionSignature(entryID: UUID(), mediaID: signature.mediaID, kind: signature.kind,
                                           backend: signature.backend, reason: signature.reason),
            ScreenSaverExclusionSignature(entryID: signature.entryID, mediaID: UUID(), kind: signature.kind,
                                           backend: signature.backend, reason: signature.reason),
            ScreenSaverExclusionSignature(entryID: signature.entryID, mediaID: signature.mediaID, kind: .image,
                                           backend: signature.backend, reason: signature.reason),
            ScreenSaverExclusionSignature(entryID: signature.entryID, mediaID: signature.mediaID, kind: signature.kind,
                                           backend: .native, reason: signature.reason),
            ScreenSaverExclusionSignature(entryID: signature.entryID, mediaID: signature.mediaID, kind: signature.kind,
                                           backend: signature.backend, reason: .webContent)
        ]
        XCTAssertTrue(consent.covers(source: projection.source, signature: signature))
        for value in changed { XCTAssertFalse(consent.covers(source: projection.source, signature: value)) }
        XCTAssertFalse(consent.covers(source: .playlist(UUID()), signature: signature))
        XCTAssertFalse(consent.covers(source: .media(fixture.list.id), signature: signature))
    }

    func testSourceSwitchDropsApprovalAndRejectsAnOldDialog() throws {
        let fixture = ProjectionFixture()
        let projection = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
        let consent = ScreenSaverConsent(acknowledging: projection)
        let settings = try ScreenSaverSettings(source: projection.source).confirming(consent)
        XCTAssertEqual(settings.selecting(projection.source).consent, consent)
        let switched = settings.selecting(.media(fixture.image.id))
        XCTAssertNil(switched.consent)
        XCTAssertNil(switched.selecting(projection.source).consent)
        XCTAssertThrowsError(try switched.confirming(consent))
        XCTAssertThrowsError(try ScreenSaverSettings(source: nil, consent: consent).validate())
        XCTAssertThrowsError(try ScreenSaverSettings(source: .media(fixture.image.id), consent: consent).validate())
        XCTAssertEqual(settings.consent, consent)
    }

    func testReplacementAtTheSameEntryRequiresNewApproval() throws {
        var fixture = ProjectionFixture()
        let projection = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
        let consent = ScreenSaverConsent(acknowledging: projection)
        let original = fixture.library.playlists[0].entries[1]
        fixture.library.playlists[0].entries[1] = PlaylistEntry(id: original.id, mediaID: fixture.web.id)
        let latest = try ScreenSaverProjection(library: fixture.library, source: projection.source)
        XCTAssertEqual(latest.unconfirmedExclusions(consent: consent).map(\.signature.entryID), [original.id])
    }
}
