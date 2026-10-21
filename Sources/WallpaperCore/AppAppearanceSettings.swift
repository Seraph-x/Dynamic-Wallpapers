import Foundation

public enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public enum GlassBlurStyle: String, Codable, CaseIterable, Sendable {
    case clear, frosted
}

public enum WallpaperMirrorFrameRate: Int, Codable, CaseIterable, Sendable {
    case hz30 = 30
    case hz60 = 60
}

public struct AppAccentColor: Codable, Equatable, Hashable, Sendable {
    public static let defaultAccent = AppAccentColor(red: 0xBF, green: 0xE2, blue: 0xFF)

    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red; self.green = green; self.blue = blue
    }

    public init(hexCode: String) throws {
        let trimmed = hexCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            throw WallpaperError("主题颜色代码必须使用 #RRGGBB 格式。")
        }
        red = UInt8((value >> 16) & 0xff)
        green = UInt8((value >> 8) & 0xff)
        blue = UInt8(value & 0xff)
    }

    public var hexCode: String { String(format: "#%02X%02X%02X", red, green, blue) }

    public init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        do { try self.init(hexCode: values.decode(String.self)) }
        catch {
            throw DecodingError.dataCorruptedError(in: values, debugDescription: error.localizedDescription)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.singleValueContainer()
        try values.encode(hexCode)
    }
}

public struct AppAppearanceSettings: Codable, Equatable, Sendable {
    public var transparency: Double
    public var blur: GlassBlurStyle
    public var fullScreenFrameRate: WallpaperMirrorFrameRate
    public var theme: AppTheme
    public var accentColor: AppAccentColor

    public init(transparency: Double = 0.75, blur: GlassBlurStyle = .frosted,
                fullScreenFrameRate: WallpaperMirrorFrameRate = .hz30, theme: AppTheme = .system,
                accentColor: AppAccentColor = .defaultAccent) {
        self.transparency = transparency
        self.blur = blur
        self.fullScreenFrameRate = fullScreenFrameRate
        self.theme = theme
        self.accentColor = accentColor
    }

    public func validate() throws {
        guard transparency.isFinite, (0...1).contains(transparency) else {
            throw WallpaperError("界面背景透明度必须在 0% 到 100% 之间。")
        }
    }

    private enum CodingKeys: String, CodingKey { case transparency, blur, fullScreenFrameRate, theme, accentColor }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transparency = try values.decode(Double.self, forKey: .transparency)
        blur = try values.decode(GlassBlurStyle.self, forKey: .blur)
        fullScreenFrameRate = values.contains(.fullScreenFrameRate)
            ? try values.decode(WallpaperMirrorFrameRate.self, forKey: .fullScreenFrameRate) : .hz30
        theme = values.contains(.theme) ? try values.decode(AppTheme.self, forKey: .theme) : .system
        accentColor = values.contains(.accentColor)
            ? try values.decode(AppAccentColor.self, forKey: .accentColor) : .defaultAccent
        try validate()
    }
}
