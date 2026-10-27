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
        let session = try await store.acquireResourceSession(id: owned.document.id)
        defer { withExtendedLifetime(session) {} }
        let staged=await EditorResourceBridge.result(["action":"stage","data":"AQI="],store:store,id:owned.document.id,session:session)
        let id=try XCTUnwrap(staged["version"] as? String), version=try EditorResourceVersion(id:id)
        let saved=try await store.save(owned.document,scene:owned.document.scene,project:owned.document.project,title:owned.document.title,resourceOverrides:["body.mdl":version])
        let listed=await EditorResourceBridge.result(["action":"list"],store:store,id:saved.id,session:session)
        let paths=try XCTUnwrap(listed["paths"] as? [String])
        XCTAssertTrue(paths.contains("body.mdl"));XCTAssertTrue(paths.contains("scene.json"))
        let unknown=await EditorResourceBridge.result(["action":"list"],store:store,id:UUID(),session:session)
        XCTAssertNotNil(unknown["error"])
        let read=await EditorResourceBridge.result(["action":"read","version":id],store:store,id:saved.id,session:session)
        XCTAssertEqual(read["data"] as? String,"AQI=")
        let snapshot=try await EditorWindowController.browserDocument(saved)
        XCTAssertEqual(snapshot["resourceOverrides"] as? [String:String],["body.mdl":id])
        let malformed=await EditorResourceBridge.result(["action":"stage","data":"not base64!"],store:store,id:saved.id,session:session)
        XCTAssertNotNil(malformed["error"])
        let other=try await store.create(title:"Other",width:10,height:10)
        let denied=await EditorResourceBridge.result(["action":"read","version":id],store:store,id:other.document.id,session:session)
        XCTAssertNotNil(denied["error"])
        let reset=try await store.save(saved,scene:saved.scene,project:saved.project,title:saved.title,resourceOverrides:[:])
        XCTAssertEqual(reset.schemaVersion,2)
        let emptySnapshot=try await EditorWindowController.browserDocument(reset)
        XCTAssertNil(emptySnapshot["resourceOverrides"],"Empty overrides must match the browser after undo and save")
        let reopened=try await store.open(id:reset.id)
        XCTAssertEqual(reopened.document,reset)
    }
}
