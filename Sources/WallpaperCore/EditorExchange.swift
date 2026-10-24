import Foundation

enum EditorFileURL {
    static func validate(_ url: URL) throws {
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host), url.path.hasPrefix("/"),
              !url.path.contains("\0"), url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else {
            throw WallpaperError("Editor 文件接口只接受本机文件路径。")
        }
    }
}

/// No filesystem access: this is a versioned, targeted application handoff.
public enum EditorLink: Equatable, Sendable {
    case openEditor(project: SceneProjectReference?, descriptor: URL?)
    case importScene(SceneProjectReference)

    public func url() throws -> URL {
        var components = URLComponents()
        var fields = [URLQueryItem(name: "api", value: "1")]
        let project: SceneProjectReference?
        switch self {
        case .openEditor(let selected, let descriptor):
            components.scheme = "dynamic-wallpaper-editor"; components.host = "open"
            project = selected
            if let descriptor {
                try EditorFileURL.validate(descriptor)
                fields.append(URLQueryItem(name: "descriptor", value: descriptor.absoluteString))
            }
        case .importScene(let selected):
            components.scheme = "dynamic-wallpaper"; components.host = "import-scene"
            project = selected
        }
        if let project {
            try project.validate(); try EditorFileURL.validate(project.root)
            fields += [URLQueryItem(name: "root", value: project.root.absoluteString),
                       URLQueryItem(name: "entry", value: project.entry),
                       URLQueryItem(name: "representation", value: project.representation.rawValue)]
        }
        components.queryItems = fields
        guard let result = components.url else { throw WallpaperError("无法编码 Editor 文件接口。") }
        return result
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, ["", "/"].contains(components.path),
              let items = components.queryItems else { throw WallpaperError("无效的 Editor 文件接口。") }
        var fields: [String: String] = [:]
        let allowed: Set<String> = ["api", "root", "entry", "representation", "descriptor"]
        for item in items {
            guard allowed.contains(item.name), fields[item.name] == nil, let value = item.value, !value.isEmpty else {
                throw WallpaperError("Editor 接口包含未知、重复或空字段。")
            }
            fields[item.name] = value
        }
        guard fields["api"] == "1" else { throw WallpaperError("不支持的 Editor 接口版本。") }
        let project: SceneProjectReference?
        if fields["root"] != nil || fields["entry"] != nil || fields["representation"] != nil {
            guard let rootValue = fields["root"], let root = URL(string: rootValue), let entry = fields["entry"],
                  let kind = fields["representation"], let representation = SceneRepresentation(rawValue: kind) else {
                throw WallpaperError("Editor 场景引用不完整。")
            }
            try EditorFileURL.validate(root)
            let reference = SceneProjectReference(root: root, entry: entry, representation: representation)
            try reference.validate(); project = reference
        } else { project = nil }
        switch (components.scheme?.lowercased(), components.host?.lowercased()) {
        case ("dynamic-wallpaper-editor", "open"):
            let descriptor: URL?
            if let value = fields["descriptor"] {
                guard let url = URL(string: value) else { throw WallpaperError("无效的共享文件路径。") }
                try EditorFileURL.validate(url); descriptor = url
            } else { descriptor = nil }
            self = .openEditor(project: project, descriptor: descriptor)
        case ("dynamic-wallpaper", "import-scene"):
            guard let project, fields["descriptor"] == nil else { throw WallpaperError("导入请求缺少场景或包含多余字段。") }
            self = .importScene(project)
        default: throw WallpaperError("未知的 Editor 接口操作。")
        }
    }
}

public struct EditorSceneOffer: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let project: SceneProjectReference
    public init(id: UUID, title: String, project: SceneProjectReference) {
        self.id = id; self.title = title; self.project = project
    }
}

public struct SharedSceneRenderer: Codable, Equatable, Sendable {
    public let version: String
    public let module: URL
    public let sha256: String
    public init(version: String, module: URL, sha256: String) {
        self.version = version; self.module = module; self.sha256 = sha256
    }
}

/// Read-only scene offers/resources. Neither app can use this descriptor to mutate the other.
public struct EditorExchange: Equatable, Sendable {
    public let hostBundleIdentifier: String
    public let scenes: [EditorSceneOffer]
    public let renderer: SharedSceneRenderer?
    private struct Wire: Codable {
        let version: Int
        let hostBundleIdentifier: String
        let scenes: [EditorSceneOffer]
        let renderer: SharedSceneRenderer?
    }

    public init(hostBundleIdentifier: String, scenes: [EditorSceneOffer], renderer: SharedSceneRenderer?) throws {
        guard !hostBundleIdentifier.isEmpty,
              hostBundleIdentifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
              Set(scenes.map(\.id)).count == scenes.count else { throw WallpaperError("无效或重复的 Editor 共享场景。") }
        for scene in scenes {
            guard !scene.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WallpaperError("共享场景缺少名称。") }
            try scene.project.validate(); try EditorFileURL.validate(scene.project.root)
        }
        if let renderer {
            try EditorFileURL.validate(renderer.module)
            let parts = renderer.version.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "0123456789".contains($0) } }),
                  renderer.sha256.count == 64, renderer.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  renderer.module.pathExtension == "mjs" else { throw WallpaperError("共享渲染模块缺少有效版本或校验值。") }
        }
        self.hostBundleIdentifier = hostBundleIdentifier; self.scenes = scenes; self.renderer = renderer
    }

    public init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WallpaperError("共享描述必须是 JSON 对象。") }
        try Self.keys(object, allowed: ["version", "hostBundleIdentifier", "scenes", "renderer"])
        if let scenes = object["scenes"] as? [[String: Any]] {
            for scene in scenes {
                try Self.keys(scene, allowed: ["id", "title", "project"])
                if let project = scene["project"] as? [String: Any] {
                    try Self.keys(project, allowed: ["root", "entry", "representation"])
                }
            }
        }
        if let renderer = object["renderer"] as? [String: Any] { try Self.keys(renderer, allowed: ["version", "module", "sha256"]) }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.version == 1 else { throw WallpaperError("不支持的 Editor 共享描述版本。") }
        try self.init(hostBundleIdentifier: wire.hostBundleIdentifier, scenes: wire.scenes, renderer: wire.renderer)
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Wire(version: 1, hostBundleIdentifier: hostBundleIdentifier, scenes: scenes, renderer: renderer))
    }
    private static func keys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw WallpaperError("Editor 共享描述包含未知字段。") }
    }
}
