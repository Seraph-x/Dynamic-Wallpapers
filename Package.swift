// swift-tools-version: 6.0
import PackageDescription
import Foundation

private struct ConfigurationError: Error, CustomStringConvertible {
    let description: String
}

private indirect enum JSONValue {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null
}

private struct StrictJSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) { bytes = Array(data) }

    mutating func parse() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("Unexpected trailing content") }
        return value
    }

    private mutating func parseValue() throws -> JSONValue {
        guard let byte = current else { throw error("Unexpected end of input") }
        switch byte {
        case 0x7B: return try parseObject()
        case 0x5B: return try parseArray()
        case 0x22: return .string(try parseString())
        case 0x74: try consumeLiteral("true"); return .boolean(true)
        case 0x66: try consumeLiteral("false"); return .boolean(false)
        case 0x6E: try consumeLiteral("null"); return .null
        case 0x2D, 0x30...0x39: return .number(try parseNumber())
        default: throw error("Unexpected byte \(byte)")
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try consume(0x7B)
        skipWhitespace()
        var result: [String: JSONValue] = [:]
        if take(0x7D) { return .object(result) }
        while true {
            guard current == 0x22 else { throw error("Object key must be a string") }
            let key = try parseString()
            guard result[key] == nil else { throw error("Duplicate JSON key: \(key)") }
            skipWhitespace()
            try consume(0x3A)
            skipWhitespace()
            result[key] = try parseValue()
            skipWhitespace()
            if take(0x7D) { return .object(result) }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try consume(0x5B)
        skipWhitespace()
        var result: [JSONValue] = []
        if take(0x5D) { return .array(result) }
        while true {
            result.append(try parseValue())
            skipWhitespace()
            if take(0x5D) { return .array(result) }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        try consume(0x22)
        var result: [UInt8] = []
        while let byte = current {
            index += 1
            if byte == 0x22 {
                guard let value = String(bytes: result, encoding: .utf8) else {
                    throw error("String is not valid UTF-8")
                }
                return value
            }
            if byte != 0x5C {
                guard byte >= 0x20 else { throw error("Unescaped control byte in string") }
                result.append(byte)
                continue
            }
            guard let escape = current else { throw error("Incomplete string escape") }
            index += 1
            switch escape {
            case 0x22, 0x5C, 0x2F: result.append(escape)
            case 0x62: result.append(0x08)
            case 0x66: result.append(0x0C)
            case 0x6E: result.append(0x0A)
            case 0x72: result.append(0x0D)
            case 0x74: result.append(0x09)
            case 0x75:
                let first = try parseHexQuad()
                let scalar: UInt32
                if (0xD800...0xDBFF).contains(first) {
                    try consume(0x5C)
                    try consume(0x75)
                    let second = try parseHexQuad()
                    guard (0xDC00...0xDFFF).contains(second) else {
                        throw error("Invalid Unicode surrogate pair")
                    }
                    scalar = 0x10000 + ((first - 0xD800) << 10) + second - 0xDC00
                } else {
                    guard !(0xDC00...0xDFFF).contains(first) else {
                        throw error("Unexpected low Unicode surrogate")
                    }
                    scalar = first
                }
                guard let unicode = UnicodeScalar(scalar) else {
                    throw error("Invalid Unicode scalar")
                }
                result.append(contentsOf: String(unicode).utf8)
            default: throw error("Invalid string escape")
            }
        }
        throw error("Unterminated string")
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current else { throw error("Incomplete Unicode escape") }
            index += 1
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
            default: throw error("Invalid Unicode escape")
            }
            result = result * 16 + digit
        }
        return result
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        _ = take(0x2D)
        guard let first = current else { throw error("Incomplete number") }
        if first == 0x30 {
            index += 1
            if let next = current, (0x30...0x39).contains(next) {
                throw error("Leading zero in number")
            }
        } else {
            guard (0x31...0x39).contains(first) else { throw error("Invalid number") }
            index += 1
            while let byte = current, (0x30...0x39).contains(byte) { index += 1 }
        }
        if take(0x2E) {
            guard let byte = current, (0x30...0x39).contains(byte) else {
                throw error("Missing fractional digits")
            }
            while let byte = current, (0x30...0x39).contains(byte) { index += 1 }
        }
        if let byte = current, byte == 0x65 || byte == 0x45 {
            index += 1
            if let sign = current, sign == 0x2B || sign == 0x2D { index += 1 }
            guard let digit = current, (0x30...0x39).contains(digit) else {
                throw error("Missing exponent digits")
            }
            while let digit = current, (0x30...0x39).contains(digit) { index += 1 }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for byte in literal.utf8 { try consume(byte) }
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard current == expected else { throw error("Expected byte \(expected)") }
        index += 1
    }

    private mutating func take(_ expected: UInt8) -> Bool {
        guard current == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) { index += 1 }
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }
    private func error(_ message: String) -> ConfigurationError {
        ConfigurationError(description: "\(message) at byte \(index)")
    }
}

