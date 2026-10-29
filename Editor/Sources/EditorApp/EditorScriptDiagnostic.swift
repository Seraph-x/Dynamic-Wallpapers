import Foundation
import CoreFoundation
import WallpaperCore

private func invalidScriptDiagnostic() -> WallpaperError { WallpaperError(text("diagnosticInvalidIssue")) }

struct EditorResourceScriptSource: Equatable {
    let path: String
    let sha256: String
    let pointer: [AnyHashable]
    let text: String
    let identity: Data
    var dictionary: [String: Any] { ["kind": "resource", "path": path, "sha256": sha256, "pointer": pointer.map(\.base), "text": text] }

    init(validated value: Any?) throws {
        guard let source = value as? [String: Any], Set(source.keys) == Set(["kind", "path", "sha256", "pointer", "text"]),
              source["kind"] as? String == "resource", let path = source["path"] as? String,
              let sha256 = source["sha256"] as? String, let rawPointer = source["pointer"] as? [Any],
              let text = source["text"] as? String, !text.contains("\0"), !path.isEmpty, !path.contains("\0"),
              !path.contains("\\"), !path.contains(":"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              sha256.count == 64, sha256.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 || $0 >= 97 && $0 <= 102 })
        else { throw invalidScriptDiagnostic() }
        var pointer: [AnyHashable] = []
        for component in rawPointer {
            if let string = component as? String, !string.contains("\0") { pointer.append(AnyHashable(string)); continue }
            guard let number = EditorScriptDiagnostic.number(component), number >= 0,
                  number <= 9_007_199_254_740_991, number.rounded() == number else { throw invalidScriptDiagnostic() }
            pointer.append(AnyHashable(Int(number)))
        }
        guard let identity = try? JSONSerialization.data(withJSONObject: ["resource", path, sha256, pointer.map(\.base), text])
        else { throw invalidScriptDiagnostic() }
        // A fixed-order array avoids dictionary-order normalization in issue identity.
        self.path = path; self.sha256 = sha256; self.pointer = pointer; self.text = text; self.identity = identity
    }
}

struct EditorScriptDiagnostic: Equatable {
    struct Key: Hashable { let layerID: Double?; let target: Data; let phase: Data; let message: Data; let source: Data? }
    let layerID: Double?
    let layerName: String
    let target: String
    let phase: String
    let message: String
    let line: Int?
    let count: Int
    let source: EditorResourceScriptSource?
    var key: Key { Key(layerID: layerID, target: Data(target.utf8), phase: Data(phase.utf8), message: Data(message.utf8), source: source?.identity) }

    init(validated value: [String: Any]) throws {
        let baseKeys = Set(["layerId", "layerName", "target", "phase", "message", "line", "count"])
        guard Set(value.keys) == baseKeys || Set(value.keys) == baseKeys.union(["source"]),
              let name = value["layerName"] as? String, let target = value["target"] as? String,
              let phase = value["phase"] as? String, let message = value["message"] as? String,
              let count = Self.positiveInteger(value["count"]) else { throw WallpaperError(text("diagnosticInvalidIssue")) }
        if value["layerId"] is NSNull { layerID = nil }
        else if let number = Self.number(value["layerId"]) { layerID = number }
        else { throw WallpaperError(text("diagnosticInvalidIssue")) }
        if value["line"] is NSNull { line = nil }
        else if let number = Self.positiveInteger(value["line"]) { line = number }
        else { throw WallpaperError(text("diagnosticInvalidIssue")) }
        source = try value["source"].map(EditorResourceScriptSource.init(validated:))
        layerName = name; self.target = target; self.phase = phase; self.message = message; self.count = count
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = number(value), number > 0, number <= 9_007_199_254_740_991, number.rounded() == number else { return nil }
        return Int(number)
    }
}

struct EditorCapturedScriptLink {
    let documentIdentity: String
    let source: String
    let layerID: Double?
    let target: String
    let path: [AnyHashable]
    let line: Int?
    let registered: Bool
    let resource: EditorResourceScriptSource?
    var dictionary: [String: Any] {
        var value: [String: Any] = ["documentIdentity": documentIdentity, "source": source, "layerId": layerID.map { $0 as Any } ?? NSNull(),
         "target": target, "path": path.map(\.base), "line": line.map { $0 as Any } ?? NSNull(), "registered": registered]
        if let resource { value["resource"] = resource.dictionary }
        return value
    }
}

