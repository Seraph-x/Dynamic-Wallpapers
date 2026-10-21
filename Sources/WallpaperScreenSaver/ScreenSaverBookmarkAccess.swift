import Darwin
import Foundation
import OSLog
import ScreenSaverCore
import ScreenSaverRuntime

private func bookmarkText(_ key: String) -> String {
    NSLocalizedString(key, bundle: Bundle(for: ScreenSaverBookmarkStore.self), comment: "")
}

public enum ScreenSaverBookmarkError: LocalizedError, Equatable, Sendable {
    case authorizationRequired, corruptBookmark, staleBookmark, accessDenied
    case notDirectory, identityChanged, invalidExport, saveFailed, defaultsUnavailable, closed

    public var errorDescription: String? {
        switch self {
        case .authorizationRequired: return bookmarkText("failure.authorizationRequired")
        case .corruptBookmark: return bookmarkText("failure.corruptBookmark")
        case .staleBookmark: return bookmarkText("failure.staleBookmark")
        case .accessDenied: return bookmarkText("failure.accessDenied")
        case .notDirectory: return bookmarkText("failure.notDirectory")
        case .identityChanged: return bookmarkText("failure.identityChanged")
        case .invalidExport: return bookmarkText("failure.invalidExport")
        case .saveFailed: return bookmarkText("failure.saveFailed")
        case .defaultsUnavailable: return bookmarkText("failure.defaultsUnavailable")
        case .closed: return bookmarkText("failure.closed")
        }
    }

    var failure: ScreenSaverFailure {
        switch self {
        case .authorizationRequired, .accessDenied:
            return ScreenSaverFailure(code: .authorizationRequired)
        case .corruptBookmark, .staleBookmark, .notDirectory, .invalidExport:
            return ScreenSaverFailure(code: .bookmarkInvalid)
        case .identityChanged:
            return ScreenSaverFailure(code: .identityChanged)
        case .saveFailed, .defaultsUnavailable:
            return ScreenSaverFailure(code: .settingsUnavailable)
        case .closed:
            return ScreenSaverFailure(code: .applicationClosing(.shutdown))
        }
    }
}

func screenSaverHostFailure(capturing error: Error,
                            phase: ScreenSaverFailure.Phase? = nil) -> ScreenSaverFailure {
    if let bookmark = error as? ScreenSaverBookmarkError { return bookmark.failure }
    return ScreenSaverFailure(capturing: error, phase: phase)
}

struct BookmarkResolution {
    let url: URL
    let isStale: Bool
}

struct ScreenSaverBookmarkRecord: Codable, Equatable {
    let schemaVersion: Int
    let exportID: UUID
    let bookmark: Data

    init(exportID: UUID, bookmark: Data) {
        schemaVersion = 1; self.exportID = exportID; self.bookmark = bookmark
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, exportID, bookmark }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        exportID = try values.decode(UUID.self, forKey: .exportID)
        bookmark = try values.decode(Data.self, forKey: .bookmark)
        guard schemaVersion == 1, !bookmark.isEmpty else { throw ScreenSaverBookmarkError.corruptBookmark }
    }
}

@MainActor
final class ScreenSaverBookmarkAccess: ScreenSaverDirectoryAccess {
    let root: URL
    let expectedExportID: UUID?
    private var active: Bool
    private let stopAccess: @Sendable (URL) -> Void

    init(root: URL, exportID: UUID, active: Bool = true,
         stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.root = root; expectedExportID = exportID; self.active = active; self.stopAccess = stopAccess
    }

    func close() throws {
        guard active else { return }
        active = false
        stopAccess(root)
    }

    deinit {
        if active { stopAccess(root) }
    }
}

@MainActor
final class ScreenSaverBookmarkStore {
    static let defaultsKey = "exportDirectoryBookmark"
    private static let logger = Logger(subsystem: "local.dynamicwallpaper.screensaver", category: "bookmark")
    typealias Resolver = @MainActor (Data) throws -> BookmarkResolution
    typealias AccessStarter = @MainActor (URL) -> Bool

