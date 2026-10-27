import Foundation

public struct WallpaperError: LocalizedError, Equatable, Sendable {
    public let message: String
    public let diagnostic: String?
    public init(_ message: String, diagnostic: String? = nil) {
        self.message = message; self.diagnostic = diagnostic
    }
    public var errorDescription: String? { diagnostic.map { "\(message)\n\($0)" } ?? message }
}

/// Keep individual failures available to callers instead of flattening their diagnostics.
public struct WallpaperErrorGroup: LocalizedError {
    public let errors: [Error]
    public init(_ errors: [Error]) { self.errors = errors }
    public var errorDescription: String? { errors.map(\.localizedDescription).joined(separator: "\n") }
}

public enum MediaKind: String, Codable, Sendable { case video, image, animatedImage, web, scene }
public enum PlaybackMode: String, Codable, CaseIterable, Sendable {
    case ordered, shuffle, repeatOne
    public var title: String {
        switch self { case .ordered: return "顺序循环"; case .shuffle: return "随机不重复"; case .repeatOne: return "单项循环" }
    }
}
public enum ContentFit: String, Codable, CaseIterable, Sendable { case fill, fit }
public enum TimingMode: String, Codable, CaseIterable, Sendable { case seconds, full, loops }
public enum WebWallpaperFrameRate: Int, Codable, CaseIterable, Sendable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60
}

public struct MediaItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let kind: MediaKind
    public let width: Int
    public let height: Int
    public let duration: Double?
    public let backend: MediaBackend
    public let webProject: WebProjectReference?
    public let sceneProject: SceneProjectReference?
    public let origin: MediaOrigin?
    public var customName: String?
    public var isFavorite: Bool
    public var supportsAudio: Bool { kind == .video || kind == .web || kind == .scene }
    public var name: String {
        if let customName {
            let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if kind == .web || kind == .scene {
            if let projectRoot = origin?.projectRoot?.lastPathComponent, !projectRoot.isEmpty {
                return projectRoot
            }
            if let projectRoot = (webProject?.root ?? sceneProject?.root)?.lastPathComponent,
               !projectRoot.isEmpty, projectRoot != "Project" {
                return projectRoot
            }
            return url.deletingLastPathComponent().lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }
    public init(id: UUID = UUID(), url: URL, kind: MediaKind, width: Int, height: Int,
                duration: Double? = nil, isFavorite: Bool = false,
                backend: MediaBackend = .native, webProject: WebProjectReference? = nil,
                sceneProject: SceneProjectReference? = nil,
                origin: MediaOrigin? = nil, customName: String? = nil) {
        self.id = id; self.url = url; self.kind = kind; self.width = width
        self.height = height; self.duration = duration; self.isFavorite = isFavorite
        self.backend = backend; self.webProject = webProject; self.sceneProject = sceneProject
        self.origin = origin; self.customName = customName
    }
    private enum CodingKeys: String, CodingKey {
        case id, url, kind, width, height, duration, isFavorite, backend, webProject, sceneProject, origin, customName
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        url = try values.decode(URL.self, forKey: .url)
        kind = try values.decode(MediaKind.self, forKey: .kind)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        isFavorite = try values.decode(Bool.self, forKey: .isFavorite)
        backend = try values.contains(.backend) ? values.decode(MediaBackend.self, forKey: .backend) : .native
        webProject = try values.contains(.webProject) ? values.decode(WebProjectReference.self, forKey: .webProject) : nil
        sceneProject = try values.contains(.sceneProject) ? values.decode(SceneProjectReference.self, forKey: .sceneProject) : nil
        origin = try values.decodeIfPresent(MediaOrigin.self, forKey: .origin)
        customName = try values.decodeIfPresent(String.self, forKey: .customName)
    }
    public func validateBackend(schema: Int) throws {
        guard (1...Library.currentVersion).contains(schema) else { throw WallpaperError("不支持此素材库版本。") }
        guard schema >= 2 || (backend == .native && kind != .web && kind != .scene && webProject == nil && sceneProject == nil) else {
            throw WallpaperError("旧版素材库不能包含扩展媒体。")
        }
        guard schema >= 4 || (kind != .scene && backend != .scene && sceneProject == nil) else {
            throw WallpaperError("旧版素材库不能包含场景项目。")
        }
        if kind == .scene {
            guard backend == .scene, let sceneProject, webProject == nil, duration == nil else {
                throw WallpaperError("场景项目的后端或时长元数据无效。")
            }
            try sceneProject.validate()
            guard url.standardizedFileURL == sceneProject.entryURL.standardizedFileURL else {
                throw WallpaperError("场景入口与项目引用不一致。")
            }
        } else if kind == .web {
            guard backend == .web, let webProject, sceneProject == nil, duration == nil else {
                throw WallpaperError("网页项目的后端或时长元数据无效。")
            }
            try webProject.validate()
            guard url.standardizedFileURL == webProject.entryURL.standardizedFileURL else {
                throw WallpaperError("网页入口与项目引用不一致。")
            }
        } else {
            guard webProject == nil, sceneProject == nil, backend == .native || (backend == .extended && kind == .video) else {
                throw WallpaperError("素材类型与播放后端不一致。")
            }
        }
    }
}

public struct EntryTiming: Codable, Equatable, Sendable {
    public var mode: TimingMode
    public var seconds: Double
    public var loops: Int
    public init(mode: TimingMode = .seconds, seconds: Double = 30, loops: Int = 1) {
        self.mode = mode; self.seconds = seconds; self.loops = loops
    }
    public func validate() throws {
        guard seconds.isFinite, seconds > 0, loops > 0 else { throw WallpaperError("停留时长须大于 0 秒，循环次数须为正整数。") }
        try Self.validateClockDuration(seconds)
    }
    public static func validateClockDuration(_ seconds: Double) throws {
        // Swift Duration stores its whole-second component in Int64.
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) else {
            throw WallpaperError("时长过大，请输入较小的数值。")
        }
    }
    public func duration(mediaDuration: Double?) -> Double {
        switch mode {
        case .seconds: return seconds
        case .full: return mediaDuration ?? seconds
        case .loops: return (mediaDuration ?? seconds) * Double(loops)
        }
    }
}

