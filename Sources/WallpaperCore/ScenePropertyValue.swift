import Foundation

public enum ScenePropertyValue: Codable, Equatable, Sendable {
    case boolean(Bool)
    case number(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .boolean(flag) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Scene property values must be finite JSON scalars") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .boolean(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite else { throw WallpaperError("场景属性必须是有限数值。") }
            try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return Data(a.utf8) == Data(b.utf8)
        default: return false
        }
    }
}

public struct ScenePropertyOverride: Codable, Equatable, Sendable {
    public let name: String
    public let value: ScenePropertyValue
    public var identity: Data { Data(name.utf8) }

    public init(name: String, value: ScenePropertyValue) { self.name = name; self.value = value }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.value == rhs.value
    }

    public static func validate(_ overrides: [Self]) throws {
        var identities = Set<Data>()
        for entry in overrides {
            guard identities.insert(entry.identity).inserted else { throw WallpaperError("场景属性重复：\(entry.name)。") }
            if case .number(let value) = entry.value, !value.isFinite { throw WallpaperError("场景属性必须是有限数值：\(entry.name)。") }
        }
    }
}
