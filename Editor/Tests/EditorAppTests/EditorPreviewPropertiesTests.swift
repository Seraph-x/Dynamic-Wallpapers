import AppKit
import XCTest
import WallpaperCore
import WallpaperAudioSpectrum
@testable import EditorApp

@MainActor final class EditorPreviewPropertiesTests: XCTestCase {
    private func catalog(_ properties: [String: Any]) throws -> EditorPreviewProperties {
        try EditorPreviewProperties(project: ["general": ["properties": properties]])
    }
    func testCatalogPreservesTypedDefaultsAndGeneralOverridesPreset() throws {
        let value = try EditorPreviewProperties(project: ["general": ["properties": [
            "flag": ["type": "bool", "value": true, "order": 1],
            "amount": ["type": "slider", "value": 3.25, "min": -10, "max": 10, "step": 0.25, "order": 2],
            "text": ["type": "textinput", "value": ""],
            "color": ["type": "color", "value": "0.1 0.2 1"],
            "choice": ["type": "combo", "value": "two", "options": [["label": "Two", "value": "two"]]]
        ]], "preset": ["flag": ["value": false], "presetOnly": ["value": 9]]])
        XCTAssertEqual(value.rows.prefix(2).map(\.name), ["flag", "amount"])
        XCTAssertEqual(value.defaults["flag"], .bool(true))
        XCTAssertEqual(value.defaults["text"], .string(""))
        XCTAssertNotNil(value.rows.first { $0.name == "presetOnly" }?.readOnlyReason)
        XCTAssertEqual(value.rows.first { $0.name == "choice" }?.options?.first?.value, .string("two"))
    }
    func testInvalidDefinitionsRemainVisibleAndNoInventedSliderBounds() throws {
        let value = try catalog(["unbounded": ["type": "slider", "value": 8], "bad": ["type": "slider", "value": true],
            "file": ["type": "file", "value": "x"], "condition": ["type": "bool", "value": true, "condition": "flag"],
            "__proto__": ["type": "textinput", "value": "prototype"], "future": ["type": "future", "value": [1]], "raw": 7])
        XCTAssertEqual(value.rows.count, 7)
        let unbounded = try XCTUnwrap(value.rows.first { $0.name == "unbounded" })
        XCTAssertNil(unbounded.min); XCTAssertNil(unbounded.max); XCTAssertNil(unbounded.readOnlyReason)
        XCTAssertEqual(value.rows.filter { $0.readOnlyReason != nil }.count, 6)
        XCTAssertTrue(try XCTUnwrap(value.rows.first { $0.name == "raw" }).rawDescription.contains("7"))
    }
    func testValidationRejectsWrongScalarRangeOptionAndRGBWithoutCoercion() throws {
        let value = try catalog(["n": ["type": "slider", "value": 1, "min": -2, "max": 2],
            "b": ["type": "bool", "value": false], "c": ["type": "color", "value": "0 0 0"],
            "pick": ["type": "combo", "value": "a", "options": [["label": "A", "value": "a"]]]])
        for patch: [String: Any] in [["n": true], ["n": Double.infinity], ["n": 3], ["b": 1], ["c": "1 0"], ["c": "2 0 0"], ["pick": "b"], ["unknown": "x"]] {
            XCTAssertThrowsError(try value.validate(patch))
        }
        XCTAssertEqual(try value.validate(["n": -1.5, "b": true]), ["n": .number(-1.5), "b": .bool(true)])
        XCTAssertThrowsError(try EditorPreviewProperties(project: ["general": ["properties": []]]))
    }
    func testPreviewAcknowledgesOnlyAfterPageAndResetUsesRealCommand() async throws {
        let page = PreviewPageFixture(), properties = try catalog(["n": ["type": "slider", "value": 1]])
        let session = EditorScenePreviewSession(makePage: { page }, properties: properties, cleanup: {})
        try session.start(); page.onReady?(); for _ in 0..<30 { await Task.yield() }
        page.holdProperties = true
        let task = Task { try await session.setUserProperties(["n": 4]) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(session.busy); XCTAssertEqual(session.propertyValues["n"], .number(1))
        XCTAssertEqual(page.propertyRequests.count, 1)
        do { try await session.setPlaying(false); XCTFail("Commands cannot overlap") } catch {}
        page.propertyReply?.resume(); try await task.value
        XCTAssertEqual(session.propertyValues["n"], .number(4))
        page.holdProperties = false; try await session.resetUserProperties()
        XCTAssertEqual(page.propertyRequests.count, 2); XCTAssertEqual(session.propertyValues["n"], .number(1))
        try await session.close()
    }
    func testValidationFailureDoesNotDispatchAndRuntimeFailureDoesNotAcknowledge() async throws {
        let page = PreviewPageFixture(), properties = try catalog(["b": ["type": "bool", "value": false]])
        let session = EditorScenePreviewSession(makePage: { page }, properties: properties, cleanup: {})
        try session.start(); page.onReady?(); for _ in 0..<30 { await Task.yield() }
        do { try await session.setUserProperties(["b": 3]); XCTFail("Expected type rejection") } catch {}
        XCTAssertTrue(page.propertyRequests.isEmpty); XCTAssertEqual(session.state, .playing)
        page.propertyError = WallpaperError("Renderer failed")
        do { try await session.setUserProperties(["b": true]); XCTFail("Expected renderer failure") } catch {}
        XCTAssertEqual(session.propertyValues["b"], .bool(false)); XCTAssertNotNil(session.propertyFailure)
        XCTAssertEqual(session.state, .playing, "A command rejection must not change playback/audio demand")
        try await session.close()
    }
    func testPausedUpdateAndRestartDefaultsArePreviewLocal() async throws {
        let first = PreviewPageFixture(), next = PreviewPageFixture(), other = PreviewPageFixture()
        var pages = [first, next]
        let properties = try catalog(["t": ["type": "textinput", "value": "captured"]])
        let session = EditorScenePreviewSession(makePage: { pages.removeFirst() }, properties: properties, cleanup: {})
        let independent = EditorScenePreviewSession(makePage: { other }, properties: properties, cleanup: {})
        try session.start(); first.onReady?(); for _ in 0..<30 { await Task.yield() }
        try await session.setPlaying(false); try await session.setUserProperties(["t": "changed"])
        XCTAssertEqual(session.state, .paused); XCTAssertEqual(first.playingRequests, [true, false])
        XCTAssertEqual(independent.propertyValues["t"], .string("captured"))
        try await session.restart(); XCTAssertEqual(session.propertyValues["t"], .string("captured"))
        XCTAssertTrue(next.propertyRequests.isEmpty); XCTAssertNotEqual(first.origin, session.origin)
        try await session.close(); try await independent.close()
    }
    func testPrototypeLikeNamesMetadataIdentityAndExactValidationBoundaries() throws {
        let value = try catalog([
            "constructor": ["type": "bool", "value": false], "prototype": ["type": "textinput", "value": ""],
            "toString": ["type": "slider", "value": 0.3, "step": 2],
            "actual": ["type": "bool", "value": true, "name": "__proto__", "raw": "shadow", "readOnlyReason": "fake"],
            "future": ["type": "future", "value": "x", "condition": "unsupported"],
            "color": ["type": "color", "value": "0 0 0"],
            "choice": ["type": "combo", "value": "", "options": [["label": "Empty", "value": ""]]],
            "emptyCondition": ["type": "bool", "value": true, "condition": ""]])
        XCTAssertEqual(try value.validate(["constructor": true, "prototype": "x", "toString": 0.4, "choice": ""]),
            ["constructor": .bool(true), "prototype": .string("x"), "toString": .number(0.4), "choice": .string("")])
        let actual = try XCTUnwrap(value.rows.first { $0.name == "actual" })
        XCTAssertNil(actual.readOnlyReason); XCTAssertTrue(actual.rawDescription.contains("shadow"))
        XCTAssertNil(value.rows.first { $0.name == "emptyCondition" }?.readOnlyReason)
        XCTAssertEqual(value.rows.first { $0.name == "future" }?.readOnlyReason, "unsupported-type")
        for rgb in ["0x1 0 0", "Infinity 0 0", "NaN 0 0", "0.5 0.5 0.5 1"] { XCTAssertThrowsError(try value.validate(["color": rgb])) }
        XCTAssertEqual(try value.validate(["color": "  .5 1e-2 +1.  "])["color"], .string("  .5 1e-2 +1.  "))
        XCTAssertThrowsError(try value.validate(["color": "0\u{0085}0 0"]))
        XCTAssertEqual(try value.validate(["color": "\u{FEFF}0 0 0\u{FEFF}"])["color"], .string("\u{FEFF}0 0 0\u{FEFF}"))
    }
    func testPageErrorDuringPropertyAwaitNeverAcknowledgesAndBusyCloseIsRejected() async throws {
        let page = PreviewPageFixture(), properties = try catalog(["b": ["type": "bool", "value": false]])
        let domain = "EditorPreviewPropertiesTests.\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: domain) }
        let capture = EditorCaptureFixture()
        let audio = EditorPreviewAudioController(controller: SystemAudioSpectrumController(supported: true, makeCapture: { capture }), defaults: UserDefaults(suiteName: domain)!)
        audio.setEnabled(true)
        let session = EditorScenePreviewSession(makePage: { page }, audio: audio, properties: properties, cleanup: {})
        try session.start(); page.onReady?(); for _ in 0..<30 { await Task.yield() }
        await audio.settled(); XCTAssertEqual(capture.starts, 1)
        page.propertyError = WallpaperError("Rejected patch")
        do { try await session.setUserProperties(["b": true]); XCTFail("Expected rejection") } catch {}
        await audio.settled(); XCTAssertEqual(capture.stops, 0); XCTAssertEqual(session.state, .playing)
        page.propertyError = nil
        page.holdProperties = true
        let task = Task { try await session.setUserProperties(["b": true]) }
        for _ in 0..<20 { await Task.yield() }
        do { try await session.close(); XCTFail("Close must not overlap a pending command") } catch {}
        page.onError?(WallpaperError("Page lost while awaiting properties"))
        page.propertyReply?.resume()
        do { try await task.value; XCTFail("Failed page must not acknowledge values") } catch {}
        XCTAssertEqual(session.state, .failed); XCTAssertEqual(session.propertyValues["b"], .bool(false)); XCTAssertFalse(session.busy)
        XCTAssertNotNil(session.failure); XCTAssertNotNil(session.propertyFailure)
        await audio.settled(); XCTAssertEqual(capture.stops, 1)
        try await session.close(); try await audio.shutdown()
    }
    func testDisconnectedNativeControlReportsAnError() async throws {
        let view = EditorPreviewPropertiesView(localize: { $0 })
        let properties = try catalog(["text": ["type": "textinput", "value": ""]])
        view.configure(properties)
        view.update(values: properties.defaults, enabled: true, origin: "test", failure: nil)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(view)
        let apply = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "editor-property-apply-text" })
        apply.performClick(nil); for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.identifier?.rawValue == "editor-property-error-text" && !$0.stringValue.isEmpty })
    }
    func testComboPreservesDuplicateLabelsWithDistinctStringValues() async throws {
        _ = NSApplication.shared
        let view = EditorPreviewPropertiesView(localize: { $0 })
        let properties = try catalog(["pick": ["type": "combo", "value": "a", "options": [["label": "Same", "value": "a"], ["label": "Same", "value": "b"]]]])
        var received: [String: Any]?
        view.onSubmit = { received = $0 }
        view.configure(properties); view.update(values: properties.defaults, enabled: true, origin: "combo", failure: nil)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let popup = try XCTUnwrap(descendants(view).compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(popup.numberOfItems, 2, "Labels are presentation and must not collapse distinct option values")
        popup.menu?.update()
        XCTAssertTrue(popup.itemArray.allSatisfy(\.isEnabled), "Actual menu items must stay available to mouse and keyboard selection")
        if popup.numberOfItems == 2 {
            popup.selectItem(at: 1)
            NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup)
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(received?["pick"] as? String, "b")
        }
    }
    func testStringValuesUseExactUnicodeIdentity() throws {
        let composed = "é", decomposed = "e\u{0301}"
        XCTAssertNotEqual(EditorPreviewPropertyValue.string(composed), .string(decomposed), "Wire strings use exact code points, matching JavaScript")
        let value = try catalog(["pick": ["type": "combo", "value": composed, "options": [["label": "Exact", "value": composed]]]])
        XCTAssertThrowsError(try value.validate(["pick": decomposed]))
        let named = try catalog([composed: ["type": "bool", "value": true]])
        XCTAssertThrowsError(try named.validate([decomposed: false]), "A canonical alias is not the declared JavaScript property name")
        XCTAssertEqual(try value.validate(["pick": composed])["pick"], .string(composed))
    }
    func testCapturedPropertyNamesDoNotSilentlyDropCanonicalUnicodeAliases() throws {
        let bytes = Data(#"{"general":{"properties":{"é":{"type":"bool","value":true},"e\u0301":{"type":"bool","value":false}}}}"#.utf8)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let value = try EditorPreviewProperties(project: parsed)
        XCTAssertEqual(value.rows.count, 2, "Distinct source keys must remain visible with their own raw declarations")
        XCTAssertEqual(Set(value.rows.map { Data($0.name.utf8) }).count, 2)
        XCTAssertEqual(value.defaults.count, 2)
        XCTAssertEqual(value.defaults["é"], .bool(true)); XCTAssertEqual(value.defaults["e\u{0301}"], .bool(false))
    }
    func testCanonicalAliasNamesAcknowledgeIndependentlyAndResetInOneExactDataCommand() async throws {
        let bytes = Data(#"{"general":{"properties":{"é":{"type":"bool","value":true},"e\u0301":{"type":"bool","value":false}}}}"#.utf8)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let properties = try EditorPreviewProperties(project: parsed), page = PreviewPageFixture()
        let session = EditorScenePreviewSession(makePage: { page }, properties: properties, cleanup: {})
        try session.start(); page.onReady?(); for _ in 0..<30 { await Task.yield() }
        try await session.setUserProperties(["é": false])
        XCTAssertEqual(session.propertyValues["é"], .bool(false)); XCTAssertEqual(session.propertyValues["e\u{0301}"], .bool(false))
        try await session.setUserProperties(["e\u{0301}": true])
        XCTAssertEqual(session.propertyValues["é"], .bool(false)); XCTAssertEqual(session.propertyValues["e\u{0301}"], .bool(true))
        XCTAssertEqual(page.propertyRequests.count, 2)
        XCTAssertEqual((page.propertyRequests[0].allKeys.first as? String).map { Data($0.utf8) }, Data("é".utf8))
        XCTAssertEqual((page.propertyRequests[1].allKeys.first as? String).map { Data($0.utf8) }, Data("e\u{0301}".utf8))
        try await session.resetUserProperties()
        XCTAssertEqual(page.propertyRequests.count, 3)
        let reset = try XCTUnwrap(page.propertyRequests.last)
        XCTAssertEqual(reset.count, 2)
        XCTAssertEqual(reset.object(forKey: "é" as NSString) as? Bool, true)
        XCTAssertEqual(reset.object(forKey: "e\u{0301}" as NSString) as? Bool, false)
        XCTAssertEqual(session.propertyValues.count, 2)
        XCTAssertEqual(session.propertyValues["é"], .bool(true)); XCTAssertEqual(session.propertyValues["e\u{0301}"], .bool(false))
        try await session.close()
    }
    func testInspectionFailureKeepsOrdinaryPlaybackAndSurvivesRestartWithoutPropertyCommands() async throws {
        let variants: [[String: Any]] = [
            ["general": NSNull()], ["general": ["properties": NSNull()]],
            ["preset": NSNull()], ["general": ["properties": NSNull()], "preset": NSNull()]
        ]
        for variant in variants {
            let inspection = Result { try EditorPreviewProperties(project: variant) }
            XCTAssertThrowsError(try inspection.get(), "The strict property parser still reports malformed metadata")
            let first = PreviewPageFixture(), next = PreviewPageFixture()
            var pages = [first, next]
            let session = EditorScenePreviewSession(makePage: { pages.removeFirst() }, cleanup: {})
            session.configurePropertyInspection(inspection)
            let failure = try XCTUnwrap(session.propertyInspectionFailure)
            try session.start(); first.onReady?(); for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(session.state, .playing); XCTAssertNil(session.failure)
            try await session.setPlaying(false); XCTAssertEqual(session.state, .paused)
            do { try await session.setUserProperties(["example": true]); XCTFail("Inspection failure must disable property commands") }
            catch { XCTAssertEqual(error.localizedDescription, failure.localizedDescription) }
            do { try await session.resetUserProperties(); XCTFail("Inspection failure must disable Reset") }
            catch { XCTAssertEqual(error.localizedDescription, failure.localizedDescription) }
            XCTAssertTrue(first.propertyRequests.isEmpty)
            try await session.restart(); next.onReady?(); for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(session.state, .playing); XCTAssertNil(session.failure)
            XCTAssertEqual(session.propertyInspectionFailure?.localizedDescription, failure.localizedDescription)
            XCTAssertTrue(next.propertyRequests.isEmpty); XCTAssertNotEqual(first.origin, session.origin)
            try await session.close(); XCTAssertEqual(session.state, .closed)
        }
    }
    func testInspectionFailureIsVisibleInFiveLanguagesInsteadOfAnEmptyCatalog() async throws {
        _ = NSApplication.shared
        let inspection = Result { try EditorPreviewProperties(project: ["general": NSNull()]) }
        let resources = try EditorNativeScenePreviewPage.runtimeDirectory().deletingLastPathComponent()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for language in ["en", "zh-Hans", "ja", "es", "fr"] {
            let bundle = try XCTUnwrap(Bundle(path: resources.appendingPathComponent(language + ".lproj").path))
            let t: (String) -> String = { bundle.localizedString(forKey: $0, value: nil, table: nil) }
            let page = PreviewPageFixture(), session = EditorScenePreviewSession(makePage: { page }, cleanup: {})
            session.configurePropertyInspection(inspection)
            let controller = EditorScenePreviewWindowController(session: session, title: "Inspection error", localize: t)
            try session.start(); page.onReady?(); for _ in 0..<30 { await Task.yield() }
            let content = try XCTUnwrap(controller.window?.contentView)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                controller.window?.appearance = NSAppearance(named: appearance); content.layoutSubtreeIfNeeded()
                let views = descendants(content)
                let error = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "editor-property-inspection-error" })
                XCTAssertNotEqual(t("previewPropertiesInspectionFailed"), "previewPropertiesInspectionFailed")
                XCTAssertTrue(error.stringValue.contains(t("previewPropertiesInspectionFailed")))
                XCTAssertTrue(error.stringValue.contains(try XCTUnwrap(session.propertyInspectionFailure).localizedDescription))
                XCTAssertFalse(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == t("previewPropertiesEmpty") })
                let reset = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "editor-property-reset" })
                XCTAssertFalse(reset.isEnabled)
            }
            XCTAssertEqual(session.state, .playing); XCTAssertTrue(page.propertyRequests.isEmpty)
            try await controller.requestClose()
        }
    }
    func testNativeRowsCommitOnlyValidInputAndFiveLanguageMinimumLayout() async throws {
        _ = NSApplication.shared
        let properties = try catalog(["flag": ["type": "bool", "value": true], "n": ["type": "slider", "value": 2],
            "rgb": ["type": "color", "value": "0.1 0.2 1"], "t": ["type": "textinput", "value": ""],
            "pick": ["type": "combo", "value": "a", "options": [["label": "A", "value": "a"]]],
            "file": ["type": "file", "value": "file.png"]])
        let resources = try EditorNativeScenePreviewPage.runtimeDirectory().deletingLastPathComponent()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for language in ["en", "zh-Hans", "ja", "es", "fr"] {
            let bundle = try XCTUnwrap(Bundle(path: resources.appendingPathComponent(language + ".lproj").path))
            let t: (String) -> String = { bundle.localizedString(forKey: $0, value: nil, table: nil) }
            let page = PreviewPageFixture()
            let session = EditorScenePreviewSession(makePage: { page }, properties: properties, cleanup: {})
            let controller = EditorScenePreviewWindowController(session: session, title: "Properties", localize: t)
            let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
            try session.start(); page.onReady?(); for _ in 0..<30 { await Task.yield() }
            window.setFrame(NSRect(origin: .zero, size: window.minSize), display: false)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance); content.layoutSubtreeIfNeeded()
                let views = descendants(content)
                let input = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "editor-property-input-n" })
                input.stringValue = "invalid"
                let apply = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "editor-property-apply-n" })
                apply.performClick(nil); for _ in 0..<10 { await Task.yield() }
                XCTAssertTrue(page.propertyRequests.isEmpty)
                XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.identifier?.rawValue == "editor-property-error-n" && !$0.stringValue.isEmpty })
                let reset = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "editor-property-reset" })
                XCTAssertNotEqual(reset.title, "previewPropertiesReset")
                reset.performClick(nil); for _ in 0..<30 { await Task.yield() }
                XCTAssertEqual(input.stringValue, "2.0", "An acknowledged reset must clear an invalid draft even when the default was already acknowledged")
                XCTAssertEqual(page.propertyRequests.count, 1)
                page.propertyRequests = []
                let footer = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first { $0.identifier?.rawValue == "editor-preview-footer-scroll" })
                XCTAssertGreaterThan(try XCTUnwrap(footer.documentView).bounds.height, footer.contentView.bounds.height)
                for view in views.filter({ !$0.isHidden && ($0 is NSButton || $0 is NSTextField || $0 is NSScrollView) }) {
                    view.scrollToVisible(view.bounds); content.layoutSubtreeIfNeeded()
                    let frame = view.convert(view.bounds, to: content)
                    XCTAssertGreaterThanOrEqual(frame.minX, -1, language); XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width + 1, language)
                }
            }
            try await controller.requestClose()
        }
    }

}