public struct AudioSettings: Codable, Equatable, Sendable {
    public var isMuted: Bool
    public var volume: Double
    public init(isMuted: Bool = false, volume: Double = 1) { self.isMuted = isMuted; self.volume = volume }
    public func validate() throws {
        guard volume.isFinite, (0...1).contains(volume) else { throw WallpaperError("音量必须在 0% 到 100% 之间。") }
    }
}

public struct PlaylistEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let mediaID: UUID
    public var timing: EntryTiming
    public var audio: AudioSettings
    public init(id: UUID = UUID(), mediaID: UUID, timing: EntryTiming = EntryTiming(), audio: AudioSettings = AudioSettings()) {
        self.id = id; self.mediaID = mediaID; self.timing = timing; self.audio = audio
    }
    private enum CodingKeys: String, CodingKey { case id, mediaID, timing, audio }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        mediaID = try values.decode(UUID.self, forKey: .mediaID)
        timing = try values.decode(EntryTiming.self, forKey: .timing)
        audio = try values.contains(.audio) ? values.decode(AudioSettings.self, forKey: .audio) : AudioSettings()
    }
}

public struct Playlist: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var entries: [PlaylistEntry]
    public var mode: PlaybackMode
    public var transition: Double
    public init(id: UUID = UUID(), name: String, entries: [PlaylistEntry] = [],
                mode: PlaybackMode = .ordered, transition: Double = 0.3) {
        self.id = id; self.name = name; self.entries = entries; self.mode = mode; self.transition = transition
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var pauseOnLowPower = false
    public var pauseOnHighTemperature = true
    public var pauseOnOtherAppFullScreen = false
    public var isMuted = true
    public var webInteractionEnabled = false
    public var systemWallpaperSyncEnabled = false
    public var systemAudioSpectrumEnabled = false
    public var systemMediaSource = SystemMediaSource.disabled
    public var showDockIcon = true
    public var webWallpaperFrameRate = WebWallpaperFrameRate.fps30
    public var appearance = AppAppearanceSettings()
    public var language = AppLanguage.system
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case pauseOnLowPower, pauseOnHighTemperature, pauseOnOtherAppFullScreen, isMuted, webInteractionEnabled, showDockIcon, appearance, language
        case systemWallpaperSyncEnabled, systemAudioSpectrumEnabled, systemMediaSource, webWallpaperFrameRate
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pauseOnLowPower = try values.decode(Bool.self, forKey: .pauseOnLowPower)
        pauseOnHighTemperature = try values.decode(Bool.self, forKey: .pauseOnHighTemperature)
        pauseOnOtherAppFullScreen = try values.contains(.pauseOnOtherAppFullScreen)
            ? values.decode(Bool.self, forKey: .pauseOnOtherAppFullScreen) : false
        // Only missing fields in older libraries receive the documented compatibility default.
        isMuted = try values.contains(.isMuted) ? values.decode(Bool.self, forKey: .isMuted) : true
        webInteractionEnabled = try values.contains(.webInteractionEnabled)
            ? values.decode(Bool.self, forKey: .webInteractionEnabled) : false
        systemWallpaperSyncEnabled = try values.contains(.systemWallpaperSyncEnabled)
            ? values.decode(Bool.self, forKey: .systemWallpaperSyncEnabled) : false
        systemAudioSpectrumEnabled = try values.contains(.systemAudioSpectrumEnabled)
            ? values.decode(Bool.self, forKey: .systemAudioSpectrumEnabled) : false
        systemMediaSource = try values.contains(.systemMediaSource)
            ? values.decode(SystemMediaSource.self, forKey: .systemMediaSource) : .disabled
        showDockIcon = try values.contains(.showDockIcon)
            ? values.decode(Bool.self, forKey: .showDockIcon) : true
        webWallpaperFrameRate = try values.contains(.webWallpaperFrameRate)
            ? values.decode(WebWallpaperFrameRate.self, forKey: .webWallpaperFrameRate) : .fps30
        appearance = try values.contains(.appearance)
            ? values.decode(AppAppearanceSettings.self, forKey: .appearance) : AppAppearanceSettings()
        language = try values.contains(.language) ? values.decode(AppLanguage.self, forKey: .language) : .system
    }
}

