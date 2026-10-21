import AppKit

enum ColorContrast {
    static func ratio(_ first: NSColor, _ second: NSColor) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func luminance(_ color: NSColor) -> Double {
        let components = [color.redComponent, color.greenComponent, color.blueComponent].map { value in
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return zip(components, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
