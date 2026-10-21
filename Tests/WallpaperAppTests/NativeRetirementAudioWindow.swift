import Foundation
import WallpaperCore

/// Uses the existing system-output stable windows; all raw packets remain in the
/// evidence file. This does not assert continuous coverage or physical acoustics.
struct NativeRetirementAudioWindow: Codable {
    let name: String
    let start: Double
    let end: Double
    let expectsSilence: Bool

    struct Report: Codable {
        let name: String
        let stableRMS: Double
        let stablePackets: Int
        let stableFirst: Double
        let stableLast: Double
        let minGap: Double
        let maxGap: Double
        let lastNonzeroOffset: Double?
    }

    func analyze(_ packets: [SystemAudioEvidence.Packet]) throws -> Report {
        guard start.isFinite, end.isFinite, end > start + 0.25 else {
            throw WallpaperError("\(name)：声音验收时间范围无效。")
        }
        guard packets.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start &&
            $0.energy.isFinite && $0.energy >= 0 && $0.samples > 0 }) else {
            throw WallpaperError("\(name)：声音采样数据无效。")
        }
        let stable = packets.filter { $0.start >= start + 0.25 && $0.end <= end }
        guard stable.count > 10, let first = stable.first, let last = stable.last,
              first.start <= start + 0.28, last.end >= end - 0.10 else {
            throw WallpaperError("\(name)：声音采集覆盖不足，不能判定静音。")
        }
        let energy = stable.reduce(0) { $0 + $1.energy }
        let sampleCount = stable.reduce(0) { $0 + $1.samples }
        let rms = sqrt(energy / Double(sampleCount))
        guard rms.isFinite else { throw WallpaperError("\(name)：声音能量无效。") }
        if expectsSilence && rms != 0 {
            throw WallpaperError("\(name)：检测到旧声音持续或复响，stableRMS=\(rms)。")
        }
        if !expectsSilence && rms <= 0.0001 {
            throw WallpaperError("\(name)：未采到有声正控制，不能证明采集覆盖被测播放器。")
        }
        let gaps = zip(stable, stable.dropFirst()).map { $1.start - $0.end }
        let lastNonzero = packets.compactMap(\.lastNonzero).filter { $0 >= start && $0 <= end }.max()
        return Report(name: name, stableRMS: rms, stablePackets: stable.count,
                      stableFirst: first.start, stableLast: last.end,
                      minGap: gaps.min()!, maxGap: gaps.max()!,
                      lastNonzeroOffset: lastNonzero.map { $0 - start })
    }
}
