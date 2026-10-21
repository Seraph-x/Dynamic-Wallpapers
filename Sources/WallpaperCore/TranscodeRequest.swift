import Foundation

public enum TranscodePreset: String, CaseIterable, Identifiable, Sendable {
    case original, hd1080
    public var id: String { rawValue }
    public var title: String { self == .original ? "原尺寸 · 原帧率" : "适配 1080p · 最高约 30 fps" }
}

public struct TranscodeTrackTimeline: Sendable {
    public let start: Double
    public let end: Double
    public let maxPacketDuration: Double
    public var duration: Double { end - start }
    var isValid: Bool { start.isFinite && end.isFinite && duration.isFinite && duration > 0 && maxPacketDuration.isFinite && maxPacketDuration > 0 }
    public init(start: Double, end: Double, maxPacketDuration: Double) {
        self.start = start; self.end = end; self.maxPacketDuration = maxPacketDuration
    }
}

public struct TranscodeTimeline: Sendable {
    public let video: TranscodeTrackTimeline
    public let audio: TranscodeTrackTimeline?
    public var duration: Double { max(video.end, audio?.end ?? video.end) - min(video.start, audio?.start ?? video.start) }
    public var maxAudioPacketDuration: Double { audio?.maxPacketDuration ?? 0 }
    public init(video: TranscodeTrackTimeline, audio: TranscodeTrackTimeline?) {
        self.video = video; self.audio = audio
    }
}

/// Strict ffprobe metadata. Cover art is not a playable video track.
public struct TranscodeMedia: Sendable {
    public let videoIndex: Int
    public let audioIndex: Int?
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let duration: Double
    public let rotation: Int
    public let sampleAspectRatio: Double
    public let videoCodec: String
    public let audioCodec: String?
    public let formatName: String
    public let sourceRevision: TranscodeSourceRevision?
    public let timeBase: Double?
    public let timeline: TranscodeTimeline?

    public init(json: Data, sourceRevision: TranscodeSourceRevision? = nil, timeline: TranscodeTimeline? = nil) throws {
        let probe = try JSONDecoder().decode(Probe.self, from: json)
        guard let video = probe.streams.first(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }),
              video.index >= 0, let width = video.width, let height = video.height, width > 0, height > 0,
              let rate = video.avg_frame_rate, let duration = Double(probe.format.duration),
              duration.isFinite, duration > 0, let codec = video.codec_name else {
            throw WallpaperError("转码输入缺少有效视频轨道、尺寸、帧率或时长。")
        }
        let frameRate = try Self.ratio(rate, separator: "/")
        let aspect: Double
        if let sar = video.sample_aspect_ratio, sar != "N/A" {
            aspect = try Self.ratio(sar, separator: ":")
        } else { aspect = 1 } // Unspecified SAR denotes no declared pixel-aspect correction.
        let rotationValue = video.side_data_list?.compactMap(\.rotation).first ?? 0
        guard rotationValue.isFinite, rotationValue.truncatingRemainder(dividingBy: 90) == 0,
              abs(rotationValue) <= 360 else {
            throw WallpaperError("转码不支持此非直角旋转元数据，未更改源文件。")
        }
        let audio = probe.streams.first { $0.codec_type == "audio" }
        guard audio == nil || (audio!.index >= 0 && audio!.codec_name != nil) else {
            throw WallpaperError("音频轨道元数据无效。")
        }
        self.videoIndex = video.index; self.audioIndex = audio?.index
        self.width = width; self.height = height; self.frameRate = frameRate
        if let timeline {
            guard timeline.duration.isFinite, timeline.duration > 0,
                  timeline.video.isValid, timeline.audio?.isValid != false,
                  (timeline.audio == nil) == (audio == nil) else {
                throw WallpaperError("选定轨道时间线无效。")
            }
        }
        self.duration = timeline?.duration ?? duration; self.rotation = Int(rotationValue)
        self.sampleAspectRatio = aspect; self.videoCodec = codec; self.audioCodec = audio?.codec_name
        self.formatName = probe.format.format_name ?? ""
        self.sourceRevision = sourceRevision
        self.timeBase = try video.time_base.map { try Self.ratio($0, separator: "/") }
        self.timeline = timeline
    }

    private static func ratio(_ value: String, separator: Character) throws -> Double {
        let parts = value.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]),
              numerator.isFinite, denominator.isFinite, numerator > 0, denominator > 0,
              (numerator / denominator).isFinite else { throw WallpaperError("无效媒体比例：\(value)") }
        return numerator / denominator
    }
    private struct Probe: Decodable {
        let streams: [Stream]
        let format: Format
    }
    private struct Format: Decodable { let duration: String; let format_name: String? }
    private struct Stream: Decodable {
        let index: Int
        let codec_type: String
        let codec_name: String?
        let width: Int?
        let height: Int?
        let avg_frame_rate: String?
        let sample_aspect_ratio: String?
        let time_base: String?
        let disposition: [String: Int]?
        let side_data_list: [SideData]?
    }
    private struct SideData: Decodable { let rotation: Double? }
}