public struct Library: Codable, Equatable, Sendable {
    public static let currentVersion = 4
    public var version = currentVersion
    public var media: [MediaItem] = []
    public var playlists: [Playlist] = [Playlist(name: "我的播放列表")]
    public var displays: [DisplayBinding] = []
    public var settings = AppSettings()
    public var pendingMediaDeletions: [MediaItem] = []
    public init() {}
    public static var empty: Library { Library() }

    private enum CodingKeys: String, CodingKey { case version, media, playlists, displays, settings, pendingMediaDeletions }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        media = try values.decode([MediaItem].self, forKey: .media)
        playlists = try values.decode([Playlist].self, forKey: .playlists)
        displays = try values.decode([DisplayBinding].self, forKey: .displays)
        settings = try values.decode(AppSettings.self, forKey: .settings)
        pendingMediaDeletions = try values.decodeIfPresent([MediaItem].self, forKey: .pendingMediaDeletions) ?? []
    }

    public func validate() throws {
        guard (1...Self.currentVersion).contains(version) else { throw WallpaperError("不支持此素材库版本：\(version)。") }
        try settings.appearance.validate()
        try unique(media.map(\.id)); try unique(playlists.map(\.id)); try unique(displays.map(\.id))
        try unique(pendingMediaDeletions.map(\.id))
        guard Set(media.map(\.id)).isDisjoint(with: pendingMediaDeletions.map(\.id)),
              pendingMediaDeletions.allSatisfy({ $0.origin != nil }) else {
            throw WallpaperError("待清理记录不能引用仍在素材库中的壁纸或外部原文件。")
        }
        for item in pendingMediaDeletions { try item.validateBackend(schema: version) }
        for item in media {
            try item.validateBackend(schema: version)
            guard item.url.isFileURL, item.width > 0, item.height > 0,
                  item.duration.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw WallpaperError("素材元数据无效：\(item.name)。")
            }
        }
        let mediaIDs = Set(media.map(\.id))
        for list in playlists {
            guard !list.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  list.transition.isFinite, list.transition >= 0 else { throw WallpaperError("播放列表名称或过渡时间无效。") }
            try unique(list.entries.map(\.id))
            try EntryTiming.validateClockDuration(list.transition)
            for entry in list.entries {
                guard mediaIDs.contains(entry.mediaID) else { throw WallpaperError("播放列表引用了不存在的素材。") }
                try entry.timing.validate()
                try entry.audio.validate()
                let item = media.first { $0.id == entry.mediaID }!
                guard (item.kind != .web && item.kind != .scene) || entry.timing.mode == .seconds else {
                    throw WallpaperError("网页和场景壁纸仅支持固定停留时长。")
                }
                try EntryTiming.validateClockDuration(entry.timing.duration(mediaDuration: item.duration))
            }
        }
        for binding in displays {
            switch binding.source {
            case .playlist(let playlistID):
                guard let list = playlists.first(where: { $0.id == playlistID }),
                      binding.currentEntryID.map({ id in list.entries.contains { $0.id == id } }) ?? true else {
                    throw WallpaperError("显示器绑定引用了不存在的播放列表或条目。")
                }
            case .media(let mediaID, let audio):
                guard version >= 3 else { throw WallpaperError("旧版素材库不能包含直接应用的壁纸。") }
                guard mediaIDs.contains(mediaID) else { throw WallpaperError("显示器绑定引用了不存在的壁纸。") }
                guard binding.currentEntryID == nil else { throw WallpaperError("单张壁纸不能包含播放列表进度。") }
                try audio.validate()
            }
        }
        for bindings in Dictionary(grouping: displays, by: \.groupID).values {
            guard let first = bindings.first else { continue }
            guard bindings.allSatisfy({ $0.source == first.source && $0.fit == first.fit && $0.currentEntryID == first.currentEntryID }) else {
                throw WallpaperError("同步显示器组的播放来源、声音、显示方式或当前项不一致。")
            }
        }
    }
    private func unique<T: Hashable>(_ values: [T]) throws {
        guard Set(values).count == values.count else { throw WallpaperError("素材库包含重复标识。") }
    }
}