private func object(
    _ value: JSONValue, path: String, keys: Set<String>
) throws -> [String: JSONValue] {
    guard case let .object(document) = value else {
        throw ConfigurationError(description: "\(path) must be an object")
    }
    let present = Set(document.keys)
    let missing = keys.subtracting(present).sorted()
    let unknown = present.subtracting(keys).sorted()
    guard missing.isEmpty else {
        throw ConfigurationError(description: "\(path) missing keys: \(missing)")
    }
    guard unknown.isEmpty else {
        throw ConfigurationError(description: "\(path) has unknown keys: \(unknown)")
    }
    return document
}

private func string(
    _ value: JSONValue, path: String, allowEmpty: Bool = false
) throws -> String {
    guard case let .string(result) = value else {
        throw ConfigurationError(description: "\(path) must be a string")
    }
    guard allowEmpty || !result.isEmpty else {
        throw ConfigurationError(description: "\(path) must not be empty")
    }
    return result
}

private func array(
    _ value: JSONValue, path: String, allowEmpty: Bool = false
) throws -> [JSONValue] {
    guard case let .array(result) = value else {
        throw ConfigurationError(description: "\(path) must be an array")
    }
    guard allowEmpty || !result.isEmpty else {
        throw ConfigurationError(description: "\(path) must not be empty")
    }
    return result
}

private func boolean(_ value: JSONValue, path: String) throws -> Bool {
    guard case let .boolean(result) = value else {
        throw ConfigurationError(description: "\(path) must be a boolean")
    }
    return result
}

private func integer(_ value: JSONValue, path: String) throws -> Int {
    guard case let .number(text) = value, let result = Int(text) else {
        throw ConfigurationError(description: "\(path) must be an integer")
    }
    return result
}

private func validateSemanticVersion(_ version: String) throws {
    let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#
    guard version.range(of: pattern, options: .regularExpression) != nil else {
        throw ConfigurationError(description: "Invalid semantic version")
    }
    let withoutBuild = version.split(separator: "+", maxSplits: 1)[0]
    guard let separator = withoutBuild.firstIndex(of: "-") else { return }
    let prerelease = withoutBuild[withoutBuild.index(after: separator)...]
    for identifier in prerelease.split(separator: ".") {
        if identifier.count > 1, identifier.allSatisfy(\.isNumber), identifier.first == "0" {
            throw ConfigurationError(description: "Invalid semantic version prerelease")
        }
    }
}

private struct ConfiguredTarget {
    let name: String
    let kind: String
    let path: String
    let root: Bool
    let dependencies: [String]
}

private struct ProductConfiguration {
    let minimumMacOS: String
    let swiftLanguageMode: String
    let developmentLocalization: String
    let swiftPMProduct: String
    let screenSaverTargets: [ConfiguredTarget]

