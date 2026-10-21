import Foundation
import Darwin
import WallpaperCore

@MainActor
enum FFmpegJob {
    static func inspect(source: URL, tools: TranscodeTools) async throws -> TranscodeMedia {
        try await TranscodeInput.withFile(source: source) { @MainActor @Sendable input in
            try FileManager.default.createDirectory(at: tools.temporaryDirectory,
                withIntermediateDirectories: true)
            return try await TranscodeWorkspace.withDirectory(in: tools.temporaryDirectory,
                successCleanupMessage: "清理探测临时目录失败") { @MainActor @Sendable staging in
                let fields = "stream=index,codec_type,codec_name,width,height,avg_frame_rate,sample_aspect_ratio,time_base,start_time,duration,sample_rate:stream_disposition=attached_pic:stream_side_data=rotation:stream_tags=DURATION:format=duration,format_name,start_time"
                let result = try await TranscodeProcess().run(executable: tools.ffprobe, arguments: [
                    "-v", "error", "-protocol_whitelist", "fd", "-format_whitelist", "mov,matroska,webm,avi",
                    "-show_entries", fields, "-of", "json", "fd:"
                ], input: input.file, errorLog: staging.appendingPathComponent("ffprobe.log"), onLine: { _ in })
                try requireSuccess(result, operation: "原文件检查", tools: tools)
                let media = try TranscodeMedia(json: result.stdout, sourceRevision: input.revision)
                let timeline = try await inspectPackets(input: input, media: media, tools: tools, staging: staging)
                try input.verifyUnchanged()
                return try TranscodeMedia(json: result.stdout, sourceRevision: input.revision, timeline: timeline)
            }
        }
    }

    static func run(request: TranscodeRequest, tools: TranscodeTools,
                    onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        return try await TranscodeInput.withFile(source: request.source) { @MainActor @Sendable input in
            guard request.plan.media.sourceRevision == input.revision else {
                throw WallpaperError("原文件已变化或尚未完成检查，未开始转码；请重新选择并检查。")
            }
            return try await encode(request: request, input: input, tools: tools, onProgress: onProgress)
        }
    }

    private static func encode(request: TranscodeRequest, input: TranscodeInput, tools: TranscodeTools,
                               onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try requireAbsent(request.destination)
        return try await TranscodeWorkspace.withDirectory(in: request.destination.deletingLastPathComponent(),
            successCleanupMessage: "文件已保存到 \(request.destination.path)，但临时文件清理失败。") { @MainActor @Sendable staging in
            let output = staging.appendingPathComponent("output.mp4")
            let progress = ProgressDelivery(duration: request.plan.media.duration, receive: onProgress)
            let result = try await TranscodeProcess().run(executable: tools.ffmpeg,
                arguments: request.plan.arguments(source: request.source, stagedOutput: output, useInputFileDescriptor: true),
                input: input.file, captureStandardOutput: false,
                errorLog: staging.appendingPathComponent("ffmpeg.log")) { line in
                    progress.accept(line)
                }
            // Flush queued progress before probing/publishing; progress=end alone never commits.
            await progress.flush()
            try requireSuccess(result, operation: "转码", tools: tools)
            try input.verifyUnchanged()
            try input.close()
            try Task.checkCancellation()
            let actual = try await inspect(source: output, tools: tools)
            try validateOutput(actual, plan: request.plan)
            try await decodeOutput(output, actual: actual, tools: tools, staging: staging)
            try Task.checkCancellation()
            try ExclusiveFileCommit.commit(staged: output, destination: request.destination)
            return request.destination
        }
    }

    private static func inspectPackets(input: TranscodeInput, media: TranscodeMedia,
                                       tools: TranscodeTools, staging: URL) async throws -> TranscodeTimeline {
        try input.file.seek(toOffset: 0)
        let scanner = TranscodePacketTimeline(media: media)
        let result = try await TranscodeProcess().run(executable: tools.ffprobe, arguments: [
            "-v", "error", "-protocol_whitelist", "fd", "-format_whitelist", "mov,matroska,webm,avi",
            "-show_packets", "-show_entries", "packet=stream_index,pts_time,duration_time",
            "-of", "compact=p=0:nk=0", "fd:"
        ], input: input.file, captureStandardOutput: false,
            errorLog: staging.appendingPathComponent("packet-probe.log"), onLine: { scanner.accept($0) })
        try requireSuccess(result, operation: "时间线检查", tools: tools)
        return try scanner.finish()
    }

    private static func decodeOutput(_ output: URL, actual: TranscodeMedia,
                                     tools: TranscodeTools, staging: URL) async throws {
        try await TranscodeInput.withFile(source: output) { @MainActor @Sendable input in
            guard input.revision == actual.sourceRevision else { throw WallpaperError("输出文件在校验期间发生变化，未保存到所选位置。") }
            var arguments = ["-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "fd",
                             "-format_whitelist", "mov", "-i", "fd:", "-map", "0:v:0"]
            if actual.audioIndex != nil { arguments += ["-map", "0:a:0"] }
            arguments += ["-f", "null", "-"]
            let result = try await TranscodeProcess().run(executable: tools.ffmpeg, arguments: arguments,
                input: input.file, captureStandardOutput: false,
                errorLog: staging.appendingPathComponent("output-decode.log"), onLine: { _ in })
            try requireSuccess(result, operation: "输出解码检查", tools: tools)
            try input.verifyUnchanged()
        }
    }

