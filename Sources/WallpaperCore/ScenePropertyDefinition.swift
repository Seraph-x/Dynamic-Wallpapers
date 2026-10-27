import Foundation

public enum ScenePropertyKind: String, Sendable { case bool, slider, color, textinput, combo }
public enum ScenePropertyReadOnlyReason: String, Sendable {
    case presetOnly = "preset-only"
    case unsupportedName = "unsupported-name"
    case invalidDeclaration = "invalid-declaration"
    case unsupportedType = "unsupported-type"
    case unsupportedCondition = "unsupported-condition"
}

public struct ScenePropertyChoice: Equatable, Sendable {
    public let label: String
    public let value: String
    public var identity: Data { Data(value.utf8) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && Data(lhs.label.utf8) == Data(rhs.label.utf8)
    }
}

public struct ScenePropertyDefinition: Equatable, Sendable {
    public let name: String
    public let label: String
    public let kind: ScenePropertyKind?
    public let defaultValue: ScenePropertyValue?
    public let minimum: Double?
    public let maximum: Double?
    public let step: Double?
    public let options: [ScenePropertyChoice]
    public let order: Double?
    public let readOnlyReason: ScenePropertyReadOnlyReason?
    public var identity: Data { Data(name.utf8) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && Data(lhs.label.utf8) == Data(rhs.label.utf8)
            && lhs.kind == rhs.kind && lhs.defaultValue == rhs.defaultValue
            && lhs.minimum == rhs.minimum && lhs.maximum == rhs.maximum
            && lhs.step == rhs.step && lhs.options == rhs.options
            && lhs.order == rhs.order && lhs.readOnlyReason == rhs.readOnlyReason
    }

    init(name: String, raw: ScenePropertyJSON.Value, presetOnly: Bool) {
        let object = presetOnly ? nil : raw.object
        self.name = name
        label = object?["text"]?.string ?? name
        kind = object?["type"]?.string.flatMap(ScenePropertyKind.init(rawValue:))
        defaultValue = object?["value"]?.scalar
        minimum = Self.number(object?["min"]); maximum = Self.number(object?["max"])
        step = Self.number(object?["step"]); order = Self.number(object?["order"])
        options = Self.choices(object?["options"]) ?? []
        if presetOnly { readOnlyReason = .presetOnly }
        else if name == "__proto__" { readOnlyReason = .unsupportedName }
        else if object == nil { readOnlyReason = .invalidDeclaration }
        else if kind == nil { readOnlyReason = .unsupportedType }
        else if let condition = object?["condition"], condition.string != "" { readOnlyReason = .unsupportedCondition }
        else if !Self.validMetadata(object!, kind: kind!) { readOnlyReason = .invalidDeclaration }
        else if let defaultValue, Self.accepts(defaultValue, kind: kind!, minimum: minimum, maximum: maximum, options: options) { readOnlyReason = nil }
        else { readOnlyReason = .invalidDeclaration }
    }

    public func accepts(_ value: ScenePropertyValue) -> Bool {
        guard readOnlyReason == nil, let kind else { return false }
        return Self.accepts(value, kind: kind, minimum: minimum, maximum: maximum, options: options)
    }

    private static func accepts(_ value: ScenePropertyValue, kind: ScenePropertyKind, minimum: Double?, maximum: Double?, options: [ScenePropertyChoice]) -> Bool {
        switch (kind, value) {
        case (.bool, .boolean), (.textinput, .string): return true
        case (.slider, .number(let value)): return value.isFinite && (minimum.map { value >= $0 } ?? true) && (maximum.map { value <= $0 } ?? true)
        case (.color, .string(let value)): return validColor(value)
        case (.combo, .string(let value)): return options.contains { $0.identity == Data(value.utf8) }
        default: return false
        }
    }

    private static func validMetadata(_ object: ScenePropertyJSON.Object, kind: ScenePropertyKind) -> Bool {
        if let text = object["text"], text.string == nil { return false }
        if object["order"] != nil && number(object["order"]) == nil { return false }
        if kind == .slider {
            for field in ["min", "max", "step"] where object[field] != nil {
                guard let value = number(object[field]), field != "step" || value > 0 else { return false }
            }
            if let minimum = number(object["min"]), let maximum = number(object["max"]), minimum > maximum { return false }
        }
        return kind != .combo || choices(object["options"]) != nil
    }

    private static func number(_ value: ScenePropertyJSON.Value?) -> Double? { value?.number }
    private static func choices(_ value: ScenePropertyJSON.Value?) -> [ScenePropertyChoice]? {
        guard let items = value?.array, !items.isEmpty else { return nil }
        var result: [ScenePropertyChoice] = []
        for item in items {
            guard let object = item.object, let label = object["label"]?.string,
                  let value = object["value"]?.string else { return nil }
            result.append(ScenePropertyChoice(label: label, value: value))
        }
        return result
    }
    private static func validColor(_ value: String) -> Bool {
        // Match JavaScript's ECMAScript whitespace, not Foundation's larger set.
        let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        let components = value.components(separatedBy: whitespace).filter { !$0.isEmpty }
        let decimal = "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"
        return components.count == 3 && components.allSatisfy {
            guard $0.range(of: decimal, options: .regularExpression) != nil, let number = Double($0) else { return false }
            return number.isFinite && (0...1).contains(number)
        }
    }
}
