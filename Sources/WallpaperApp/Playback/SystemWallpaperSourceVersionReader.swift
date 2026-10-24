import CryptoKit
import Foundation
import WallpaperCore

/// Metadata work stays off the main actor; the result belongs to a particular media preparation.
actor SystemWallpaperSourceVersionReader {
    static let changedSource = WallpaperError("素材文件已变化，请重新应用壁纸后再同步系统底图。")

    func record(_ item: MediaItem) throws -> Result<String, WallpaperError> {
        do { return .success(try Self.fingerprint(for: item)) }
        catch is CancellationError { throw CancellationError() }
        catch let error as WallpaperError { return .failure(error) }
        catch {
            return .failure(WallpaperError("无法读取系统底图素材版本。", diagnostic: FailureDiagnostics.describe(error)))
        }
    }

    // Also used by the poster store's background actor when validating a recorded version.
    static func fingerprint(for item: MediaItem) throws -> String {
        try Task.checkCancellation()
        guard item.url.isFileURL else { throw WallpaperError("系统底图需要本地素材。") }
        var parts = ["source-v1"]
        try item.webProject?.validate()
        try item.sceneProject?.validate()
        let project = item.webProject.map { (root: $0.root, entryURL: $0.entryURL, entry: $0.entry) }
            ?? item.sceneProject.map { (root: $0.root, entryURL: $0.entryURL, entry: $0.entry) }
        if let project {
            let root = project.root.resolvingSymlinksInPath().standardizedFileURL
            let entry = project.entryURL.resolvingSymlinksInPath().standardizedFileURL
            guard isInside(entry, root: root) else {
                throw WallpaperError("资源符号链接越出网页项目：\(project.entry)。")
            }
            parts += try resourceVersion(project.entryURL, projectRoot: root)
            parts += try projectVersion(root)
        } else { parts += try resourceVersion(item.url) }
        let data = try JSONEncoder().encode(parts)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func resourceVersion(_ url: URL, projectRoot: URL? = nil) throws -> [String] {
        var version = try metadata(url)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved != url.standardizedFileURL else { return version }
        // Unused external web links do not make the whole project invalid, nor authorize target reads.
        if let projectRoot, !isInside(resolved, root: projectRoot) { return version }
        version += try metadata(resolved)
        return version
    }

    private static func metadata(_ url: URL) throws -> [String] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber,
              let type = attributes[.type] as? FileAttributeType else {
            throw WallpaperError("无法读取系统底图素材版本。", diagnostic: url.path)
        }
        var version = [url.standardizedFileURL.path, type.rawValue, size.stringValue,
                       String(date.timeIntervalSince1970)]
        if let identity = attributes[.systemFileNumber] as? NSNumber { version.append(identity.stringValue) }
        if type == .typeSymbolicLink {
            version.append(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        }
        return version
    }

    private static func projectVersion(_ root: URL) throws -> [String] {
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw WallpaperError("网页项目目录不可用。", diagnostic: root.path)
        }
        var failure: Error?
        // Directory enumeration does not descend into symbolic links, avoiding cycles and external trees.
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, error in failure = error; return false }) else {
            throw WallpaperError("无法读取网页项目素材版本。", diagnostic: root.path)
        }
        var resources: [URL] = []
        while let file = files.nextObject() as? URL {
            try Task.checkCancellation()
            resources.append(file)
        }
        if let failure { throw failure }
        var version = try metadata(root)
        for file in resources.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            version += try resourceVersion(file, projectRoot: root)
        }
        return version
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        url.pathComponents.count > root.pathComponents.count && url.pathComponents.starts(with: root.pathComponents)
    }
}
