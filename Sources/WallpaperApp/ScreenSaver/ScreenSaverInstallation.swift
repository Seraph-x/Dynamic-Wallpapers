import AppKit
import Foundation
import ScreenSaverCore
import WallpaperCore

struct ScreenSaverInstallationOperations {
    let open: (URL) -> Bool
    let installedBundles: () throws -> [URL]

    static var system: Self {
        Self(open: { NSWorkspace.shared.open($0) }, installedBundles: {
            let user = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Screen Savers", isDirectory: true)
            let system = URL(fileURLWithPath: "/Library/Screen Savers", isDirectory: true)
            return try [user, system].flatMap { directory -> [URL] in
                do {
                    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "saver" }
                } catch let error as NSError where
                    error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                    return []
                }
            }
        })
    }
}

@MainActor
final class ScreenSaverInstallation {
    private static let maximumInfoBytes = 65_536

    enum Status: Equatable {
        case notInstalled(bundledVersion: String)
        case installed(version: String, url: URL)
        case updateAvailable(installedVersion: String, bundledVersion: String, url: URL)
        case ambiguous(urls: [URL])
    }
    private let bundledURL: URL
    private let product: ProductBundleMetadata
    private let operations: ScreenSaverInstallationOperations
    private(set) var status: Status?

    init(bundledURL: URL, product: ProductBundleMetadata,
         operations: ScreenSaverInstallationOperations? = nil) {
        self.bundledURL = bundledURL
        self.product = product
        self.operations = operations ?? .system
    }

    @discardableResult
    func refresh() throws -> Status {
        status = nil
        let bundled = try metadata(at: bundledURL)
        guard bundled.identifier == product.screenSaverBundleIdentifier else {
            throw ScreenSaverFailure(code: .bundleMetadataInvalid(bundledURL.lastPathComponent))
        }
        let matches = try operations.installedBundles().compactMap { url -> (URL, String)? in
            let info = try readInfo(at: url)
            guard info["CFBundleIdentifier"] as? String == product.screenSaverBundleIdentifier else { return nil }
            return (url, try metadata(at: url, info: info).version)
        }
        let result: Status
        switch matches.count {
        case 0: result = .notInstalled(bundledVersion: bundled.version)
        case 1:
            let (url, version) = matches[0]
            result = version.compare(bundled.version, options: .numeric) == .orderedAscending
                ? .updateAvailable(installedVersion: version, bundledVersion: bundled.version, url: url)
                : .installed(version: version, url: url)
        default: result = .ambiguous(urls: matches.map(\.0))
        }
        status = result
        return result
    }

    @discardableResult
    func install() throws -> Status {
        guard try metadata(at: bundledURL).identifier == product.screenSaverBundleIdentifier else {
            throw ScreenSaverFailure(code: .bundleMetadataInvalid(bundledURL.lastPathComponent))
        }
        guard operations.open(bundledURL) else { throw ScreenSaverFailure(code: .installationFailed) }
        return try refresh()
    }

    private func metadata(at url: URL) throws -> (identifier: String, version: String) {
        try metadata(at: url, info: readInfo(at: url))
    }

    private func metadata(at url: URL, info values: [String: Any]) throws -> (identifier: String, version: String) {
        guard let identifier = values["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let version = values["CFBundleShortVersionString"] as? String, !version.isEmpty,
              values["CFBundlePackageType"] as? String == "BNDL",
              let executable = values["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/") else {
            throw ScreenSaverFailure(code: .bundleMetadataInvalid(url.lastPathComponent))
        }
        let binary = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        let attributes = try FileManager.default.attributesOfItem(atPath: binary.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
            throw ScreenSaverFailure(code: .bundleExecutableInvalid(url.lastPathComponent))
        }
        return (identifier, version)
    }

    private func readInfo(at url: URL) throws -> [String: Any] {
        let info = url.appendingPathComponent("Contents/Info.plist")
        let handle = try ScreenSaverFileAccess.openSource(at: info)
        let read = Result { () throws -> Data in
            let maximum = Self.maximumInfoBytes
            var bytes = Data()
            while bytes.count <= maximum {
                let chunk = try handle.read(upToCount: min(4_096, maximum + 1 - bytes.count)) ?? Data()
                if chunk.isEmpty { break }
                bytes.append(chunk)
            }
            guard bytes.count <= maximum else {
                throw ScreenSaverFailure(code: .infoPlistTooLarge(url.lastPathComponent))
            }
            return bytes
        }
        do { try handle.close() }
        catch {
            if case .failure(let original) = read { throw WallpaperErrorGroup([original, error]) }
            throw error
        }
        guard let values = try PropertyListSerialization.propertyList(from: read.get(), format: nil) as? [String: Any] else {
            throw ScreenSaverFailure(code: .infoPlistInvalid(url.lastPathComponent))
        }
        return values
    }
}
