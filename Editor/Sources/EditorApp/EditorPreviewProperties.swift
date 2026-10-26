import Foundation
import CoreFoundation
import WallpaperCore

/// Immutable scalar values keep CFBoolean distinct from numeric NSNumber values.
enum EditorPreviewPropertyValue: Equatable {
    case bool(Bool), number(Double), string(String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.bool(let left), .bool(let right)): return left == right
        case (.number(let left), .number(let right)): return left == right
        case (.string(let left), .string(let right)): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }
    init(_ raw: Any) throws {
        if let string = raw as? String { self = .string(string); return }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue); return }
            if number.doubleValue.isFinite { self = .number(number.doubleValue); return }
        }
        throw WallpaperError("Expected a finite number, boolean or string")
    }
    var rawValue: Any {
        switch self { case .bool(let value): return value; case .number(let value): return value; case .string(let value): return value }
    }
    var display: String {
        switch self { case .bool(let value): return String(value); case .number(let value): return String(value); case .string(let value): return value }
    }
}

/// JavaScript property keys use exact code units; Swift String-keyed dictionaries
/// normalize canonically equivalent names. Foundation NSString keys and these
/// UTF-8 identities retain each distinct captured declaration and acknowledgement.
struct EditorPreviewPropertyValues: Equatable, ExpressibleByDictionaryLiteral {
    private struct Entry: Equatable { let name: String; let value: EditorPreviewPropertyValue }
    private let storage: [Data: Entry]