    init(value: JSONValue) throws {
        let document = try object(value, path: "root", keys: [
            "schema_version", "version", "build", "target", "localizations",
            "development_localization", "application", "screen_saver", "cef_helpers",
            "screen_saver_targets",
        ])
        guard try integer(document["schema_version"]!, path: "schema_version") == 1 else {
            throw ConfigurationError(description: "Unsupported schema version")
        }
        try validateSemanticVersion(try string(document["version"]!, path: "version"))
        let build = try string(document["build"]!, path: "build")
        guard build.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil else {
            throw ConfigurationError(description: "Invalid build number")
        }

        let target = try object(document["target"]!, path: "target", keys: [
            "architecture", "minimum_macos", "swift_language_mode",
        ])
        guard try string(target["architecture"]!, path: "target.architecture") == "arm64" else {
            throw ConfigurationError(description: "Unsupported architecture")
        }
        minimumMacOS = try string(target["minimum_macos"]!, path: "target.minimum_macos")
        guard minimumMacOS == "14.0" else {
            throw ConfigurationError(description: "Unsupported minimum macOS")
        }
        swiftLanguageMode = try string(
            target["swift_language_mode"]!, path: "target.swift_language_mode")
        guard swiftLanguageMode == "5" else {
            throw ConfigurationError(description: "Unsupported Swift language mode")
        }

        let localizationValues = try array(document["localizations"]!, path: "localizations")
        let localizations = try localizationValues.enumerated().map {
            try string($0.element, path: "localizations[\($0.offset)]")
        }
        guard localizations.count == Set(localizations).count else {
            throw ConfigurationError(description: "Duplicate localization")
        }
        developmentLocalization = try string(
            document["development_localization"]!, path: "development_localization")
        guard localizations.contains(developmentLocalization) else {
            throw ConfigurationError(description: "Development localization is not configured")
        }

        let applicationKeys: Set<String> = [
            "bundle_identifier", "display_name", "bundle_name", "executable", "swiftpm_product",
        ]
        let application = try object(
            document["application"]!, path: "application", keys: applicationKeys)
        for key in applicationKeys {
            _ = try string(application[key]!, path: "application.\(key)")
        }
        swiftPMProduct = try string(
            application["swiftpm_product"]!, path: "application.swiftpm_product")
        let executable = try string(
            application["executable"]!, path: "application.executable")
        guard swiftPMProduct == executable else {
            throw ConfigurationError(description: "SwiftPM product must equal executable")
        }

        let screenSaverKeys: Set<String> = [
            "bundle_identifier", "display_name", "bundle_name", "executable", "principal_class",
        ]
        let screenSaver = try object(
            document["screen_saver"]!, path: "screen_saver", keys: screenSaverKeys)
        for key in screenSaverKeys {
            _ = try string(screenSaver[key]!, path: "screen_saver.\(key)")
        }

        let suffixes = [
            "main": "", "gpu": " (GPU)", "renderer": " (Renderer)",
            "alerts": " (Alerts)", "plugin": " (Plugin)",
        ]
        var roles = Set<String>()
        var identifiers = Set<String>()
        for (index, value) in try array(document["cef_helpers"]!, path: "cef_helpers").enumerated() {
            let path = "cef_helpers[\(index)]"
            let helper = try object(value, path: path, keys: [
                "role", "suffix", "bundle_identifier",
            ])
            let role = try string(helper["role"]!, path: "\(path).role")
            let suffix = try string(helper["suffix"]!, path: "\(path).suffix", allowEmpty: true)
            let identifier = try string(
                helper["bundle_identifier"]!, path: "\(path).bundle_identifier")
            guard roles.insert(role).inserted, identifiers.insert(identifier).inserted else {
                throw ConfigurationError(description: "Duplicate CEF helper")
            }
            guard suffixes[role] == suffix else {
                throw ConfigurationError(description: "Invalid suffix for CEF helper \(role)")
            }
        }
        guard roles == Set(suffixes.keys) else {
            throw ConfigurationError(description: "CEF helper roles do not match schema")
        }

        var targets: [ConfiguredTarget] = []
        for (index, value) in try array(
            document["screen_saver_targets"]!, path: "screen_saver_targets").enumerated() {
            let path = "screen_saver_targets[\(index)]"
            let item = try object(value, path: path, keys: [
                "name", "kind", "path", "root", "dependencies",
            ])
            let dependencies = try array(
                item["dependencies"]!, path: "\(path).dependencies", allowEmpty: true
            ).enumerated().map {
                try string($0.element, path: "\(path).dependencies[\($0.offset)]")
            }
            guard dependencies.count == Set(dependencies).count else {
                throw ConfigurationError(description: "Duplicate configured dependency")
            }
            let configured = ConfiguredTarget(
                name: try string(item["name"]!, path: "\(path).name"),
                kind: try string(item["kind"]!, path: "\(path).kind"),
                path: try string(item["path"]!, path: "\(path).path"),
                root: try boolean(item["root"]!, path: "\(path).root"),
                dependencies: dependencies
            )
            guard configured.kind == "target" else {
                throw ConfigurationError(description: "Unsupported configured target kind")
            }
            targets.append(configured)
        }
        try Self.validateGraph(targets)
        screenSaverTargets = targets
    }

