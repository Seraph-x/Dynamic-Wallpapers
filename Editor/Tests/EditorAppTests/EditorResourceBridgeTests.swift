import Foundation
import XCTest
import WallpaperEditorCore
@testable import EditorApp

final class EditorResourceBridgeTests: XCTestCase {
    func testRealNativeResourceBridgeAndSavedSnapshotRoundTrip() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at:root) }
        let store=EditorProjectStore(directory:root)
        let owned=try await store.create(title:"Bridge",width:10,height:10)
        let staged=await EditorResourceBridge.result(["action":"stage","data":"AQI="],store:store,id:owned.document.id)
        let id=try XCTUnwrap(staged["version"] as? String), version=try EditorResourceVersion(id:id)
        let saved=try await store.save(owned.document,scene:owned.document.scene,project:owned.document.project,title:owned.document.title,resourceOverrides:["body.mdl":version])
        let read=await EditorResourceBridge.result(["action":"read","version":id],store:store,id:saved.id)
        XCTAssertEqual(read["data"] as? String,"AQI=")
        let snapshot=try await EditorWindowController.browserDocument(saved)
        XCTAssertEqual(snapshot["resourceOverrides"] as? [String:String],["body.mdl":id])
        let malformed=await EditorResourceBridge.result(["action":"stage","data":"not base64!"],store:store,id:saved.id)
        XCTAssertNotNil(malformed["error"])
        let other=try await store.create(title:"Other",width:10,height:10)
        let denied=await EditorResourceBridge.result(["action":"read","version":id],store:store,id:other.document.id)
        XCTAssertNotNil(denied["error"])
        let reset=try await store.save(saved,scene:saved.scene,project:saved.project,title:saved.title,resourceOverrides:[:])
        XCTAssertEqual(reset.schemaVersion,2)
        let emptySnapshot=try await EditorWindowController.browserDocument(reset)
        XCTAssertNil(emptySnapshot["resourceOverrides"],"Empty overrides must match the browser after undo and save")
        let reopened=try await store.open(id:reset.id)
        XCTAssertEqual(reopened.document,reset)
    }
}
