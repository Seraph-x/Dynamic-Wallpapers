import CoreFoundation
import Darwin
import Foundation
import WallpaperCore

/// An owned, bytes-only selection. No filesystem authority is sent to the workbench.
public struct EditorModelImportSource: Sendable {
    public let entry: String
    public let files: [String: Data]

    public var commandSource: [String: Any] {
        ["entry": entry, "files": files.keys.sorted().map { ["path": $0, "data": files[$0]!.base64EncodedString()] }]
    }

    public init(url: URL) throws {
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host), url.query == nil, url.fragment == nil,
              !url.path.contains("\0"), ["gltf", "glb"].contains(url.pathExtension.lowercased()) else {
            throw WallpaperError("Select a local glTF or GLB model.")
        }
        let entry = url.lastPathComponent
        guard !Self.containsControl(entry) else { throw WallpaperError("Invalid model entry name.") }
        try SceneProjectReference.validateRelativePath(entry)
        let reader = EditorProjectFiles(root: url.deletingLastPathComponent())
        let files = try reader.withReadOnlyScope { scoped in
            try Self.validateDiskPath(entry, reader: scoped)
            let original = try scoped.read(entry)
            let container = try Self.container(original, binary: url.pathExtension.lowercased() == "glb")
            let references = try Self.references(container.json, binaryLength: container.binaryLength)
            try Self.validateAliases([entry] + references)
            // Validate every selected path before reading any external resource.
            for path in Set(references) { try Self.validateDiskPath(path, reader: scoped) }
            var files = [entry: original]
            for path in Set(references) where path != entry { files[path] = try scoped.read(path) }
            return files
        }
        self.entry = entry; self.files = files
    }

    private static func container(_ data: Data, binary: Bool) throws -> (json: Data, binaryLength: Int?) {
        if !binary { return (data, nil) }
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) }
        }
        guard data.count >= 12, word(0) == 0x46546c67, word(4) == 2, UInt64(word(8)) == UInt64(data.count) else {
            throw WallpaperError("Invalid GLB header or declared length.")
        }
        var offset = 12, index = 0
        var json: Data?, binaryLength: Int?
        while offset < data.count {
            guard data.count - offset >= 8 else { throw WallpaperError("Truncated GLB chunk header.") }
            let length = Int(word(offset)), type = word(offset + 4)
            offset += 8
            guard length % 4 == 0, length <= data.count - offset else { throw WallpaperError("Invalid GLB chunk bounds or alignment.") }
            if index == 0, type != 0x4e4f534a { throw WallpaperError("GLB must start with its JSON chunk.") }
            if type == 0x4e4f534a {
                guard index == 0, json == nil else { throw WallpaperError("GLB contains duplicate or misplaced JSON.") }
                json = data.subdata(in: offset..<(offset + length))
            } else if type == 0x004e4942 {
                guard index == 1, binaryLength == nil else { throw WallpaperError("GLB contains duplicate or misplaced BIN.") }
                binaryLength = length
            }
            offset += length; index += 1
        }
        guard let json else { throw WallpaperError("GLB JSON chunk is missing.") }
        return (json, binaryLength)
    }

    private static func references(_ data: Data, binaryLength: Int?) throws -> [String] {
        guard String(data: data, encoding: .utf8) != nil,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let asset = json["asset"] as? [String: Any], asset["version"] as? String == "2.0" else {
            throw metadataError()
        }
        func objects(_ key: String) throws -> [[String: Any]] {
            guard let value = json[key] else { return [] }
            guard let objects = value as? [[String: Any]] else { throw metadataError() }
            return objects
        }
        var uris: [String] = []
        for (index, buffer) in try objects("buffers").enumerated() {
            guard let length = integer(buffer["byteLength"]), length > 0 else { throw metadataError() }
            if let raw = buffer["uri"] {
                guard let uri = raw as? String, !uri.isEmpty else { throw metadataError() }
                uris.append(uri)
            } else {
                guard index == 0, let binaryLength, length <= binaryLength, binaryLength - length <= 3 else { throw metadataError() }
            }
        }
        for image in try objects("images") {
            if let raw = image["uri"] {
                guard let uri = raw as? String, !uri.isEmpty, image["bufferView"] == nil else { throw metadataError() }
                uris.append(uri)
            } else {
                guard let view = integer(image["bufferView"]), view >= 0,
                      let mime = image["mimeType"] as? String, ["image/png", "image/jpeg"].contains(mime),
                      view < (try objects("bufferViews")).count else { throw metadataError() }
            }
        }
        return try uris.compactMap { uri in
            if uri.lowercased().hasPrefix("data:") { return nil }
            return try relativeURI(uri)
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue < Double(Int.max) else { return nil }
        return number.intValue
    }
    private static func metadataError() -> WallpaperError { WallpaperError("Invalid glTF source metadata.") }

    private static func relativeURI(_ uri: String) throws -> String {
        let lower = uri.lowercased()
        guard !containsControl(uri),
              !uri.contains("?"), !uri.contains("#"), !lower.contains("%2f"), !lower.contains("%5c"),
              let decoded = uri.removingPercentEncoding, !containsControl(decoded) else { throw WallpaperError("Invalid model resource URI.") }
        try SceneProjectReference.validateRelativePath(decoded)
        return decoded
    }

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    private static func validateAliases(_ paths: [String]) throws {
        var spellings: [String: [UInt8]] = [:]
        var kinds: [String: Bool] = [:]
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            for index in components.indices {
                let prefix = components[...index].joined(separator: "/"), key = EditorProjectDocument.resourcePathKey(prefix)
                let bytes = Array(prefix.utf8), directory = index < components.count - 1
                guard spellings[key] == nil || spellings[key] == bytes,
                      kinds[key] == nil || kinds[key] == directory else {
                    throw WallpaperError("Model resource paths contain case, Unicode or directory aliases.")
                }
                spellings[key] = bytes; kinds[key] = directory
            }
        }
    }

    private static func validateDiskPath(_ path: String, reader: EditorProjectFiles) throws {
        var parent = ""
        for component in path.split(separator: "/").map(String.init) {
            try reader.withDirectory(parent) { descriptor in
                // A new open description keeps readdir from advancing the pinned root's offset.
                let duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard duplicate >= 0 else { throw WallpaperError("Cannot inspect the model resource directory.") }
                guard let stream = fdopendir(duplicate) else { close(duplicate); throw WallpaperError("Cannot inspect the model resource directory.") }
                defer { closedir(stream) }
                var matches: [String] = []
                while true {
                    errno = 0
                    guard let item = readdir(stream) else {
                        guard errno == 0 else { throw WallpaperError("Cannot inspect model resource names.") }
                        break
                    }
                    var bytes = item.pointee.d_name
                    let name = withUnsafePointer(to: &bytes) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
                    if EditorProjectDocument.resourcePathKey(name) == EditorProjectDocument.resourcePathKey(component) { matches.append(name) }
                }
                guard matches.count == 1,
                      matches[0].precomposedStringWithCanonicalMapping.utf8.elementsEqual(component.precomposedStringWithCanonicalMapping.utf8) else {
                    throw WallpaperError("Missing or ambiguous model resource path: \(path)")
                }
            }
            parent = parent.isEmpty ? component : parent + "/" + component
        }
    }
}
