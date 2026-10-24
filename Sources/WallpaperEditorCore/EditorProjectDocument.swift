import Foundation
import CoreFoundation
import WallpaperCore

public struct EditorProjectDocument: Equatable, Sendable {
    public let id: UUID
    public let revision: UInt64
    public let title: String
    public let sceneEntry: String
    public let sourcePackage: String?
    public let scene: Data
    public let project: Data
    public let schemaVersion: Int
    public let resourceOverrides: [String: EditorResourceVersion]

    public init(id: UUID, revision: UInt64, title: String, sceneEntry: String,
                sourcePackage: String?, scene: Data, project: Data,
                resourceOverrides: [String: EditorResourceVersion] = [:], schemaVersion: Int? = nil) throws {
        try SceneProjectReference.validateRelativePath(sceneEntry)
        guard sceneEntry.hasSuffix(".json"), sceneEntry != "project.json",
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WallpaperError("工程缺少名称或有效场景入口。") }
        if let sourcePackage { try SceneProjectReference.validateRelativePath(sourcePackage) }
        _ = try Self.object(scene); let metadata = try Self.object(project)
        guard metadata["type"] as? String == "scene" else { throw WallpaperError("工程类型必须为 scene。") }
        let schema = schemaVersion ?? (resourceOverrides.isEmpty ? 1 : 2)
        guard [1,2].contains(schema), schema == 2 || resourceOverrides.isEmpty else { throw WallpaperError("Invalid resource workspace schema") }
        for path in resourceOverrides.keys { try Self.validateResourcePath(path, entry: sceneEntry, package: sourcePackage) }
        self.schemaVersion = schema; self.resourceOverrides = resourceOverrides
        self.id = id; self.revision = revision; self.title = title; self.sceneEntry = sceneEntry
        self.sourcePackage = sourcePackage; self.scene = try Self.encode(Self.object(scene)); self.project = try Self.encode(metadata)
    }

    public init(data: Data) throws {
        let object = try Self.object(data)
        guard let schema = object["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), [1,2].contains(schema),
              let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)),
              let number = object["revision"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let revision = UInt64(number.stringValue), let title = object["title"] as? String,
              let entry = object["sceneEntry"] as? String, let scene = object["scene"], let project = object["project"],
              Set(object.keys).isSubset(of: ["schema", "id", "revision", "title", "sceneEntry", "sourcePackage", "scene", "project", "resourceOverrides"]),
              object["sourcePackage"] == nil || object["sourcePackage"] is String else { throw WallpaperError("工程工作文档格式或版本无效。") }
        let overrides: [String: EditorResourceVersion]
        if schema == 2, let raw = object["resourceOverrides"] as? [String:String] { overrides = try raw.mapValues { try EditorResourceVersion(id: $0) } }
        else if schema == 1, object["resourceOverrides"] == nil { overrides = [:] }
        else { throw WallpaperError("Invalid Editor resource overrides") }
        try self.init(id: id, revision: revision, title: title, sceneEntry: entry, sourcePackage: object["sourcePackage"] as? String,
                      scene: Self.encode(scene), project: Self.encode(project), resourceOverrides: overrides, schemaVersion: schema.intValue)
    }

    public func encoded() throws -> Data {
        var value: [String: Any] = ["schema": schemaVersion, "id": id.uuidString, "revision": revision, "title": title,
            "sceneEntry": sceneEntry, "scene": try Self.object(scene), "project": try Self.object(project)]
        if let sourcePackage { value["sourcePackage"] = sourcePackage }
        if schemaVersion == 2 { value["resourceOverrides"] = resourceOverrides.mapValues(\.id) }
        return try Self.encode(value)
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WallpaperError("场景及工程数据必须是 JSON 对象。") }
        return object
    }
    static func encode(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) }
}

public struct EditorOwnedProject: Sendable {
    public let document: EditorProjectDocument
    public let resources: URL
}