    static func requireAbsent(_ destination: URL) throws {
        var info = stat()
        let result = destination.withUnsafeFileSystemRepresentation { lstat($0!, &info) }
        if result == 0 { throw WallpaperError("输出文件已存在，请更名；未覆盖任何文件。") }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func requireSuccess(_ result: TranscodeProcess.Output, operation: String, tools: TranscodeTools) throws {
        // Both tools run at -v error. A zero exit does not erase a demuxer or
        // decoder error (e.g. Matroska can log premature EOF and return success).
        guard result.status == 0, result.stderrByteCount == 0 else {
            var diagnostic = String(decoding: result.stderr, as: UTF8.self)
            if let log = result.errorLog {
                let saved = tools.diagnosticsDirectory.appendingPathComponent(UUID().uuidString + ".log")
                do {
                    try FileManager.default.createDirectory(at: tools.diagnosticsDirectory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: log, to: saved)
                } catch {
                    throw TranscodeDiagnosticPreservationError(context: "FFmpeg \(operation)失败（exit \(result.status)）",
                                                               originalLog: log, underlying: error)
                }
                diagnostic = "完整诊断（\(result.stderrByteCount) 字节）：\(saved.path)"
            }
            throw WallpaperError("\(operation)失败。", diagnostic: "FFmpeg \(operation)失败（exit \(result.status)）：\(diagnostic)")
        }
    }
    static func validateOutput(_ actual: TranscodeMedia, plan: TranscodePlan) throws {
        guard actual.videoCodec == "h264", actual.audioCodec == (plan.media.audioIndex == nil ? nil : "aac"),
              actual.width == plan.width, actual.height == plan.height,
              actual.formatName.split(separator: ",").contains("mp4"), actual.rotation == 0 else {
            throw WallpaperError("输出的轨道、格式或尺寸不符合预设，未保存到所选位置。")
        }
        guard let expectedTimeline = plan.media.timeline, let actualTimeline = actual.timeline,
              let sourceTick = plan.media.timeBase, let outputTick = actual.timeBase else {
            throw WallpaperError("无法验证输出文件的完整时长，未保存到所选位置。")
        }
        // Validate each selected track, not their union: complete audio must not
        // hide truncated video. Priming/padding applies only to audio, not video.
        let precision = 2 * (sourceTick + outputTick)
        let videoTolerance = precision + (plan.frameRateLimit.map { 1 / Double($0) } ?? 0)
        try validateTrackDuration(actualTimeline.video, expected: expectedTimeline.video,
                                  tolerance: videoTolerance, track: "视频")
        if let expectedAudio = expectedTimeline.audio, let actualAudio = actualTimeline.audio {
            let audioTolerance = precision + 2 * max(expectedAudio.maxPacketDuration, actualAudio.maxPacketDuration)
            try validateTrackDuration(actualAudio, expected: expectedAudio, tolerance: audioTolerance, track: "音频")
            let expectedOffset = expectedAudio.start - expectedTimeline.video.start
            let actualOffset = actualAudio.start - actualTimeline.video.start
            guard abs(actualOffset - expectedOffset) <= audioTolerance else {
                throw WallpaperError("输出文件的音画同步发生变化，未保存到所选位置。",
                    diagnostic: "音视频相对起点：输入 \(expectedOffset) 秒，输出 \(actualOffset) 秒。")
            }
        }
    }

    private static func validateTrackDuration(_ actual: TranscodeTrackTimeline, expected: TranscodeTrackTimeline,
                                              tolerance: Double, track: String) throws {
        guard abs(actual.duration - expected.duration) <= tolerance else {
            throw WallpaperError("输出\(track)时长不符合预期，未保存到所选位置。",
                diagnostic: "输入 \(expected.duration) 秒，输出 \(actual.duration) 秒，容差 \(tolerance) 秒。")
        }
    }
}

/// Main-queue ordering ensures no progress delivery after job completion.
private final class ProgressDelivery: @unchecked Sendable {
    let duration: Double
    let receive: @MainActor (Double) -> Void
    init(duration: Double, receive: @escaping @MainActor (Double) -> Void) {
        self.duration = duration; self.receive = receive
    }
    func accept(_ line: String) {
        guard line.hasPrefix("out_time_us="), let value = Double(line.dropFirst("out_time_us=".count)),
              value.isFinite, value >= 0 else { return }
        let fraction = min(1, value / 1_000_000 / duration)
        DispatchQueue.main.async { self.receive(fraction) }
    }
    func flush() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
}
