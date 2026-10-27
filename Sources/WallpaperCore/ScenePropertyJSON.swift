import Foundation

/// Flat nodes avoid recursive traversal/destruction of unknown metadata.
/// Object keys retain exact bytes and JSON.parse's last-member-wins behavior.
enum ScenePropertyJSON {
    fileprivate struct Entry { let name: String; let index: Int }
    fileprivate enum Node { case object([Entry]), array([Int]), string(String), number(Double), boolean(Bool), null }
    fileprivate final class Storage { let nodes: [Node]; init(_ nodes: [Node]) { self.nodes = nodes } }
    struct Member { let name: String; let value: Value }
    struct Object {
        fileprivate let storage: Storage
        fileprivate let entries: [Entry]
        var members: [Member] { entries.map { Member(name: $0.name, value: Value(storage: storage, index: $0.index)) } }
        subscript(_ name: String) -> Value? {
            entries.first { Data($0.name.utf8) == Data(name.utf8) }.map { Value(storage: storage, index: $0.index) }
        }
    }
    struct Value {
        fileprivate let storage: Storage
        fileprivate let index: Int
        var object: Object? {
            guard case .object(let entries) = storage.nodes[index] else { return nil }
            return Object(storage: storage, entries: entries)
        }
        var array: [Value]? {
            guard case .array(let indices) = storage.nodes[index] else { return nil }
            return indices.map { Value(storage: storage, index: $0) }
        }
        var string: String? { if case .string(let value) = storage.nodes[index] { return value }; return nil }
        var number: Double? {
            if case .number(let value) = storage.nodes[index], value.isFinite { return value }; return nil
        }
        var scalar: ScenePropertyValue? {
            switch storage.nodes[index] {
            case .string(let value): return .string(value)
            case .number(let value) where value.isFinite: return .number(value)
            case .boolean(let value): return .boolean(value)
            default: return nil
            }
        }
    }

    static func parse(_ data: Data) throws -> Value {
        guard String(data: data, encoding: .utf8) != nil else { throw WallpaperError("场景属性元数据必须是 UTF-8 JSON。") }
        var parser = Parser(bytes: Array(data))
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        return try parser.parse()
    }

    private enum State { case objectKey, objectSeparator, arrayValue, arraySeparator }
    private struct Frame {
        var state: State
        var allowEnd = true
        var key: String?
        var entries: [Entry] = []
        var positions: [Data: Int] = [:]
        var indices: [Int] = []
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var nodes: [Node] = []
        var frames: [Frame] = []
        var root: Int?

        mutating func parse() throws -> Value {
            try nextValue()
            while !frames.isEmpty {
                whitespace()
                let last = frames.count - 1
                switch frames[last].state {
                case .objectKey:
                    if frames[last].allowEnd, consume(125) { try finishObject(); continue }
                    frames[last].key = try string(); whitespace()
                    guard consume(58) else { throw failure() }
                    try nextValue()
                case .objectSeparator:
                    if consume(125) { try finishObject(); continue }
                    guard consume(44) else { throw failure() }
                    frames[last].state = .objectKey; frames[last].allowEnd = false
                case .arrayValue:
                    if frames[last].allowEnd, consume(93) { try finishArray(); continue }
                    try nextValue()
                case .arraySeparator:
                    if consume(93) { try finishArray(); continue }
                    guard consume(44) else { throw failure() }
                    frames[last].state = .arrayValue; frames[last].allowEnd = false
                }
            }
            whitespace()
            guard let root, index == bytes.count else { throw failure() }
            return Value(storage: Storage(nodes), index: root)
        }
        mutating func finishObject() throws {
            let frame = frames.removeLast(); try attach(.object(frame.entries))
        }
        mutating func finishArray() throws {
            let frame = frames.removeLast(); try attach(.array(frame.indices))
        }
        mutating func attach(_ node: Node) throws {
            let nodeIndex = nodes.count; nodes.append(node)
            guard !frames.isEmpty else { guard root == nil else { throw failure() }; root = nodeIndex; return }
            let last = frames.count - 1
            switch frames[last].state {
            case .objectKey:
                guard let name = frames[last].key else { throw failure() }
                let key = Data(name.utf8), entry = Entry(name: name, index: nodeIndex)
                if let previous = frames[last].positions[key] { frames[last].entries[previous] = entry }
                else { frames[last].positions[key] = frames[last].entries.count; frames[last].entries.append(entry) }
                frames[last].key = nil; frames[last].state = .objectSeparator
            case .arrayValue:
                frames[last].indices.append(nodeIndex); frames[last].state = .arraySeparator
            default: throw failure()
            }
        }
        mutating func nextValue() throws {
            whitespace()
            guard index < bytes.count else { throw failure() }
            switch bytes[index] {
            case 123: index += 1; frames.append(Frame(state: .objectKey))
            case 91: index += 1; frames.append(Frame(state: .arrayValue))
            case 34: try attach(.string(try string()))
            case 116: try literal(Array("true".utf8)); try attach(.boolean(true))
            case 102: try literal(Array("false".utf8)); try attach(.boolean(false))
            case 110: try literal(Array("null".utf8)); try attach(.null)
            default: try attach(.number(try number()))
            }
        }
        mutating func number() throws -> Double {
            let start = index
            _ = consume(45)
            if !consume(48) { guard digits() else { throw failure() } }
            if consume(46), !digits() { throw failure() }
            if consume(101) || consume(69) {
                if !consume(43) { _ = consume(45) }
                guard digits() else { throw failure() }
            }
            guard let text = String(bytes: bytes[start..<index], encoding: .utf8), let value = Double(text) else { throw failure() }
            return value
        }
        mutating func digits() -> Bool {
            let start = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            return index > start
        }
        mutating func whitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1; return true
        }
        mutating func string() throws -> String {
            let start = index
            guard consume(34) else { throw failure() }
            while index < bytes.count {
                if consume(34) { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                if consume(92) {
                    guard index < bytes.count else { throw failure() }; index += 1
                } else { index += 1 }
            }
            throw failure()
        }
        mutating func literal(_ expected: [UInt8]) throws {
            guard expected.count <= bytes.count - index, bytes[index..<(index + expected.count)].elementsEqual(expected) else { throw failure() }
            index += expected.count
        }
        func failure() -> WallpaperError { WallpaperError("场景属性 JSON 在字节 \(index) 处无效。") }
    }
}
