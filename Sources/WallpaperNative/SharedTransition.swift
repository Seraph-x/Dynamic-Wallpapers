import QuartzCore

/// One logical progress drives both view opacity and linear audio amplitude.
@MainActor
public enum SharedTransition {
    private static let updateInterval = 1.0 / 60

    public static func run(duration: Double, apply: (Double) -> Void) async throws {
        guard duration > 0 else { apply(1); return }
        let started = ProcessInfo.processInfo.systemUptime
        apply(0)
        while true {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed >= duration { apply(1); return }
            apply(easedProgress(elapsed / duration))
            try await Task.sleep(for: .seconds(min(updateInterval, duration - elapsed)))
        }
    }

    /// Preserve the previous Core Animation easeInEaseOut curve. Its Bezier
    /// parameter is not time: invert x before evaluating opacity/amplitude y.
    private static func easedProgress(_ time: Double) -> Double {
        let curve = CAMediaTimingFunction(name: .easeInEaseOut)
        var first: [Float] = [0, 0], second: [Float] = [0, 0]
        curve.getControlPoint(at: 1, values: &first)
        curve.getControlPoint(at: 2, values: &second)
        func coordinate(_ t: Double, _ a: Float, _ b: Float) -> Double {
            let inverse = 1 - t
            return 3 * inverse * inverse * t * Double(a) + 3 * inverse * t * t * Double(b) + t * t * t
        }
        var lower = 0.0, upper = 1.0
        // Bisection error is below a Float gain's precision; no device calibration.
        for _ in 0..<30 {
            let middle = (lower + upper) / 2
            if coordinate(middle, first[0], second[0]) < time { lower = middle }
            else { upper = middle }
        }
        return coordinate((lower + upper) / 2, first[1], second[1])
    }
}
