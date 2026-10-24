import Foundation

public enum SceneRepresentation: String, Codable, Sendable { case loose, package }

public struct SceneProjectReference: Codable, Equatable, Sendable {
    public let root: URL
    public let entry: String
    public let representation: SceneRepresentation

    public init(root: URL, entry: String, representation: SceneRepresentation) {
        self.root = root; self.entry = entry; self.representation = representation
    }
    public var entryURL: URL { root.appendingPathComponent(entry) }

    /// Syntax validation only. Readers must independently bind and verify filesystem access.
    public func validate() throws {
        try Self.validateRelativePath(entry)
        guard root.isFileURL, [nil, "", "localhost"].contains(root.host), !root.path.contains("\0"),
              entryURL.pathExtension.lowercased() == (representation == .loose ? "json" : "pkg") else {
            throw WallpaperError("场景项目需要本地根目录及匹配格式的 JSON 或 PKG 入口。")
        }
    }

    public static func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\0"), !path.contains("\\"), !path.contains(":"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WallpaperError("场景资源必须使用项目内的安全相对路径。")
        }
    }
}
