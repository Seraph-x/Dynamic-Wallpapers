import Darwin
import Foundation
import WallpaperCore

public struct EditorImageResource: Sendable {
    public let model: String
    public let texture: String
}

extension EditorProjectStore {
    public func resourcePaths(id: UUID) throws -> [String] {
        let document = try open(id: id).document
        return try Set(EditorProjectFiles(root: directory, prefix: "\(id.uuidString)/Project").paths())
            .union(document.resourceOverrides.keys).sorted()
    }
    public func addImage(id: UUID, data: Data, extension suffix: String, width: Int, height: Int) throws -> EditorImageResource {
        _ = try open(id: id)
        guard ["png", "jpg"].contains(suffix), !data.isEmpty, width > 0, height > 0 else { throw WallpaperError("图片格式或尺寸无效。") }
        let files = EditorProjectFiles(root: directory, prefix: "\(id.uuidString)/Project")
        let slug = UUID().uuidString.lowercased(), model = "models/editor/\(slug).json", material = "materials/editor/\(slug).json"
        let texture = "materials/editor/\(slug).\(suffix)"
        // Unique immutable resources remain available across undo and saved revisions.
        try files.write(data, to: texture)
        try files.write(EditorProjectDocument.encode(["material": material, "width": width, "height": height]), to: model)
        try files.write(EditorProjectDocument.encode(["passes": [["blending": "translucent", "cullmode": "nocull", "depthtest": "disabled",
            "depthwrite": "disabled", "shader": "genericimage2", "textures": ["editor/\(slug)"]]]]), to: material)
        return EditorImageResource(model: model, texture: texture)
    }
    public func exportPackage(_ document: EditorProjectDocument, package: Data, to destination: URL) async throws -> SceneProjectReference {
        let reader = try ScenePackageReader(data: package)
        let scene = try EditorProjectDocument.object(reader.read("scene.json"))
        guard NSDictionary(dictionary: scene).isEqual(to: try EditorProjectDocument.object(document.scene)) else { throw WallpaperError("PKG 场景与当前保存的工程不符。") }
        let staged = destination.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(".editor-pkg-\(UUID().uuidString)")
        _ = try await exportLoose(document, to: staged)
        do {
            let files = EditorProjectFiles(root: staged)
            var metadata = try EditorProjectDocument.object(document.project)
            metadata["file"] = "scene.pkg"; metadata["title"] = document.title
            try files.write(package, to: "scene.pkg"); try files.write(EditorProjectDocument.encode(metadata), to: "project.json")
            for path in Set([document.sceneEntry, "scene.json"]) where FileManager.default.fileExists(atPath: staged.appendingPathComponent(path).path) { try files.remove(path) }
            guard destination.isFileURL, [nil,"","localhost"].contains(destination.host), !destination.path.contains("\0"),
                  renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw WallpaperError("无法发布 PKG 导出，未覆盖已有目标。") }
        } catch {
            do { try FileManager.default.removeItem(at: staged) } catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
            throw error
        }
        return SceneProjectReference(root: destination, entry: "scene.pkg", representation: .package)
    }
}
