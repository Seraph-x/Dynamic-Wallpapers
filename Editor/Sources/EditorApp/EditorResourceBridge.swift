import Foundation
import WallpaperCore
import WallpaperEditorCore

enum EditorResourceBridge {
    static func result(_ request: [String:Any], store: EditorProjectStore, id: UUID) async -> [String:Any] {
        do {
            switch request["action"] as? String {
            case "stage":
                guard let encoded = request["data"] as? String, let data = Data(base64Encoded: encoded),
                      data.base64EncodedString() == encoded else { throw WallpaperError("Invalid Editor resource bytes") }
                let version = try await store.stageResource(id: id, data: data)
                return ["version":version.id]
            case "read":
                guard let raw = request["version"] as? String else { throw WallpaperError("Missing Editor resource version") }
                let data = try await store.resource(id: id, version: EditorResourceVersion(id: raw))
                return ["data":data.base64EncodedString()]
            default: throw WallpaperError("Unknown Editor resource operation")
            }
        } catch { return ["error":error.localizedDescription] }
    }
}
