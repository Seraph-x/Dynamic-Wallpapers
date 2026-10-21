import Foundation
import WallpaperCore
@testable import WallpaperApp

@MainActor
struct PlaybackTimingFixture {
    let directory: URL
    let url: URL
    let sourceOffsets: [Double]

    static func make() async throws -> Self {
        let directory = TranscodeTestFixtures.root.appendingPathComponent(".build/verification/playback-timing/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("pulses.mkv")
        let arguments = ["-f", "lavfi", "-i", "testsrc2=s=160x90:r=30:d=3",
            "-f", "lavfi", "-i", "aevalsrc='0.1*sin(2*PI*997*t)*(between(t,0.5,0.6)+between(t,1.2,1.3)+between(t,2.2,2.3))':s=48000:d=3",
            "-vf", "drawbox=x=40:y=20:w=80:h=50:color=black:t=fill,drawbox=x=40:y=20:w=80:h=50:color=white:t=fill:enable='between(n,15,17)+between(n,36,38)+between(n,66,68)'",
            "-c:v", "h264_videotoolbox", "-allow_sw", "0", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-ac", "2", url.path]
        try JSONEncoder().encode(arguments).write(to: directory.appendingPathComponent("generate-arguments.json"))
        try await TranscodeTestFixtures.ffmpeg(arguments)
        let video = try await videoSamples(url, directory: directory)
        let audio = try await audioSamples(url, directory: directory)
        let videoEdges = try PulseTimingAnalysis.risingEdges(video, low: 0.1, high: 0.8)
        let audioEdges = try PulseTimingAnalysis.risingEdges(audio, low: 0.003, high: 0.015)
        guard videoEdges.count == 3, audioEdges.count == 3 else {
            throw WallpaperError("Generated source must contain three decoded pulses in both tracks")
        }
        // Use decoded track timestamps, not a claim that the muxer preserved lavfi start times.
        let offsets = zip(audioEdges, videoEdges).map { $0.upperBound - $1.upperBound }
        try JSONEncoder().encode(offsets).write(to: directory.appendingPathComponent("decoded-source-offsets.json"))
        try JSONEncoder().encode(video).write(to: directory.appendingPathComponent("decoded-video.json"))
        try JSONEncoder().encode(audio).write(to: directory.appendingPathComponent("decoded-audio-bins.json"))
        return Self(directory: directory, url: url, sourceOffsets: offsets)
    }

    private static func videoSamples(_ url: URL, directory: URL) async throws -> [PulseSample] {
        let times = try await TranscodeTestFixtures.frameTimes(url)
        let pixels = directory.appendingPathComponent("decoded-center.gray")
        try await TranscodeTestFixtures.ffmpeg(["-i", url.path, "-map", "0:v:0", "-vf",
            "crop=2:2:80:44,scale=1:1:flags=neighbor,format=gray", "-fps_mode", "passthrough",
            "-f", "rawvideo", pixels.path])
        let bytes = try Data(contentsOf: pixels)
        guard bytes.count == times.count else { throw WallpaperError("Decoded video timestamps/pixels disagree") }
        return zip(times, bytes).map { PulseSample(time: $0, value: Double($1) / 255) }
    }

    private static func audioSamples(_ url: URL, directory: URL) async throws -> [PulseSample] {
        let probe = try await TranscodeProcess().run(executable: TranscodeTestFixtures.tools.ffprobe,
            arguments: ["-v", "error", "-select_streams", "a:0", "-show_frames", "-show_entries",
                        "frame=best_effort_timestamp_time,nb_samples", "-of", "json", url.path], onLine: { _ in })
        guard probe.status == 0, probe.stderr.isEmpty else { throw WallpaperError("Source audio frame probe failed") }
        try probe.stdout.write(to: directory.appendingPathComponent("audio-frames.json"))
        struct Frame: Decodable { let best_effort_timestamp_time: String; let nb_samples: Int }
        struct Frames: Decodable { let frames: [Frame] }
        let frames = try JSONDecoder().decode(Frames.self, from: probe.stdout).frames
        guard !frames.isEmpty else { throw WallpaperError("Missing source audio frames") }
        let raw = directory.appendingPathComponent("decoded-audio.f32le")
        try await TranscodeTestFixtures.ffmpeg(["-i", url.path, "-map", "0:a:0", "-ac", "1", "-ar", "48000",
                                               "-f", "f32le", raw.path])
        let data = try Data(contentsOf: raw)
        guard data.count % 4 == 0, data.count / 4 == frames.reduce(0, { $0 + $1.nb_samples }) else {
            throw WallpaperError("Decoded audio timestamps/sample count disagree")
        }
        let samples: [Float] = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
        let timeline = try frames.map { frame -> PulseTimingAnalysis.AudioFrame in
            guard let time = Double(frame.best_effort_timestamp_time), time.isFinite else {
                throw WallpaperError("Invalid source audio frame timestamp")
            }
            return .init(time: time, sampleCount: frame.nb_samples)
        }
        return try PulseTimingAnalysis.audioBins(samples: samples, frames: timeline)
    }
}