    private static func validateGraph(_ targets: [ConfiguredTarget]) throws {
        let names = targets.map(\.name)
        let paths = targets.map(\.path)
        guard names.count == Set(names).count, paths.count == Set(paths).count else {
            throw ConfigurationError(description: "Duplicate configured target name or path")
        }
        let roots = targets.filter(\.root)
        guard roots.count == 1, roots[0].name == "WallpaperScreenSaver" else {
            throw ConfigurationError(description: "Root target must be WallpaperScreenSaver")
        }
        let byName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })
        for target in targets {
            for dependency in target.dependencies {
                guard dependency != target.name else {
                    throw ConfigurationError(description: "Self dependency in \(target.name)")
                }
                guard byName[dependency] != nil else {
                    throw ConfigurationError(description: "Unknown dependency \(dependency)")
                }
            }
        }
        var reachable = Set<String>()
        var pending = [roots[0].name]
        while let name = pending.popLast() {
            guard reachable.insert(name).inserted else { continue }
            pending.append(contentsOf: byName[name]!.dependencies)
        }
        guard reachable == Set(names) else {
            throw ConfigurationError(description: "Targets exist outside the root closure")
        }
        var visiting = Set<String>()
        var visited = Set<String>()
        func visit(_ name: String) throws {
            if visiting.contains(name) {
                throw ConfigurationError(description: "Configured target dependency cycle")
            }
            guard !visited.contains(name) else { return }
            visiting.insert(name)
            for dependency in byName[name]!.dependencies { try visit(dependency) }
            visiting.remove(name)
            visited.insert(name)
        }
        for name in names { try visit(name) }
    }
}

private struct MediaConfiguration {
    let cefVersion: String
    let mpvDirectory: String

    init(value: JSONValue) throws {
        let document = try object(value, path: "media root", keys: [
            "schema_version", "verification_scope", "modules",
        ])
        guard try integer(document["schema_version"]!, path: "media.schema_version") == 1 else {
            throw ConfigurationError(description: "Unsupported media schema version")
        }
        _ = try string(document["verification_scope"]!, path: "media.verification_scope")
        let modules = try object(document["modules"]!, path: "media.modules", keys: [
            "cef", "mpv", "ffmpeg",
        ])
        let cef = try Self.validateModule(
            modules["cef"]!, path: "media.modules.cef", extras: [])
        let mpv = try Self.validateModule(
            modules["mpv"]!, path: "media.modules.mpv", extras: ["source_build"])
        _ = try Self.validateModule(
            modules["ffmpeg"]!, path: "media.modules.ffmpeg", extras: [])
        cefVersion = try string(cef["version"]!, path: "media.modules.cef.version")
        let build = try object(mpv["source_build"]!, path: "media.modules.mpv.source_build",
                               keys: ["path", "sha256", "output"])
        for key in ["path", "sha256", "output"] {
            _ = try string(build[key]!, path: "media.modules.mpv.source_build.\(key)")
        }
        mpvDirectory = try string(build["output"]!, path: "media.modules.mpv.source_build.output")
        guard mpvDirectory == ".build/media-source-complete/mpv" else {
            throw ConfigurationError(description: "Invalid controlled MPV source-build output")
        }
    }