public struct TranscodePlan: Sendable {
    public let media: TranscodeMedia
    public let preset: TranscodePreset
    public let width: Int
    public let height: Int
    public let frameRateLimit: Int?
    public let videoFilter: String

    public init(media: TranscodeMedia, preset: TranscodePreset) throws {
        var displayWidth = Double(media.width) * media.sampleAspectRatio
        var displayHeight = Double(media.height)
        if abs(media.rotation) % 180 == 90 { swap(&displayWidth, &displayHeight) }
        guard displayWidth.isFinite, displayHeight.isFinite, displayWidth >= 1, displayHeight >= 1,
              displayWidth < Double(Int32.max - 2), displayHeight < Double(Int32.max - 2) else {
            throw WallpaperError("转码显示尺寸不可表示。")
        }
        self.media = media; self.preset = preset
        let scale = preset == .hd1080 ? min(1, 1920 / displayWidth, 1080 / displayHeight) : 1
        let scaledWidth = Int((displayWidth * scale).rounded(.down))
        let scaledHeight = Int((displayHeight * scale).rounded(.down))
        if preset == .original {
            width = (scaledWidth + 1) / 2 * 2; height = (scaledHeight + 1) / 2 * 2
            videoFilter = "scale=\(scaledWidth):\(scaledHeight),setsar=1,pad=\(width):\(height):0:0"
        } else {
            width = scaledWidth / 2 * 2; height = scaledHeight / 2 * 2
            // Average FPS cannot identify high-rate VFR segments. Compare integer
            // PTS ticks; round the 30 fps interval to the input timebase so 33/34 ms
            // quantization does not incorrectly discard ordinary 30 fps frames.
            videoFilter = "scale=\(width):\(height),setsar=1,select='isnan(prev_selected_pts)+gte(pts-prev_selected_pts,floor(1/(30*TB)+0.5))'"
        }
        guard width >= 2, height >= 2 else { throw WallpaperError("输出尺寸小于 H.264 所需的偶数尺寸。") }
        frameRateLimit = preset == .hd1080 ? 30 : nil
    }

    public func arguments(source: URL, stagedOutput: URL, useInputFileDescriptor: Bool = false) throws -> [String] {
        guard source.isFileURL, stagedOutput.isFileURL,
              source.standardizedFileURL.resolvingSymlinksInPath() != stagedOutput.standardizedFileURL.resolvingSymlinksInPath() else {
            throw WallpaperError("转码必须使用不同的本地输入和输出文件。")
        }
        var result = ["-nostdin", "-hide_banner", "-v", "error", "-xerror", "-n", "-stats_period", "0.1", "-progress", "pipe:1",
                      "-protocol_whitelist", useInputFileDescriptor ? "fd" : "file",
                      "-format_whitelist", "mov,matroska,webm,avi", "-i", useInputFileDescriptor ? "fd:" : source.path,
                      "-map", "0:\(media.videoIndex)"]
        if let audio = media.audioIndex { result += ["-map", "0:\(audio)"] }
        result += ["-map_metadata", "-1", "-map_chapters", "-1", "-sn", "-dn", "-vf", videoFilter,
                   "-c:v", "h264_videotoolbox", "-allow_sw", "0", "-b:v", "8M", "-pix_fmt", "yuv420p", "-c:a", "aac"]
        result += ["-fps_mode:v", "vfr", "-enc_time_base:v", "demux",
                   "-movflags", "+faststart", "-f", "mp4", stagedOutput.path]
        return result
    }
}

public struct TranscodeRequest: Sendable {
    public let source: URL
    public let destination: URL
    public let plan: TranscodePlan
    public init(source: URL, destination: URL, plan: TranscodePlan) throws {
        guard source.isFileURL, destination.isFileURL, destination.pathExtension.lowercased() == "mp4",
              source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else {
            throw WallpaperError("请选择不同于源文件的新 MP4 输出路径。")
        }
        self.source = source; self.destination = destination; self.plan = plan
    }
}
