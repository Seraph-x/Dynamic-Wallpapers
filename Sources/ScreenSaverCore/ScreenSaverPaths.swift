import Foundation

public struct ScreenSaverPaths: Sendable {
    public let root: URL
    public init(root: URL) throws {
        guard root.isFileURL, root.host == nil || root.host == "" || root.host == "localhost", !root.path.contains("\0") else {
            throw ScreenSaverFailure(code: .invalidPath(root.path))
        }
        self.root = root.standardizedFileURL
    }
    public var identity: URL { root.appendingPathComponent("export.json") }
    public var publicationLock: URL { root.appendingPathComponent(".publication.lock") }
    public var catalogLock: URL { root.appendingPathComponent(".catalog.lock") }
    public var current: URL { root.appendingPathComponent("current.json") }
    public var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
    public var generations: URL { root.appendingPathComponent("generations", isDirectory: true) }
    public func generation(_ id: UUID) -> URL { generations.appendingPathComponent(id.uuidString, isDirectory: true) }

    static func components(_ relativePath: String) throws -> [String] {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.contains("\0"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ScreenSaverFailure(code: .invalidPath(relativePath))
        }
        return parts
    }

    public static func validateMediaPath(_ relativePath: String) throws {
        let parts = try components(relativePath)
        guard parts.count >= 2, parts[0] == "media" else {
            throw ScreenSaverFailure(code: .invalidPath(relativePath))
        }
    }
}