    private static func validateModule(
        _ value: JSONValue, path: String, extras: Set<String>
    ) throws -> [String: JSONValue] {
        let common: Set<String> = [
            "version", "architecture", "minimum_macos", "source", "license_status", "artifacts",
        ]
        let module = try object(value, path: path, keys: common.union(extras))
        for key in ["version", "architecture", "minimum_macos", "source", "license_status"] {
            _ = try string(module[key]!, path: "\(path).\(key)")
        }
        let artifacts = try array(module["artifacts"]!, path: "\(path).artifacts",
                                  allowEmpty: module["source_build"] != nil)
        if module["source_build"] != nil && !artifacts.isEmpty {
            throw ConfigurationError(description: "Controlled MPV source build cannot contain binary artifacts")
        }
        for (index, value) in artifacts.enumerated() {
            let artifactPath = "\(path).artifacts[\(index)]"
            guard case let .object(raw) = value else {
                throw ConfigurationError(description: "\(artifactPath) must be an object")
            }
            let keys: Set<String> = raw["size"] == nil
                ? ["path", "url", "sha256"] : ["path", "url", "sha256", "size"]
            let artifact = try object(value, path: artifactPath, keys: keys)
            for key in ["path", "url", "sha256"] {
                _ = try string(artifact[key]!, path: "\(artifactPath).\(key)")
            }
            if let size = artifact["size"], try integer(size, path: "\(artifactPath).size") <= 0 {
                throw ConfigurationError(description: "\(artifactPath).size must be positive")
            }
        }
        if let value = module["manifest"] {
            let manifest = try object(value, path: "\(path).manifest", keys: [
                "path", "sha256", "cache_prefix",
            ])
            for key in ["path", "sha256", "cache_prefix"] {
                _ = try string(manifest[key]!, path: "\(path).manifest.\(key)")
            }
        }
        return module
    }
}

private func parseStrictJSON(at url: URL, label: String) -> JSONValue {
    do {
        var parser = StrictJSONParser(data: try Data(contentsOf: url))
        return try parser.parse()
    } catch {
        fatalError("Invalid \(label): \(error)")
    }
}

let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let productURL = URL(fileURLWithPath: projectRoot).appendingPathComponent(
    "scripts/product-configuration.json")
let mediaURL = URL(fileURLWithPath: projectRoot).appendingPathComponent(
    "scripts/media-dependencies.json")
private let configuration: ProductConfiguration = {
    do {
        return try ProductConfiguration(value: parseStrictJSON(
            at: productURL, label: "scripts/product-configuration.json"))
    } catch {
        fatalError("Invalid scripts/product-configuration.json: \(error)")
    }
}()
private let mediaConfiguration: MediaConfiguration = {
    do {
        return try MediaConfiguration(value: parseStrictJSON(
            at: mediaURL, label: "scripts/media-dependencies.json"))
    } catch {
        fatalError("Invalid scripts/media-dependencies.json: \(error)")
    }
}()
let mpvRoot = projectRoot + "/" + mediaConfiguration.mpvDirectory
let cefRoot = projectRoot + "/.build/dependencies/cef/cef_binary_\(mediaConfiguration.cefVersion)_macosarm64_minimal"
let cefWrapper = projectRoot + "/.build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a"

let configuredNames = Set(configuration.screenSaverTargets.map(\.name))
let explicitNames: Set<String> = [
    "MPVBridge", "WebWallpaperBridge", "WallpaperApp", "ScreenSaverLeaseHarness",
    "WallpaperAudioSpectrum", "WallpaperAudioSpectrumTests",
    "WallpaperMediaIntegration", "WallpaperMediaIntegrationTests",
    "WallpaperCoreTests", "ScreenSaverCoreTests", "ScreenSaverRuntimeTests",
    "WallpaperScreenSaverTests", "WallpaperAppTests", "WallpaperEditorCore", "WallpaperEditorCoreTests",
]
let collisions = configuredNames.intersection(explicitNames)
guard collisions.isEmpty else {
    fatalError("Configured targets collide with explicit targets: \(collisions.sorted())")
}

let screenSaverTargets: [Target] = configuration.screenSaverTargets.map { target in
    .target(name: target.name,
            dependencies: target.dependencies.map { .byName(name: $0) },
            path: target.path)
}

