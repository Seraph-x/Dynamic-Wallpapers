import Foundation
import WallpaperCore

extension EditorProjectStore {
    public func stageResource(id: UUID, data: Data) throws -> EditorResourceVersion {
        _ = try workspaceDocument(id: id)
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
        _ = try workspaceDocument(id: id)
        return try resourceBytes(id: id, version: version)
    }
    func resourceBytes(id: UUID, version: EditorResourceVersion) throws -> Data {
        let bytes = try EditorProjectFiles(root: directory, prefix: id.uuidString).read("Resources/" + version.id)
        guard EditorResourceVersion(data: bytes) == version else { throw WallpaperError("Editor resource version is corrupt") }
        return bytes
    }
    func validateResources(_ document: EditorProjectDocument) throws {
        if !document.resourceOverrides.isEmpty { try validateResourceInventory(document) }
        for version in Set(document.resourceOverrides.values) { _ = try resourceBytes(id: document.id, version: version) }
    }
    private func validateResourceInventory(_ document: EditorProjectDocument) throws {
        let original = try EditorProjectFiles(root: directory,prefix: "\(document.id.uuidString)/Project").paths()
        let paths = original + Array(document.resourceOverrides.keys)
        var files: [String:String] = [:], directories: [String:String] = [:]
        for path in paths {
            let key = EditorProjectDocument.resourcePathKey(path)
            if let existing = files[key], !existing.utf8.elementsEqual(path.utf8) { throw WallpaperError("Ambiguous resource path: \(path)") }
            files[key] = path
            let parts = path.split(separator:"/")
            for end in 1..<parts.count {
                let parent = parts[..<end].joined(separator:"/"), parentKey = EditorProjectDocument.resourcePathKey(parent)
                if let existing = directories[parentKey], !existing.utf8.elementsEqual(parent.utf8) { throw WallpaperError("Ambiguous resource directory: \(parent)") }
                directories[parentKey] = parent
            }
        }
        guard Set(files.keys).isDisjoint(with:directories.keys) else { throw WallpaperError("Resource file/directory conflict") }
    }
}
