import Foundation
import WallpaperCore

/// Diagnostic data only; these types never enter the application's playback clock.
struct PulseSample: Codable {
    let time: Double
    let value: Double
    var duration: Double = 0
}

enum PulseTimingAnalysis {
    // 64 divides this fixture's 1024-frame AAC packets and SCK's 960-frame packets.
    // It avoids a 16-frame tail bin sharing its timestamp with the next ms-quantized AAC frame.
    static let audioBinFrames = 64
    struct Edge: Codable {
        let lowerBound: Double
        let upperBound: Double
    }
    struct Offset: Codable {
        let association: String
        let pulseIdentityVerified: Bool
        let video: Edge
        let audio: Edge
        let sourceOffset: Double
        /// Positive means captured audio follows the WindowServer video observation.
        let audioMinusVideo: Double
        let lowerBound: Double
        let upperBound: Double
    }
    struct AudioFrame {
        let time: Double
        let sampleCount: Int
    }

    static func audioBins(samples: [Float], frames: [AudioFrame]) throws -> [PulseSample] {
        guard samples.allSatisfy(\.isFinite) else { throw WallpaperError("Invalid source PCM") }
        var offset = 0
        var previousTime = -Double.infinity
        var bins: [PulseSample] = []
        for frame in frames {
            guard frame.time.isFinite, frame.time > previousTime, frame.sampleCount > 0,
                  frame.sampleCount <= samples.count - offset else { throw WallpaperError("Invalid source PCM timeline") }
            previousTime = frame.time
            for local in stride(from: 0, to: frame.sampleCount, by: audioBinFrames) {
                let end = min(local + audioBinFrames, frame.sampleCount)
                let energy = samples[(offset + local)..<(offset + end)].reduce(0.0) {
                    $0 + Double($1) * Double($1)
                }
                bins.append(PulseSample(time: frame.time + Double(local) / 48000,
                    value: sqrt(energy / Double(end - local)), duration: Double(end - local) / 48000))
            }
            offset += frame.sampleCount
        }
        guard offset == samples.count else { throw WallpaperError("Source PCM frame/sample count disagree") }
        return bins
    }

    static func risingEdges(_ samples: [PulseSample], low: Double, high: Double) throws -> [Edge] {
        guard low.isFinite, high.isFinite, low < high else { throw WallpaperError("Invalid pulse thresholds") }
        var previousTime = -Double.infinity
        var lastLow: Double?
        var edges: [Edge] = []
        for sample in samples {
            guard sample.time.isFinite, sample.value.isFinite, sample.duration.isFinite,
                  sample.duration >= 0, sample.time > previousTime else {
                throw WallpaperError("Invalid or unordered pulse samples")
            }
            previousTime = sample.time
            if sample.value <= low { lastLow = sample.time }
            if sample.value >= high, let lower = lastLow {
                edges.append(Edge(lowerBound: lower, upperBound: sample.time + sample.duration))
                lastLow = nil
            }
        }
        return edges
    }

    static func compare(video: [PulseSample], audio: [PulseSample], sourceOffsets: [Double]) throws -> [Offset] {
        let videoEdges = try risingEdges(video, low: 0.1, high: 0.8)
        // Fixed to the generated sine-burst fixture, not a general audio detector.
        let audioEdges = try risingEdges(audio, low: 0.003, high: 0.015)
        guard !sourceOffsets.isEmpty, sourceOffsets.allSatisfy(\.isFinite),
              videoEdges.count == sourceOffsets.count, audioEdges.count == sourceOffsets.count else {
            throw WallpaperError("Pulse evidence incomplete: video=\(videoEdges.count), audio=\(audioEdges.count), expected=\(sourceOffsets.count)")
        }
        return zip(zip(videoEdges, audioEdges), sourceOffsets).map { pair, source in
            let (video, audio) = pair
            return Offset(association: "ordinal-count-only", pulseIdentityVerified: false,
                          video: video, audio: audio, sourceOffset: source,
                          audioMinusVideo: audio.upperBound - video.upperBound - source,
                          lowerBound: audio.lowerBound - video.upperBound - source,
                          upperBound: audio.upperBound - video.lowerBound - source)
        }
    }
}
