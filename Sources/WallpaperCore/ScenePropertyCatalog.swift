import Foundation

public struct ScenePropertyCatalog: Sendable {
    public let projectJSON: Data
    public let rows: [ScenePropertyDefinition]
    private let definitions: [Data: ScenePropertyDefinition]

    public init(projectJSON: Data) throws {
        guard let project = try ScenePropertyJSON.parse(projectJSON).object else {
            throw WallpaperError("场景属性元数据必须是对象。")
        }
        let general = try Self.object(project, "general")
        let properties = try general.map { try Self.object($0, "properties") } ?? nil
        let preset = try Self.object(project, "preset")
        var rows: [ScenePropertyDefinition] = [], identities = Set<Data>()
        // Object member identities use exact UTF-8 bytes and retain the pin's
        // last-member-wins behavior, independent of Foundation dictionary policy.
        for (object, presetOnly) in [(properties, false), (preset, true)] {
            guard let object else { continue }
            for member in object.members {
                let name = member.name, raw = member.value
                guard identities.insert(Data(name.utf8)).inserted else { continue }
                rows.append(ScenePropertyDefinition(name: name, raw: raw, presetOnly: presetOnly))
            }
        }
        rows.sort {
            let left = $0.order ?? .infinity, right = $1.order ?? .infinity
            return left == right ? Array($0.name.utf16).lexicographicallyPrecedes(Array($1.name.utf16)) : left < right
        }
        self.projectJSON = projectJSON; self.rows = rows
        definitions = Dictionary(uniqueKeysWithValues: rows.map { ($0.identity, $0) })
    }

    public func validate(overrides: [ScenePropertyOverride]) throws {
        try ScenePropertyOverride.validate(overrides)
        for entry in overrides {
            guard let definition = definitions[entry.identity] else { throw WallpaperError("未知场景属性：\(entry.name)。") }
            guard definition.readOnlyReason == nil else { throw WallpaperError("场景属性只读：\(entry.name)（\(definition.readOnlyReason!.rawValue)）。") }
            guard definition.accepts(entry.value) else { throw WallpaperError("场景属性值无效：\(entry.name)。") }
        }
    }

    public func resolvedValues(overrides: [ScenePropertyOverride]) throws -> [ScenePropertyOverride] {
        try validate(overrides: overrides)
        let values = Dictionary(uniqueKeysWithValues: overrides.map { ($0.identity, $0.value) })
        return rows.compactMap { row in
            guard row.readOnlyReason == nil, let value = values[row.identity] ?? row.defaultValue else { return nil }
            return ScenePropertyOverride(name: row.name, value: value)
        }
    }

    public func wireJSON(overrides: [ScenePropertyOverride]) throws -> Data {
        try validate(overrides: overrides)
        let encoder = JSONEncoder()
        var result = Data("{".utf8)
        for (index, entry) in overrides.enumerated() {
            if index > 0 { result.append(contentsOf: ",".utf8) }
            result.append(try encoder.encode(entry.name)); result.append(contentsOf: ":".utf8)
            result.append(try encoder.encode(entry.value))
        }
        result.append(contentsOf: "}".utf8)
        return result
    }

    private static func object(_ parent: ScenePropertyJSON.Object, _ key: String) throws -> ScenePropertyJSON.Object? {
        guard let value = parent[key] else { return nil }
        guard let object = value.object else { throw WallpaperError("场景属性元数据对象无效：\(key)。") }
        return object
    }
}