struct EditorCapturedScriptSnapshot {
    struct Resolution { let link: EditorCapturedScriptLink?; let reasonKey: String? }
    private struct Source { let source: String; let layerID: Double?; let target: String; let path: [AnyHashable]; let registered: Bool }
    let documentIdentity: String
    private let sources: [Source]
    private let ambiguousIDs: Set<Double>
    private static let properties = Set(["origin", "scale", "angles", "color", "alpha", "brightness", "maxwidth", "pointsize", "volume", "intensity", "exponent", "visible", "text"])
    private static let particleProperties = Set(["rate", "count", "size", "speed", "lifetime", "brightness", "alpha", "colorn"])

    init(documentIdentity: String, scene: [String: Any]) throws {
        guard !documentIdentity.isEmpty, !documentIdentity.contains("\0") else { throw WallpaperError(text("diagnosticMissingCapture")) }
        self.documentIdentity = documentIdentity
        // JSON round-trip detaches all mutable Foundation containers from the owner.
        let bytes = try JSONSerialization.data(withJSONObject: scene)
        let captured = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let objects = captured["objects"] as? [[String: Any]] ?? []
        var runtimeIDs: [Double: Int] = [:]
        for (index, object) in objects.enumerated() {
            let id = object["id"] == nil ? Double(index) : EditorScriptDiagnostic.number(object["id"])
            if let id { runtimeIDs[id, default: 0] += 1 }
        }
        ambiguousIDs = Set(runtimeIDs.filter { $0.value > 1 }.map(\.key))
        var found: [Source] = []
        var pending: [(Any, [AnyHashable])] = [(captured, [])]
        while let (value, path) = pending.popLast() {
            if path.last?.base as? String == "script", let source = value as? String {
                let layerIndex = path.count > 1 && path[0].base as? String == "objects" ? path[1].base as? Int : nil
                let layer = layerIndex.flatMap { objects.indices.contains($0) ? objects[$0] : nil }
                let layerID = layer.flatMap { EditorScriptDiagnostic.number($0["id"]) }
                let local = layerIndex == nil ? Array(path.dropLast()) : Array(path.dropFirst(2).dropLast())
                let effect = local.count == 3 && local[0].base as? String == "effects" && local[1].base is Int && local[2].base as? String == "visible"
                let target = effect ? "effects[\(local[1])].visible" : local.map { String(describing: $0.base) }.joined(separator: ".")
                let particle = local.count == 2 && local[0].base as? String == "instanceoverride" &&
                    Self.particleProperties.contains(String(describing: local[1].base)) && !(layer?["particle"] as? String ?? "").isEmpty
                let registered = layer != nil && ((local.count == 1 && Self.properties.contains(target)) || effect || particle)
                // null identity belongs only to actual general wrappers, never a layer with a string/missing ID.
                if layerIndex == nil || layerID != nil {
                    found.append(Source(source: source, layerID: layerID, target: target, path: path, registered: registered))
                }
            }
            if let object = value as? [String: Any] {
                for (key, child) in object { pending.append((child, path + [AnyHashable(key)])) }
            } else if let array = value as? [Any] {
                for (index, child) in array.enumerated() { pending.append((child, path + [AnyHashable(index)])) }
            }
        }
        sources = found
    }
    func resolve(_ issue: EditorScriptDiagnostic) -> Resolution {
        if let resource = issue.source {
            return Resolution(link: EditorCapturedScriptLink(documentIdentity: documentIdentity, source: resource.text,
                layerID: issue.layerID, target: issue.target, path: resource.pointer, line: issue.line,
                registered: true, resource: resource), reasonKey: nil)
        }
        if let id = issue.layerID {
            guard id.rounded() == id, abs(id) <= 9_007_199_254_740_991, !ambiguousIDs.contains(id) else {
                return Resolution(link: nil, reasonKey: "diagnosticAmbiguousSource")
            }
        } else if !issue.target.hasPrefix("general.") { return Resolution(link: nil, reasonKey: "diagnosticUnknownSource") }
        let matching = sources.filter { $0.layerID == issue.layerID && Data($0.target.utf8) == Data(issue.target.utf8) }
        guard matching.count == 1, let source = matching.first else {
            return Resolution(link: nil, reasonKey: matching.isEmpty ? "diagnosticUnknownSource" : "diagnosticAmbiguousSource")
        }
        return Resolution(link: EditorCapturedScriptLink(documentIdentity: documentIdentity, source: source.source,
            layerID: issue.layerID, target: issue.target, path: source.path, line: issue.line, registered: source.registered, resource: nil), reasonKey: nil)
    }
}