    init(_ entries: [(String, EditorPreviewPropertyValue)] = []) {
        var values: [Data: Entry] = [:]
        for (name, value) in entries { values[Data(name.utf8)] = Entry(name: name, value: value) }
        storage = values
    }
    init(dictionaryLiteral elements: (String, EditorPreviewPropertyValue)...) { self.init(elements) }
    private init(storage: [Data: Entry]) { self.storage = storage }
    subscript(name: String) -> EditorPreviewPropertyValue? { storage[Data(name.utf8)]?.value }
    var count: Int { storage.count }
    func merging(_ values: Self) -> Self {
        Self(storage: storage.merging(values.storage) { _, new in new })
    }
    func encoded() throws -> Data {
        let object = NSMutableDictionary()
        for entry in storage.values { object.setObject(entry.value.rawValue, forKey: entry.name as NSString) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

struct EditorPreviewProperties {
    struct Option { let label: String; let value: EditorPreviewPropertyValue }
    struct Row {
        let name: String
        let type: String?
        let text: String?
        let order: Double?
        let value: EditorPreviewPropertyValue?
        let min: Double?
        let max: Double?
        let step: Double?
        let options: [Option]?
        /// Original declaration encoded without coercion, including unknown fields.
        let rawJSON: Data
        let readOnlyReason: String?
        var rawDescription: String { String(decoding: rawJSON, as: UTF8.self) }

        func validate(_ value: EditorPreviewPropertyValue) throws {
            guard readOnlyReason == nil else { throw WallpaperError("\(name): \(readOnlyReason!)") }
            switch (type, value) {
            case ("bool", .bool), ("textinput", .string): return
            case ("slider", .number(let number)):
                guard min.map({ number >= $0 }) ?? true, max.map({ number <= $0 }) ?? true else {
                    throw WallpaperError("\(name): value is outside the declared range")
                }
            case ("color", .string(let string)):
                guard Self.validRGB(string) else { throw WallpaperError("\(name): expected three RGB components between 0 and 1") }
            case ("combo", .string):
                guard options?.contains(where: { $0.value == value }) == true else { throw WallpaperError("\(name): choose a declared option") }
            default: throw WallpaperError("\(name): value does not match the declared type")
            }
        }
        private static func validRGB(_ string: String) -> Bool {
            // Match ECMAScript \s exactly, including BOM and excluding NEL.
            let separators = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
            let components = string.components(separatedBy: separators).filter { !$0.isEmpty }
            let decimal = #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$"#
            return components.count == 3 && components.allSatisfy {
                $0.range(of: decimal, options: .regularExpression) != nil && Double($0).map { $0.isFinite && (0...1).contains($0) } == true
            }
        }
    }
    let rows: [Row]
    var defaults: EditorPreviewPropertyValues {
        EditorPreviewPropertyValues(rows.compactMap { row in
            guard row.readOnlyReason == nil, let value = row.value else { return nil }; return (row.name, value)
        })
    }

    init(project: [String: Any]) throws {
        let general = try Self.record(project["general"], path: "project.general")
        let properties = try Self.record(general.object(forKey: "properties"), path: "project.general.properties")
        let preset = try Self.record(project["preset"], path: "project.preset")
        var declarations: [Data: (name: String, raw: Any, presetOnly: Bool)] = [:]
        for (source, presetOnly) in [(preset, true), (properties, false)] {
            for key in source.allKeys {
                guard let name = key as? String else { throw WallpaperError("Property names must be strings") }
                declarations[Data(name.utf8)] = (name, source.object(forKey: key)!, presetOnly)
            }
        }
        rows = try declarations.values.map {
            try Self.makeRow(name: $0.name, raw: $0.raw, presetOnly: $0.presetOnly)
        }.sorted {
            let left = $0.order ?? .infinity, right = $1.order ?? .infinity
            return left == right ? $0.name.utf16.lexicographicallyPrecedes($1.name.utf16) : left < right
        }
    }

    func validate(_ patch: [String: Any]) throws -> EditorPreviewPropertyValues {
        let declarations = Dictionary(uniqueKeysWithValues: rows.map { (Data($0.name.utf8), $0) })
        var result: [(String, EditorPreviewPropertyValue)] = []
        for (name, raw) in patch {
            guard let row = declarations[Data(name.utf8)] else { throw WallpaperError("Unknown property: \(name)") }
            let value = try EditorPreviewPropertyValue(raw); try row.validate(value); result.append((name, value))
        }
        return EditorPreviewPropertyValues(result)
    }

    private static func record(_ raw: Any?, path: String) throws -> NSDictionary {
        guard let raw else { return NSDictionary() }
        guard let record = raw as? NSDictionary else { throw WallpaperError("\(path) must be an object") }
        return record
    }
    private static func finiteNumber(_ raw: Any?) -> Double? {
        guard let raw, let scalar = try? EditorPreviewPropertyValue(raw), case .number(let value) = scalar else { return nil }
        return value
    }
    private static func makeRow(name: String, raw: Any, presetOnly: Bool) throws -> Row {
        let json = try JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed, .sortedKeys])
        let definition = raw as? [String: Any]
        let type = definition?["type"] as? String, text = definition?["text"] as? String
        let order = finiteNumber(definition?["order"])
        let value = definition?["value"].flatMap { try? EditorPreviewPropertyValue($0) }
        let min = finiteNumber(definition?["min"]), max = finiteNumber(definition?["max"]), step = finiteNumber(definition?["step"])
        let options: [Option]? = (definition?["options"] as? [[String: Any]]).flatMap { entries in
            var parsed: [Option] = []
            for entry in entries {
                guard let label = entry["label"] as? String, let value = entry["value"] as? String else { return nil }
                parsed.append(Option(label: label, value: .string(value)))
            }
            return parsed.isEmpty ? nil : parsed
        }
        var reason: String?
        if presetOnly { reason = "preset-only" }
        else if name == "__proto__" { reason = "unsupported-name" }
        else if definition == nil { reason = "invalid-declaration" }
        else if !["bool", "slider", "color", "textinput", "combo"].contains(type ?? "") { reason = "unsupported-type" }
        else if definition?["condition"] != nil && definition?["condition"] as? String != "" { reason = "unsupported-condition" }
        else if (definition?["text"] != nil && text == nil) || (definition?["order"] != nil && order == nil) { reason = "invalid-declaration" }
        else if type == "slider", (definition?["min"] != nil && min == nil) || (definition?["max"] != nil && max == nil) || (definition?["step"] != nil && (step == nil || step! <= 0)) || (min != nil && max != nil && min! > max!) { reason = "invalid-declaration" }
        else if type == "combo" && options == nil { reason = "invalid-declaration" }
        let candidate = Row(name: name, type: type, text: text, order: order, value: value, min: min, max: max, step: step, options: options, rawJSON: json, readOnlyReason: reason)
        if reason == nil {
            do { guard let value else { throw WallpaperError("Missing scalar value") }; try candidate.validate(value) }
            catch { reason = "invalid-declaration" }
        }
        return Row(name: name, type: type, text: text, order: order, value: value, min: min, max: max, step: step, options: options, rawJSON: json, readOnlyReason: reason)
    }
}
