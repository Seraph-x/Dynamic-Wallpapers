import Darwin
import Foundation
import WallpaperCore

/// Editor-owned workspace data survives deletion of either application bundle.
public actor EditorProjectStore {
    public nonisolated let directory: URL
    private let media: ManagedMediaStore
    public init(directory: URL) {
        let media = ManagedMediaStore(directory: directory)
        self.directory = media.directory
        self.media = media
    }
    public func create(title: String, width: Int, height: Int) async throws -> EditorOwnedProject {
        guard width > 0, height > 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WallpaperError("请输入工程名称和正数画布尺寸。") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Editor-New-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            let files = EditorProjectFiles(root: temporary.resolvingSymlinksInPath())
            try files.write(EditorProjectDocument.encode(["type": "scene", "file": "scene.json", "title": title]), to: "project.json")
            try files.write(EditorProjectDocument.encode(["general": ["orthogonalprojection": ["width": width, "height": height],
                "clearenabled": true, "clearcolor": "0.08 0.08 0.1", "cameraparallax": false], "objects": []]), to: "scene.json")
            let project = try await importProject(root: temporary)
            try FileManager.default.removeItem(at: temporary)
            return project
        } catch {
            if FileManager.default.fileExists(atPath: temporary.path) {
                do { try FileManager.default.removeItem(at: temporary) } catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
            }
            throw error
        }
    }
    public func importProject(root: URL, expected: SceneProjectReference? = nil) async throws -> EditorOwnedProject {
        let source = EditorProjectFiles(root: root.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent))
        let metadataData = try source.read("project.json"), metadata = try EditorProjectDocument.object(metadataData)
        guard metadata["type"] as? String == "scene", let declared = metadata["file"] as? String else { throw WallpaperError("请选择 scene 工程目录。") }
        try SceneProjectReference.validateRelativePath(declared)
        guard declared != "project.json" else { throw WallpaperError("工程入口不能是元数据文件。") }
        let entry: String
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(declared).path) { entry = declared }
        else if declared == "scene.json", FileManager.default.fileExists(atPath: root.appendingPathComponent("scene.pkg").path) { entry = "scene.pkg" }
        else { throw WallpaperError("工程缺少声明的场景入口。") }
        let representation: SceneRepresentation
        switch (entry as NSString).pathExtension.lowercased() {
        case "json": representation = .loose
        case "pkg": representation = .package
        default: throw WallpaperError("场景入口必须是 JSON 或 PKG。")
        }
        if let expected {
            try expected.validate()
            guard expected.root.standardizedFileURL == root.standardizedFileURL,
                  expected.entry == entry, expected.representation == representation else { throw WallpaperError("场景请求与工程元数据选择的入口不符。") }
        }
        let copy = try await media.stage(source: .scene(SceneProjectReference(root: root, entry: entry, representation: representation)))
        do {
            let resources = try require(copy.stagedSceneProject).root
            let files = EditorProjectFiles(root: directory, prefix: ".import-\(copy.id.uuidString)/Project")
            let sceneEntry: String
            if representation == .package {
                let package = try ScenePackageReader(data: files.read(entry))
                guard package.paths.contains("scene.json") else { throw WallpaperError("PKG 缺少 scene.json。") }
                for path in package.paths {
                    let bytes = try package.read(path)
                    if FileManager.default.fileExists(atPath: resources.appendingPathComponent(path).path) {
                        guard try files.read(path) == bytes else { throw WallpaperError("PKG 与外部资源内容冲突：\(path)。") }
                    } else { try files.write(bytes, to: path) }
                }
                sceneEntry = "scene.json"
            } else { sceneEntry = entry }
            let document = try EditorProjectDocument(id: copy.id, revision: 0, title: metadata["title"] as? String ?? "Untitled",
                sceneEntry: sceneEntry, sourcePackage: representation == .package ? entry : nil,
                scene: files.read(sceneEntry), project: metadataData)
            try EditorProjectFiles(root: directory, prefix: ".import-\(copy.id.uuidString)").write(document.encoded(), to: "workspace.json")
            try await media.commit(copy)
            return EditorOwnedProject(document: document, resources: try require(copy.sceneProject).root)
        } catch {
            do { try await media.discard(copy) } catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
            throw error
        }
    }
    public func open(id: UUID) throws -> EditorOwnedProject {
        let root = directory.appendingPathComponent(id.uuidString)
        let document = try workspaceDocument(id: id)
        try validateResources(document)
        return EditorOwnedProject(document: document, resources: root.appendingPathComponent("Project"))
    }
    func workspaceDocument(id: UUID) throws -> EditorProjectDocument {
        let document = try EditorProjectDocument(data: EditorProjectFiles(root: directory, prefix: id.uuidString).read("workspace.json"))
        guard document.id == id else { throw WallpaperError("工程身份与目录不符。") }
        return document
    }
    public func save(_ previous: EditorProjectDocument, scene: Data, project: Data, title: String,
                     resourceOverrides: [String: EditorResourceVersion]? = nil) throws -> EditorProjectDocument {
        let files = EditorProjectFiles(root: directory, prefix: previous.id.uuidString)
        return try files.locked { files in
            let current = try EditorProjectDocument(data: files.read("workspace.json"))
            guard current == previous else { throw WallpaperError("磁盘上的工程已改变，请重新打开，未覆盖现有内容。") }
            guard current.revision < UInt64.max else { throw WallpaperError("工程修订号已耗尽。") }
            let next = try EditorProjectDocument(id: current.id, revision: current.revision + 1, title: title,
                sceneEntry: current.sceneEntry, sourcePackage: current.sourcePackage, scene: scene, project: project,
                resourceOverrides: resourceOverrides ?? current.resourceOverrides,
                schemaVersion: current.schemaVersion == 2 || !(resourceOverrides ?? current.resourceOverrides).isEmpty ? 2 : 1)
            try validateResources(next)
            try files.write(next.encoded(), to: "workspace.json")
            return next
        }
    }
    /// Creates a standard scene folder without replacing an existing destination.
    public func exportLoose(_ document: EditorProjectDocument, to destination: URL) async throws -> SceneProjectReference {
        let current = try open(id: document.id)
        guard current.document == document else { throw WallpaperError("请保存最新工程后再导出。") }
        return try await materializeLoose(document, resources: current.resources, to: destination)
    }
    /// Captures an unsaved revision without changing its saved workspace or original resources.
    public func exportPreview(_ draft: EditorProjectDocument, basedOn saved: EditorProjectDocument,
                              to destination: URL) async throws -> SceneProjectReference {
        let current = try validatePreview(draft, basedOn: saved)
        return try await materializeLoose(draft, resources: current.resources, to: destination, previewBaseline: saved)
    }
    private func validatePreview(_ draft: EditorProjectDocument, basedOn saved: EditorProjectDocument) throws -> EditorOwnedProject {
        guard draft.id == saved.id, draft.revision == saved.revision,
              draft.sceneEntry == saved.sceneEntry, draft.sourcePackage == saved.sourcePackage else {
            throw WallpaperError("预览草稿与已保存工程的身份、修订或入口不符。")
        }
        let current = try open(id: saved.id)
        guard current.document == saved else { throw WallpaperError("磁盘上的工程已改变，请重新打开后再预览。") }
        try validateResources(draft)
        return current
    }
    private func materializeLoose(_ document: EditorProjectDocument, resources: URL, to destination: URL,
                                  previewBaseline: EditorProjectDocument? = nil) async throws -> SceneProjectReference {
        let copy = try await media.stage(source: .scene(SceneProjectReference(root: resources, entry: document.sceneEntry, representation: .loose)))
        do {
            if let previewBaseline { _ = try validatePreview(document, basedOn: previewBaseline) }
            let root = try require(copy.stagedSceneProject).root
            let files = EditorProjectFiles(root: directory, prefix: ".import-\(copy.id.uuidString)/Project")
            var metadata = try EditorProjectDocument.object(document.project)
            metadata["file"] = document.sceneEntry; metadata["title"] = document.title
            try files.write(EditorProjectDocument.encode(metadata), to: "project.json")
            try files.write(document.scene, to: document.sceneEntry)
            for (path, version) in document.resourceOverrides {
                try files.write(resourceBytes(id: document.id, version: version), to: path)
            }
            if let container = document.sourcePackage { try files.remove(container) }
            guard destination.isFileURL, [nil, "", "localhost"].contains(destination.host), !destination.path.contains("\0") else { throw WallpaperError("导出目标必须是本地目录。") }
            // Cross-volume export is explicit: stage beside the destination, then publish atomically.
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".editor-export-\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: root, to: staged)
                try await media.discard(copy)
                // Both actor hops allow a save or resource change; publication must use the same baseline.
                if let previewBaseline { _ = try validatePreview(document, basedOn: previewBaseline) }
                guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw WallpaperError("无法发布导出，未覆盖目标：\(String(cString: strerror(errno)))。") }
            } catch {
                if FileManager.default.fileExists(atPath: staged.path) {
                    do { try FileManager.default.removeItem(at: staged) } catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
                }
                throw error
            }
            return SceneProjectReference(root: destination, entry: document.sceneEntry, representation: .loose)
        } catch {
            do { try await media.discard(copy) } catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
            throw error
        }
    }
    private func require(_ project: SceneProjectReference?) throws -> SceneProjectReference {
        guard let project else { throw WallpaperError("托管副本缺少场景引用。") }; return project
    }
}
