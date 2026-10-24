import CryptoKit
import Foundation
import WallpaperCore

public struct EditorResourceVersion: Hashable, Sendable {
    public let id: String
    public init(id: String) throws {
        guard id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw WallpaperError("Invalid Editor resource version")
        }
        self.id = id
    }
    init(data: Data) { id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension EditorProjectDocument {
    static func resourcePathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))
    }
    static func validateResourcePath(_ path: String, entry: String, package: String?) throws {
        try SceneProjectReference.validateRelativePath(path)
        let key = resourcePathKey(path)
        guard ![entry,"project.json",package].compactMap({$0}).map(resourcePathKey).contains(key) else { throw WallpaperError("Reserved Editor resource path") }
    }
}