let explicitTargets: [Target] = [
        .target(name: "WallpaperMediaIntegration", dependencies: ["WallpaperCore"]),
        .testTarget(name: "WallpaperMediaIntegrationTests", dependencies: ["WallpaperMediaIntegration", "WallpaperCore"]),
        .target(name: "WallpaperAudioSpectrum", dependencies: ["WallpaperCore"]),
        .testTarget(name: "WallpaperAudioSpectrumTests", dependencies: ["WallpaperAudioSpectrum"]),
        .target(name: "WallpaperEditorCore", dependencies: ["WallpaperCore"]),
        .testTarget(name: "WallpaperEditorCoreTests", dependencies: ["WallpaperEditorCore", "WallpaperCore"]),
        .target(name: "MPVBridge", publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-I", mpvRoot + "/include", "-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Foundation"),
                    .unsafeFlags([mpvRoot + "/runtime-lib/libmpv.2.dylib", "-Xlinker", "-rpath",
                                  "-Xlinker", mpvRoot + "/runtime-lib"])]),
        .target(name: "WebWallpaperBridge", sources: ["WebRuntime.mm", "WebPage.mm", "WebClient.cpp", "WebAudioOutput.mm",
                "LocalProjectFiles.cpp", "LocalWebRequestContext.cpp", "SceneProtocol.mm"], publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-std=c++20", "-isystem", cefRoot, "-fobjc-arc", "-frtti", "-Wall", "-Wextra", "-Werror"])],
                linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("QuartzCore"),
                    .linkedFramework("AVFoundation"), .linkedFramework("CoreAudio"),
                    .unsafeFlags([cefWrapper])]),
        .executableTarget(name: "WallpaperApp", dependencies: ["WallpaperAudioSpectrum", "WallpaperMediaIntegration", "WallpaperCore", "WallpaperNative", "ScreenSaverCore", "ScreenSaverRuntime", "MPVBridge", "WebWallpaperBridge"],
                          resources: [.process("Resources/en.lproj"), .process("Resources/zh-Hans.lproj"),
                                      .process("Resources/es.lproj"), .process("Resources/ja.lproj"),
                                      .process("Resources/fr.lproj"), .copy("Resources/SceneRuntime"), .copy("Help")]),
        .executableTarget(name: "ScreenSaverLeaseHarness", dependencies: ["ScreenSaverCore", "WallpaperCore"],
                          path: "Tests/ScreenSaverLeaseHarness"),
        .testTarget(name: "WallpaperCoreTests", dependencies: ["WallpaperCore"]),
        .testTarget(name: "ScreenSaverCoreTests", dependencies: ["ScreenSaverCore", "WallpaperCore"]),
        .testTarget(name: "ScreenSaverRuntimeTests", dependencies: ["ScreenSaverRuntime", "ScreenSaverCore", "WallpaperCore", "WallpaperNative"]),
        .testTarget(name: "WallpaperScreenSaverTests", dependencies: ["WallpaperScreenSaver", "ScreenSaverCore"]),
        .testTarget(name: "WallpaperAppTests", dependencies: ["WallpaperAudioSpectrum", "WallpaperMediaIntegration", "WallpaperApp", "WallpaperCore", "WallpaperNative", "ScreenSaverCore"])
]

let products: [Product] = [
    .library(name: "WallpaperMediaIntegration", targets: ["WallpaperMediaIntegration"]),
    .library(name: "WallpaperAudioSpectrum", targets: ["WallpaperAudioSpectrum"]),
    .library(name: "WallpaperCore", targets: ["WallpaperCore"]),
    .library(name: "WallpaperEditorCore", targets: ["WallpaperEditorCore"]),
    .library(name: "WebWallpaperBridge", targets: ["WebWallpaperBridge"]),
    .executable(name: configuration.swiftPMProduct, targets: ["WallpaperApp"]),
    .executable(name: "ScreenSaverLeaseHarness", targets: ["ScreenSaverLeaseHarness"]),
]

let package = Package(
    name: configuration.swiftPMProduct,
    defaultLocalization: LanguageTag(rawValue: configuration.developmentLocalization),
    platforms: [.macOS(configuration.minimumMacOS)],
    products: products,
    targets: screenSaverTargets + explicitTargets,
    swiftLanguageModes: [.v5]
)
