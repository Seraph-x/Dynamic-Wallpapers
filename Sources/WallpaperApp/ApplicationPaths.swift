import Foundation
import Darwin

struct ApplicationPaths: Sendable {
    struct Record: Codable, Equatable {
        let event: String
        let bundleIdentifier: String
        let preferencesDomain: String
        let fixedUserHome: String
        let temporaryRoot: String
        let paths: [String: String]
    }

    enum PathError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self { case .invalid(let detail): "Invalid application path configuration: \(detail)" }
        }
    }

    let bundleIdentifier: String
    let applicationSupport: URL
    let library: URL
    let legacyLibrary: URL
    let screenSaverExport: URL
    let media: URL
    let systemWallpapers: URL
    let cefCache: URL
    let transcodeTemporary: URL
    let transcodeDiagnostics: URL
    let preferences: URL
    let logs: URL
    let fixedUserHome: URL
    let temporaryRoot: URL
    let validationRoot: URL?
    let evidence: URL?
    let printValidationPaths: Bool

    var writablePaths: [String: URL] {
        var result = [
            "applicationSupport": applicationSupport, "library": library,
            "legacyLibrary": legacyLibrary, "screenSaverExport": screenSaverExport,
            "media": media, "systemWallpapers": systemWallpapers, "cefCache": cefCache,
            "transcodeTemporary": transcodeTemporary, "transcodeDiagnostics": transcodeDiagnostics,
            "preferences": preferences, "logs": logs
        ]
        if let evidence { result["evidence"] = evidence }
        return result
    }

    static func production(bundleIdentifier: String) -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicWallpaper", isDirectory: true)
        return Self(bundleIdentifier: bundleIdentifier, applicationSupport: support,
            library: support.appendingPathComponent("library-extended.json"),
            legacyLibrary: support.appendingPathComponent("library.json"),
            screenSaverExport: support.appendingPathComponent("ScreenSaverExport", isDirectory: true),
            media: support.appendingPathComponent("Media", isDirectory: true),
            systemWallpapers: support.appendingPathComponent("SystemWallpapers", isDirectory: true),
            cefCache: temporary.appendingPathComponent("DynamicWallpaper-CEF/\(UUID().uuidString)", isDirectory: true),
            transcodeTemporary: temporary.appendingPathComponent("DynamicWallpaper-Transcode", isDirectory: true),
            transcodeDiagnostics: temporary.appendingPathComponent("DynamicWallpaper-Transcode-Diagnostics", isDirectory: true),
            preferences: home.appendingPathComponent("Library/Preferences", isDirectory: true),
            logs: support.appendingPathComponent("Logs", isDirectory: true), fixedUserHome: home,
            temporaryRoot: temporary, validationRoot: nil, evidence: nil, printValidationPaths: false)
    }

    static func resolve(arguments: [String], bundleIdentifier: String,
                        configuredBundleIdentifier: String,
                        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let validation = isValidationIdentifier(bundleIdentifier, configured: configuredBundleIdentifier)
        guard validation || bundleIdentifier == configuredBundleIdentifier else {
            throw PathError.invalid("unexpected bundle identifier \(bundleIdentifier)")
        }
        var rootArgument: String?
        var evidenceArgument: String?
        var printPaths = false
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--validation-data-root", "--validation-evidence":
                guard validation, index + 1 < arguments.count else { throw PathError.invalid(flag) }
                index += 1
                if flag == "--validation-data-root" {
                    guard rootArgument == nil else { throw PathError.invalid("duplicate root") }
                    rootArgument = arguments[index]
                } else {
                    guard evidenceArgument == nil else { throw PathError.invalid("duplicate evidence") }
                    evidenceArgument = arguments[index]
                }
            case "--print-validation-paths":
                guard validation, !printPaths else { throw PathError.invalid(flag) }
                printPaths = true
            default:
                if flag.hasPrefix("--validation-") { throw PathError.invalid(flag) }
            }
            index += 1
        }
        let home: URL
        let temporary: URL
        let root: URL?
        if validation {
            guard let rootArgument, let fixedHome = environment["CFFIXED_USER_HOME"],
                  let temp = environment["TMPDIR"] else {
                throw PathError.invalid("validation root, CFFIXED_USER_HOME and TMPDIR are required")
            }
            let presentedRoot = try checkedAbsolute(rootArgument)
            try requireDirectory(presentedRoot)
            let candidate = try canonicalExisting(presentedRoot)
            root = candidate
            home = try checkedChild(fixedHome, root: candidate, presentedRoot: presentedRoot)
            temporary = try checkedChild(temp, root: candidate, presentedRoot: presentedRoot)
            try requireDirectory(home)
            try requireDirectory(temporary)
        } else {
            return production(bundleIdentifier: bundleIdentifier)
        }
        let support = (validation ? home.appendingPathComponent("Library/Application Support") :
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("DynamicWallpaper", isDirectory: true)
        let preferenceDirectory = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        let evidence = try evidenceArgument.map {
            try checkedChild($0, root: root!, presentedRoot: try checkedAbsolute(rootArgument!))
        }
        let paths = Self(bundleIdentifier: bundleIdentifier,
            applicationSupport: support, library: support.appendingPathComponent("library-extended.json"),
            legacyLibrary: support.appendingPathComponent("library.json"),
            screenSaverExport: support.appendingPathComponent("ScreenSaverExport", isDirectory: true),
            media: support.appendingPathComponent("Media", isDirectory: true),
            systemWallpapers: support.appendingPathComponent("SystemWallpapers", isDirectory: true),
            cefCache: temporary.appendingPathComponent("DynamicWallpaper-CEF/\(validation ? bundleIdentifier : UUID().uuidString)", isDirectory: true),
            transcodeTemporary: temporary.appendingPathComponent("DynamicWallpaper-Transcode", isDirectory: true),
            transcodeDiagnostics: temporary.appendingPathComponent("DynamicWallpaper-Transcode-Diagnostics", isDirectory: true),
            preferences: preferenceDirectory, logs: support.appendingPathComponent("Logs", isDirectory: true),
            fixedUserHome: home, temporaryRoot: temporary, validationRoot: root,
            evidence: evidence, printValidationPaths: printPaths)
        if let root {
            for path in paths.writablePaths.values { _ = try checkedChild(path.path, root: root, presentedRoot: root) }
        }
        return paths
    }

    func preflightRecord() -> Record { record(event: "preflight") }
    func startupRecord() -> Record { record(event: "startup") }
    func record(event: String) -> Record {
        Record(event: event, bundleIdentifier: bundleIdentifier, preferencesDomain: bundleIdentifier,
            fixedUserHome: fixedUserHome.path, temporaryRoot: temporaryRoot.path,
            paths: writablePaths.mapValues(\.path))
    }

    func encodedRecord(event: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record(event: event))
    }

    func appendEvidence(event: String) throws {
        guard let evidence, let validationRoot else { return }
        _ = try Self.checkedChild(evidence.path, root: validationRoot, presentedRoot: validationRoot)
        var line = try encodedRecord(event: event)
        line.append(0x0A)
        let flags = O_WRONLY | O_NOFOLLOW | (event == "startup" ? O_CREAT | O_EXCL : O_APPEND)
        let descriptor = evidence.withUnsafeFileSystemRepresentation { Darwin.open($0!, flags, 0o600) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        try line.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }

    private static func checkedAbsolute(_ raw: String) throws -> URL {
        guard raw.hasPrefix("/"), !raw.split(separator: "/").contains(".."),
              !raw.split(separator: "/").contains(".") else { throw PathError.invalid(raw) }
        return URL(fileURLWithPath: raw).standardizedFileURL
    }

    static func isValidationIdentifier(_ identifier: String, configured: String) -> Bool {
        let prefix = configured + ".validation."
        guard identifier.hasPrefix(prefix) else { return false }
        let suffix = identifier.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }

    private static func checkedChild(_ raw: String, root: URL, presentedRoot: URL) throws -> URL {
        let url = try checkedAbsolute(raw)
        let relative: ArraySlice<String>
        if url.pathComponents.starts(with: presentedRoot.pathComponents) {
            relative = url.pathComponents.dropFirst(presentedRoot.pathComponents.count)
        } else if url.pathComponents.starts(with: root.pathComponents) {
            relative = url.pathComponents.dropFirst(root.pathComponents.count)
        } else {
            throw PathError.invalid("path escapes validation root: \(raw)")
        }
        guard !relative.isEmpty else { throw PathError.invalid("path equals validation root: \(raw)") }
        var canonical = root
        for component in relative {
            canonical.appendPathComponent(component)
            var info = stat()
            if canonical.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else {
                    throw PathError.invalid("symbolic link component: \(canonical.path)")
                }
            } else if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return canonical.standardizedFileURL
    }

    private static func requireDirectory(_ url: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw PathError.invalid("directory does not exist: \(url.path)")
        }
    }

    private static func canonicalExisting(_ url: URL) throws -> URL {
        let pointer = url.withUnsafeFileSystemRepresentation { Darwin.realpath($0!, nil) }
        guard let pointer else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer)).standardizedFileURL
    }
}
