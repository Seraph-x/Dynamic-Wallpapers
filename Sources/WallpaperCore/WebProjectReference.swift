import Foundation

public enum MediaBackend: String, Codable, Sendable { case native, extended, web }

public struct WebProjectReference: Codable, Equatable, Sendable {
    public let root: URL
    public let entry: String
    public init(root: URL, entry: String) { self.root = root; self.entry = entry }
    public var entryURL: URL { root.appendingPathComponent(entry) }

    /// Validates persisted syntax only; the resource handler must recheck resolved filesystem boundaries on access.
    public func validate() throws {
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        guard root.isFileURL, root.host == nil || root.host == "" || root.host == "localhost",
              !entry.isEmpty, !entry.contains("\0"), !entry.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              ["html", "htm"].contains(entryURL.pathExtension.lowercased()) else {
            throw WallpaperError("网页项目需要本地根目录及项目内的相对 HTML 入口。")
        }
    }
}
