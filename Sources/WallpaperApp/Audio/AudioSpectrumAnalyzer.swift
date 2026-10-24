import Accelerate
import Foundation
import WallpaperCore

struct AudioSpectrum: Equatable, Sendable {
    let left: [Float]
    let right: [Float]
    static let zero = AudioSpectrum(left: Array(repeating: 0, count: 64), right: Array(repeating: 0, count: 64))
}

/// Confined to the capture queue. Non-overlapping windows bound both work and memory.
final class AudioSpectrumAnalyzer {
    private static let size = 2048
    private let sampleRate: Double
    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    private let normalization: Float
    private var left = [Float](repeating: 0, count: size)
    private var right = [Float](repeating: 0, count: size)
    private var position = 0
    private var real = [Float](repeating: 0, count: size)
    private let imaginary = [Float](repeating: 0, count: size)
    private var resultReal = [Float](repeating: 0, count: size)
    private var resultImaginary = [Float](repeating: 0, count: size)

    init(sampleRate: Double) throws {
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate),
              let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD) else {
            throw WallpaperError("无效的系统音频采样率或 FFT 初始化失败。")
        }
        self.sampleRate = sampleRate; self.setup = setup
        window = (0..<Self.size).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(Self.size))) }
        normalization = 2 / window.reduce(0, +)
    }
    deinit { vDSP_DFT_DestroySetup(setup) }

    func band(for frequency: Double) -> Int {
        let maximum = min(20000, sampleRate / 2)
        return min(63, max(0, Int(floor(log(max(20, frequency) / 20) / log(maximum / 20) * 64))))
    }

    func append(left: [Float], right: [Float]) throws -> AudioSpectrum? {
        guard left.count == right.count, left.allSatisfy(\.isFinite), right.allSatisfy(\.isFinite) else {
            throw WallpaperError("系统音频包含无效采样或不匹配的声道。")
        }
        var latest: AudioSpectrum?
        for index in left.indices {
            self.left[position] = left[index]; self.right[position] = right[index]
            position += 1
            if position == Self.size {
                latest = AudioSpectrum(left: transform(self.left), right: transform(self.right))
                position = 0
            }
        }
        return latest
    }

    private func transform(_ samples: [Float]) -> [Float] {
        for index in real.indices { real[index] = samples[index] * window[index] }
        vDSP_DFT_Execute(setup, real, imaginary, &resultReal, &resultImaginary)
        var bands = [Float](repeating: 0, count: 64)
        for index in 1..<(Self.size / 2) {
            let frequency = Double(index) * sampleRate / Double(Self.size)
            guard frequency >= 20, frequency <= 20000 else { continue }
            let magnitude = hypot(resultReal[index], resultImaginary[index]) * normalization
            let target = band(for: frequency)
            bands[target] = max(bands[target], min(1, magnitude))
        }
        return bands
    }
}
