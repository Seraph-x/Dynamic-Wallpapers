import Foundation
import UniformTypeIdentifiers
import Darwin
import WallpaperCore

struct WebProjectResource {
    let data: Data
    let mimeType: String
}

enum WebProjectProbe {
    static func inspect(_ reference: WebProjectReference) throws -> MediaItem {
        try reference.validate()
        let handle = try openResource(project: reference, relativePath: reference.entry)
        try handle.close()
        // A webpage has no intrinsic video dimensions; use a documented preview viewport.
        return MediaItem(url: reference.entryURL, kind: .web, width: 640, height: 360,
                         backend: .web, webProject: reference)
    }

    static func readResource(project: WebProjectReference, relativePath: String) throws -> WebProjectResource {
        let handle = try openResource(project: project, relativePath: relativePath)
        do {
            let data = try handle.readToEnd() ?? Data()
            try handle.close()
            let ext = (relativePath as NSString).pathExtension.lowercased()
            let mime = ["js": "text/javascript", "mjs": "text/javascript", "wasm": "application/wasm"]
            return WebProjectResource(data: data, mimeType: mime[ext] ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream")
        } catch {
            do { try handle.close() }
            catch let cleanup {
                throw WallpaperError("网页资源处理失败，且未能关闭文件。",
                    diagnostic: "资源处理：\(String(describing: error as NSError))\n关闭文件：\(String(describing: cleanup as NSError))")
            }
            throw error
        }
    }

    static func openResource(project: WebProjectReference, relativePath: String) throws -> FileHandle {
        try project.validate()
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0"),
              !relativePath.split(separator: "/").contains("..") else {
            throw WallpaperError("拒绝访问项目外资源：\(relativePath)。")
        }
        let root = project.root.resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw WallpaperError("网页项目目录不可用：\(project.root.path)。")
        }
        let resource = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resource, root: root) else { throw WallpaperError("资源符号链接越出网页项目：\(relativePath)。") }
        let descriptor = resource.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw systemError("无法打开网页资源 \(relativePath)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw systemError("无法检查资源文件") }
            guard info.st_mode & S_IFMT == S_IFREG else { throw WallpaperError("网页资源不是普通文件：\(relativePath)。") }
            // Check the opened file, not just a path resolved before open, to detect a replaced ancestor link.
            var actual = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &actual) == 0 else { throw systemError("无法核验打开的资源路径") }
            guard isInside(URL(fileURLWithPath: String(cString: actual)).standardizedFileURL, root: root) else {
                throw WallpaperError("打开的资源已越出网页项目：\(relativePath)。")
            }
            return handle
        } catch {
            do { try handle.close() }
            catch let cleanup {
                throw WallpaperError("网页资源处理失败，且未能关闭文件。",
                    diagnostic: "资源处理：\(String(describing: error as NSError))\n关闭文件：\(String(describing: cleanup as NSError))")
            }
            throw error
        }
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let components = url.pathComponents, base = root.pathComponents
        return components.count > base.count && components.starts(with: base)
    }
    private static func systemError(_ action: String) -> WallpaperError {
        let code = errno
        return WallpaperError("\(action)：\(String(cString: strerror(code)))。")
    }
}
