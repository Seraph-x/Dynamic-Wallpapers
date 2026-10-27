import Foundation

/// Known project labels from exact JSON; unknown fields remain uninterpreted.
public struct SceneProjectDeclaration: Sendable {
    public let type: String?
    public let file: String?
    public let title: String?

    public init(json: Data) throws {
        guard let object = try ScenePropertyJSON.parse(json).object else {
            throw WallpaperError("场景 JSON 必须是对象。")
        }
        type = object["type"]?.string
        file = object["file"]?.string
        title = object["title"]?.string
    }
}
