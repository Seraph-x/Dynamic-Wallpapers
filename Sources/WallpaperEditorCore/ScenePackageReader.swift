import Foundation
import WallpaperCore

/// Checked, read-only PKGV0012–0023 table. Entry data is copied only when requested.
public struct ScenePackageReader: Sendable {
    private let data: Data
    private let entries: [String: Range<Int>]
    public let paths: [String]

    public init(data: Data) throws {
        var cursor = 0
        func bytes(_ count: Int) throws -> Data {
            guard count >= 0, cursor <= data.count, count <= data.count - cursor else {
                throw WallpaperError("PKG 入口表越界或被截断。")
            }
            defer { cursor += count }
            return data.subdata(in: cursor..<(cursor + count))
        }
        func number() throws -> Int {
            let value = try bytes(4)
            return value.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        }
        guard try number() == 8, let magic = String(data: try bytes(8), encoding: .ascii),
              magic.hasPrefix("PKGV"), let version = Int(magic.dropFirst(4)), (12...23).contains(version),
              magic == String(format: "PKGV%04d", version) else {
            throw WallpaperError("不支持的 PKG 容器版本。")
        }
        let count = try number()
        guard count <= (data.count - cursor) / 13 else { throw WallpaperError("PKG 入口数量超出文件长度。") }
        var table: [(String, Int, Int)] = [], names = Set<String>()
        for _ in 0..<count {
            let length = try number()
            guard let path = String(data: try bytes(length), encoding: .utf8) else { throw WallpaperError("PKG 路径不是 UTF-8。") }
            try SceneProjectReference.validateRelativePath(path)
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(key).inserted else { throw WallpaperError("PKG 包含重复或大小写冲突的路径。") }
            table.append((path, try number(), try number()))
        }
        for name in names {
            var parent = name as NSString
            while parent.deletingLastPathComponent != "" {
                let path = parent.deletingLastPathComponent
                guard !names.contains(path) else { throw WallpaperError("PKG 文件与目录路径冲突。") }
                parent = path as NSString
            }
        }
        var entries: [String: Range<Int>] = [:], ranges: [Range<Int>] = []
        for (path, offset, length) in table {
            guard offset <= data.count - cursor, length <= data.count - cursor - offset else { throw WallpaperError("PKG 资源超出容器长度。") }
            let range = (cursor + offset)..<(cursor + offset + length)
            entries[path] = range
            if !range.isEmpty { ranges.append(range) }
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in sorted.indices.dropFirst() where sorted[index].lowerBound < sorted[index - 1].upperBound {
            throw WallpaperError("PKG 资源区域互相重叠。")
        }
        self.data = data; self.entries = entries; paths = table.map { $0.0 }
    }

    public func read(_ path: String) throws -> Data {
        guard let range = entries[path] else { throw WallpaperError("PKG 缺少资源：\(path)。") }
        return data.subdata(in: range)
    }
}
