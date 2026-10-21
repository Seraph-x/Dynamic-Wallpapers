import Foundation

enum EntryDurationUnit: String, CaseIterable {
    case seconds = "s"
    case minutes = "m"
    case hours = "h"

    var secondsPerUnit: Double {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 3_600
        }
    }

    static func preferred(for seconds: Double) -> Self {
        if seconds >= 3_600, Self.hours.canDisplay(seconds) { return .hours }
        if seconds >= 60, Self.minutes.canDisplay(seconds) { return .minutes }
        return .seconds
    }

    func value(for seconds: Double) -> Double { seconds / secondsPerUnit }
    func seconds(for value: Double) -> Double { value * secondsPerUnit }

    private func canDisplay(_ seconds: Double) -> Bool {
        let value = value(for: seconds)
        let rounded = (value * 100).rounded() / 100
        return abs(self.seconds(for: rounded) - seconds) < 0.000_001
    }
}
