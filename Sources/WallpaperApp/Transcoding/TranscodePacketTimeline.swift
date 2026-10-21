import Foundation
import WallpaperCore

/// Streaming packet-span measurement of only the selected tracks. Called on one
/// stdout-reader thread, then consumed after that reader has joined.
final class TranscodePacketTimeline: @unchecked Sendable {
    private let media: TranscodeMedia
    private var video = Track()
    private var audio = Track()
    private var failure: Error?

    init(media: TranscodeMedia) { self.media = media }

    func accept(_ line: String) {
        guard failure == nil, !line.isEmpty else { return }
        var fields: [String: String] = [:]
        for field in line.split(separator: "|") {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        guard let index = fields["stream_index"].flatMap(Int.init) else {
            failure = WallpaperError("无法解析 FFprobe 媒体包轨道：\(line)"); return
        }
        guard index == media.videoIndex || index == media.audioIndex else { return }
        guard let pts = fields["pts_time"].flatMap(Double.init), pts.isFinite,
              let duration = fields["duration_time"].flatMap(Double.init), duration.isFinite, duration > 0,
              (pts + duration).isFinite else {
            failure = WallpaperError("选定轨道的媒体包缺少有效时间戳或时长：\(line)"); return
        }
        if index == media.videoIndex { video.append(pts: pts, duration: duration) }
        else { audio.append(pts: pts, duration: duration) }
    }

    func finish() throws -> TranscodeTimeline {
        if let failure { throw failure }
        guard media.timeBase != nil else { throw WallpaperError("选定视频轨道的时间基无法验证。") }
        return try TranscodeTimeline(video: video.finish(), audio: media.audioIndex == nil ? nil : audio.finish())
    }

    private struct Track {
        var start = Double.infinity
        var end = -Double.infinity
        var maxDuration: Double = 0
        mutating func append(pts: Double, duration: Double) {
            start = min(start, pts); end = max(end, pts + duration)
            maxDuration = max(maxDuration, duration)
        }
        func finish() throws -> TranscodeTrackTimeline {
            guard (end - start).isFinite, end > start else {
                throw WallpaperError("选定的视频或音频轨道没有可验证的媒体包时间线。")
            }
            return TranscodeTrackTimeline(start: start, end: end, maxPacketDuration: maxDuration)
        }
    }
}
