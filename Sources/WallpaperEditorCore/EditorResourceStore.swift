import Foundation
import WallpaperCore

extension EditorProjectStore {
    public func stageResource(id: UUID, data: Data) throws -> EditorResourceVersion {
        _ = try open(id: id)
        let files = EditorProjectFiles(root: directory, prefix: id.uuidString)
        let version = EditorResourceVersion(data: data)
        return try files.locked { scoped in
            try scoped.withDirectory("Resources", create: true) { _ in }
            let path = "Resources/" + version.id
            if try scoped.containsFile(path) {
                guard try scoped.read(path) == data else { throw WallpaperError("Editor resource version is corrupt") }
            } else { try scoped.write(data, to: path) }
            return version
        }
    }
    public func resource(id: UUID, version: EditorResourceVersion) throws -> Data {
        _ = try open(id: id)
        return try resourceBytes(id: id, version: version)
    }
    func resourceBytes(id: UUID, version: EditorResourceVersion) throws -> Data {
        let bytes = try EditorProjectFiles(root: directory, prefix: id.uuidString).read("Resources/" + version.id)
        guard EditorResourceVersion(data: bytes) == version else { throw WallpaperError("Editor resource version is corrupt") }
        return bytes
    }
    func validateResources(_ document: EditorProjectDocument) throws {
        for version in Set(document.resourceOverrides.values) { _ = try resourceBytes(id: document.id, version: version) }
    }
}
