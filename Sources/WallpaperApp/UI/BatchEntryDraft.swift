import Foundation
import WallpaperCore

struct BatchEntryDraft {
    var changeTiming = false
    var changeMute = false
    var changeVolume = false
    var mode = TimingMode.seconds
    var durationValue = "30"
    var durationUnit = EntryDurationUnit.seconds
    var loops = "1"
    var muted = false
    var volume = 1.0

    func patch(hasVideo: Bool, hasWeb: Bool = false) throws -> EntryBatchPatch {
        var timing: EntryTiming?
        if changeTiming {
            guard !hasWeb || mode == .seconds else {
                throw WallpaperError("包含网页或场景时，仅支持固定停留时长。")
            }
            guard let value = Double(durationValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw WallpaperError("时长必须是有效数字，例如 30 或 12.5。")
            }
            let count: Int
            if mode == .loops {
                guard let parsed = Int(loops.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw WallpaperError("循环次数必须是正整数。")
                }
                count = parsed
            } else { count = 1 }
            timing = EntryTiming(mode: mode, seconds: durationUnit.seconds(for: value), loops: count)
        }
        let result = EntryBatchPatch(timing: timing, isMuted: changeMute ? muted : nil, volume: changeVolume ? volume : nil)
        try result.validate(hasVideo: hasVideo)
        return result
    }
}
