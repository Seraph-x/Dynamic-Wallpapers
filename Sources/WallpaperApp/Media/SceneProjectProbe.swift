import Darwin
import Foundation
import WallpaperCore

struct ScenePropertyCatalogCapture: Sendable {
    let project: SceneProjectReference
    let catalog: ScenePropertyCatalog
    let device: UInt64
    let inode: UInt64
}

/// Inspects data only; scene execution is owned by the scene playback runtime.
enum SceneProjectProbe {
    static func background<T: Sendable>(_ read: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(operation: read)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func propertyCatalog(_ item: MediaItem) throws -> ScenePropertyCatalogCapture {
        guard item.kind == .scene, item.backend == .scene, let reference = item.sceneProject else {
            throw WallpaperError("壁纸没有场景属性。")
        }
        try reference.validate()
        let files = try SceneProjectFiles(root: reference.root)
        defer { files.close() }
        let metadata = try files.read("project.json")
        guard try inspect(root: reference.root, files: files, metadata: metadata).sceneProject == reference else {
            throw WallpaperError("场景引用与项目元数据选择的入口不一致。")
        }
        let identity = try files.identity()
        return ScenePropertyCatalogCapture(project: reference,
            catalog: try ScenePropertyCatalog(projectJSON: metadata),
            device: identity.device, inode: identity.inode)
    }

    static func revalidate(_ capture: ScenePropertyCatalogCapture) throws {
        try capture.project.validate()
        let files = try SceneProjectFiles(root: capture.project.root)
        defer { files.close() }
        let identity = try files.identity()
        guard identity.device == capture.device, identity.inode == capture.inode,
              try files.read("project.json") == capture.catalog.projectJSON else {
            throw WallpaperError("场景元数据已变化，请重新载入属性。")
        }
    }
    static func inspect(root: URL) throws -> MediaItem {
        try Task.checkCancellation()
        guard root.isFileURL, [nil, "", "localhost"].contains(root.host), !root.path.contains("\0") else {
            throw WallpaperError("场景项目必须位于本地目录。")
        }
        let files = try SceneProjectFiles(root: root)
        defer { files.close() }
        let metadata = try files.read("project.json")
        return try inspect(root: root, files: files, metadata: metadata)
    }

    private static func inspect(root: URL, files: SceneProjectFiles, metadata: Data) throws -> MediaItem {
        let declaration = try SceneProjectDeclaration(json: metadata)
        guard let type = declaration.type, type.lowercased() == "scene", let declared = declaration.file else {
            throw WallpaperError("project.json 必须声明场景类型和入口文件。")
        }
        try SceneProjectReference.validateRelativePath(declared)
        guard declared.lowercased() != "project.json" else {
            throw WallpaperError("场景入口不能是项目元数据。")
        }
        let ext = (declared as NSString).pathExtension.lowercased()
        guard ext == "json" || ext == "pkg" else { throw WallpaperError("场景入口必须是 JSON 或 PKG。") }
        let entry: String
        let data: Data
        if let declaredData = try files.readIfPresent(declared, headerOnly: ext == "pkg") {
            entry = declared; data = declaredData
        } else if declared == "scene.json", let package = try files.readIfPresent("scene.pkg", headerOnly: true) {
            // Wallpaper Engine commonly declares scene.json while shipping scene.pkg.
            entry = "scene.pkg"; data = package
        } else {
            throw WallpaperError("找不到声明的场景入口：\(declared)。")
        }
        try Task.checkCancellation()
        let representation: SceneRepresentation = entry.lowercased().hasSuffix(".pkg") ? .package : .loose
        if representation == .loose {
            _ = try SceneProjectDeclaration(json: data)
        } else {
            guard data.count == 12, data.prefix(4) == Data([8, 0, 0, 0]),
                  data.subdata(in: 4..<8) == Data("PKGV".utf8),
                  data.suffix(4).allSatisfy({ (48...57).contains($0) }) else {
                throw WallpaperError("场景包缺少 PKGV 文件头。")
            }
        }
        let reference = SceneProjectReference(root: root, entry: entry, representation: representation)
        try reference.validate()
        // Scenes have no authoritative decoded video size; the renderer resizes this preview viewport.
        return MediaItem(url: reference.entryURL, kind: .scene, width: 640, height: 360,
                         backend: .scene, sceneProject: reference, customName: declaration.title)
    }

    static func inspect(_ reference: SceneProjectReference) throws -> MediaItem {
        try reference.validate()
        let item = try inspect(root: reference.root)
        guard item.sceneProject == reference else {
            throw WallpaperError("场景引用与项目元数据选择的入口不一致。")
        }
        return item
    }
}

/// Each path component is opened relative to its parent descriptor, never through a symlink.
private final class SceneProjectFiles {
    private let descriptor: Int32
    init(root: URL) throws {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        descriptor = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure("无法打开场景项目目录") }
    }
    func close() { Darwin.close(descriptor) }
    func identity() throws -> (device: UInt64, inode: UInt64) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.failure("无法检查场景项目目录") }
        return (UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))
    }
    func read(_ path: String) throws -> Data {
        guard let data = try readIfPresent(path) else { throw WallpaperError("场景项目缺少资源：\(path)。") }
        return data
    }
    func readIfPresent(_ path: String, headerOnly: Bool = false) throws -> Data? {
        try Task.checkCancellation()
        try SceneProjectReference.validateRelativePath(path)
        let parts = path.split(separator: "/").map(String.init)
        var parent = descriptor
        var opened: [Int32] = []
        defer { for fd in opened.reversed() { Darwin.close(fd) } }
        for component in parts.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                if errno == ENOENT { return nil }
                throw Self.failure("无法打开场景资源目录 \(component)")
            }
            opened.append(next); parent = next
        }
        let file = openat(parent, parts.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw Self.failure("无法打开场景资源 \(path)")
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(file, &info) == 0 else { throw Self.failure("无法检查场景资源 \(path)") }
            guard info.st_mode & S_IFMT == S_IFREG else { throw WallpaperError("场景资源必须是普通文件：\(path)。") }
            let data = try (headerOnly ? handle.read(upToCount: 12) : handle.readToEnd()) ?? Data()
            try handle.close()
            return data
        } catch {
            do { try handle.close() }
            catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
            throw error
        }
    }
    private static func failure(_ action: String) -> WallpaperError {
        let code = errno
        return WallpaperError("\(action)：\(String(cString: strerror(code)))。")
    }
}
