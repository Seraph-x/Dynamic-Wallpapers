import Darwin
import Foundation
import WallpaperCore

/// Inspects data only; scene execution is owned by the scene playback runtime.
enum SceneProjectProbe {
    static func inspect(root: URL) throws -> MediaItem {
        try Task.checkCancellation()
        guard root.isFileURL, [nil, "", "localhost"].contains(root.host), !root.path.contains("\0") else {
            throw WallpaperError("场景项目必须位于本地目录。")
        }
        let files = try SceneProjectFiles(root: root)
        defer { files.close() }
        let metadata = try files.read("project.json")
        guard let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let type = object["type"] as? String, type.lowercased() == "scene",
              let declared = object["file"] as? String else {
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
            guard try JSONSerialization.jsonObject(with: data) is [String: Any] else {
                throw WallpaperError("场景 JSON 必须是对象。")
            }
        } else {
            guard data.count == 8, data.starts(with: Data("PKGV".utf8)) else { throw WallpaperError("场景包缺少 PKGV 文件头。") }
        }
        let reference = SceneProjectReference(root: root, entry: entry, representation: representation)
        try reference.validate()
        // Scenes have no authoritative decoded video size; the renderer resizes this preview viewport.
        return MediaItem(url: reference.entryURL, kind: .scene, width: 640, height: 360,
                         backend: .scene, sceneProject: reference, customName: object["title"] as? String)
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
            let data = try (headerOnly ? handle.read(upToCount: 8) : handle.readToEnd()) ?? Data()
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