    private let defaults: UserDefaults?
    private let resolve: Resolver
    private let startAccess: AccessStarter
    private let stopAccess: @Sendable (URL) -> Void

    init(defaults: UserDefaults?,
         resolve: @escaping Resolver = { data in
             var stale = false
             let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
             return BookmarkResolution(url: url, isStale: stale)
         }, startAccess: @escaping AccessStarter = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.defaults = defaults; self.resolve = resolve; self.startAccess = startAccess; self.stopAccess = stopAccess
    }

    func authorize(_ directory: URL) throws {
        guard let defaults else { throw ScreenSaverBookmarkError.defaultsUnavailable }
        guard directory.isFileURL else { throw ScreenSaverBookmarkError.notDirectory }
        let bookmark = try directory.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                  includingResourceValuesForKeys: nil, relativeTo: nil)
        let resolution = try resolveBookmark(bookmark)
        guard startAccess(resolution.url) else { throw ScreenSaverBookmarkError.accessDenied }
        defer { stopAccess(resolution.url) }
        guard try resolution.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ScreenSaverBookmarkError.notDirectory
        }
        let exportID: UUID
        do { exportID = try identity(at: resolution.url).id }
        catch {
            Self.logger.error("Invalid export identity at \(resolution.url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            throw ScreenSaverBookmarkError.invalidExport
        }
        defaults.set(try JSONEncoder().encode(ScreenSaverBookmarkRecord(exportID: exportID, bookmark: bookmark)),
                     forKey: Self.defaultsKey)
        guard defaults.synchronize() else { throw ScreenSaverBookmarkError.saveFailed }
    }

    func acquire() throws -> ScreenSaverBookmarkAccess {
        guard let defaults else { throw ScreenSaverBookmarkError.defaultsUnavailable }
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            throw ScreenSaverBookmarkError.authorizationRequired
        }
        let record: ScreenSaverBookmarkRecord
        do { record = try JSONDecoder().decode(ScreenSaverBookmarkRecord.self, from: data) }
        catch is ScreenSaverBookmarkError { throw ScreenSaverBookmarkError.corruptBookmark }
        catch { throw ScreenSaverBookmarkError.corruptBookmark }
        return try open(record)
    }

    private func open(_ record: ScreenSaverBookmarkRecord) throws -> ScreenSaverBookmarkAccess {
        let resolution = try resolveBookmark(record.bookmark)
        guard startAccess(resolution.url) else { throw ScreenSaverBookmarkError.accessDenied }
        let access = ScreenSaverBookmarkAccess(root: resolution.url, exportID: record.exportID, stopAccess: stopAccess)
        do {
            guard try resolution.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw ScreenSaverBookmarkError.notDirectory
            }
            guard try identity(at: resolution.url).id == record.exportID else {
                throw ScreenSaverBookmarkError.identityChanged
            }
            return access
        } catch {
            try? access.close()
            throw error
        }
    }

    private func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolution {
        let resolution: BookmarkResolution
        do { resolution = try resolve(bookmark) }
        catch { throw ScreenSaverBookmarkError.corruptBookmark }
        guard !resolution.isStale else { throw ScreenSaverBookmarkError.staleBookmark }
        guard resolution.url.isFileURL else { throw ScreenSaverBookmarkError.notDirectory }
        return resolution
    }

    private func identity(at root: URL) throws -> ScreenSaverExportIdentity {
        try ScreenSaverExportIdentityReader.read(at: root)
    }
}

private enum ScreenSaverExportIdentityReader {
    static func read(at root: URL) throws -> ScreenSaverExportIdentity {
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ScreenSaverBookmarkError.notDirectory }
        let directoryHandle = FileHandle(fileDescriptor: directory, closeOnDealloc: true)
        defer { try? directoryHandle.close() }
        let descriptor = openat(directory, "export.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw ScreenSaverBookmarkError.identityChanged
        }
        return try JSONDecoder().decode(ScreenSaverExportIdentity.self, from: handle.readToEnd() ?? Data())
    }
}
