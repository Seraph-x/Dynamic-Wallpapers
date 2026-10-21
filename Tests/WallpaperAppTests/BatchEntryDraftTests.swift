import XCTest
import WallpaperCore
@testable import WallpaperApp

final class BatchEntryDraftTests: XCTestCase {
    func testWebSelectionAllowsOnlyFixedTimingButKeepsUncheckedTimingUntouched() throws {
        var draft = BatchEntryDraft()
        draft.changeTiming = true
        for mode in [TimingMode.full, .loops] {
            draft.mode = mode
            XCTAssertThrowsError(try draft.patch(hasVideo: true, hasWeb: true))
        }
        draft.mode = .seconds
        XCTAssertEqual(try draft.patch(hasVideo: true, hasWeb: true).timing, EntryTiming(seconds: 30))
        draft.mode = .full; draft.changeTiming = false; draft.changeVolume = true
        XCTAssertEqual(try draft.patch(hasVideo: true, hasWeb: true), EntryBatchPatch(volume: 1))
    }

    func testInvalidVisibleTimeTextCannotProducePatch() {
        var draft = BatchEntryDraft()
        draft.changeTiming = true
        for text in ["", "abc", "30abc", "-1", "0", "nan", "inf"] {
            draft.durationValue = text
            XCTAssertThrowsError(try draft.patch(hasVideo: true), text)
        }
        draft.durationValue = "12.5"; draft.mode = .loops
        for text in ["", "abc", "1.5", "0", "-2", "9999999999999999999999"] {
            draft.loops = text
            XCTAssertThrowsError(try draft.patch(hasVideo: true), text)
        }
    }

    func testUncheckedFieldsDoNotParseOrChange() throws {
        var draft = BatchEntryDraft()
        draft.durationValue = "invalid"; draft.loops = "invalid"
        draft.changeVolume = true; draft.volume = 0.42
        XCTAssertEqual(try draft.patch(hasVideo: true), EntryBatchPatch(volume: 0.42))
        draft.changeTiming = true; draft.durationValue = "12.5"; draft.mode = .full
        XCTAssertEqual(try draft.patch(hasVideo: true).timing, EntryTiming(mode: .full, seconds: 12.5))
    }

    func testSelectedTimingAndIndependentAudioProduceExactPatch() throws {
        var draft = BatchEntryDraft()
        XCTAssertThrowsError(try draft.patch(hasVideo: true))
        draft.changeTiming = true; draft.mode = .loops; draft.durationValue = "7"; draft.loops = "3"
        draft.changeMute = true; draft.muted = true
        XCTAssertEqual(try draft.patch(hasVideo: true), EntryBatchPatch(timing: EntryTiming(mode: .loops, seconds: 7, loops: 3), isMuted: true))
        XCTAssertThrowsError(try draft.patch(hasVideo: false))
    }

    func testDurationUnitsStoreSecondsWithoutChangingExistingTimingFormat() throws {
        var draft = BatchEntryDraft()
        draft.changeTiming = true
        draft.durationValue = "1.5"
        draft.durationUnit = .minutes
        XCTAssertEqual(try draft.patch(hasVideo: true).timing, EntryTiming(seconds: 90))
        draft.durationUnit = .hours
        XCTAssertEqual(try draft.patch(hasVideo: true).timing, EntryTiming(seconds: 5_400))
    }

    func testDurationUnitDisplayPrefersWholeHoursAndMinutes() {
        XCTAssertEqual(EntryDurationUnit.preferred(for: 3_600), .hours)
        XCTAssertEqual(EntryDurationUnit.preferred(for: 5_400), .hours)
        XCTAssertEqual(EntryDurationUnit.preferred(for: 120), .minutes)
        XCTAssertEqual(EntryDurationUnit.preferred(for: 90), .minutes)
        XCTAssertEqual(EntryDurationUnit.preferred(for: 61), .seconds)
        XCTAssertEqual(EntryDurationUnit.hours.value(for: 5_400), 1.5)
    }
}
