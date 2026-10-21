import Foundation
import Darwin
import OSLog

enum ProbeAccessError: LocalizedError {
    case authorizationRequired, staleBookmark, accessDenied, notDirectory, defaultsUnavailable, saveFailed, closed
    var errorDescription: String? {
        switch self {
        case .authorizationRequired: return "尚未授权测试目录，请打开屏保选项选择目录。"
        case .staleBookmark: return "目录书签已失效，请在屏保选项中重新授权。"
        case .accessDenied: return "宿主无法取得目录的 security-scoped access；没有改读其他路径。"
        case .notDirectory: return "所选位置不是本地目录。"
        case .defaultsUnavailable: return "屏保配置域不可用。"
        case .saveFailed: return "无法持久保存目录书签。"
        case .closed: return "配置宿主已关闭。"
        }
    }
}

final class ProbeDirectoryAccess {
    let url: URL
    private var active = true
    private var lease: FileHandle?
    init(url: URL) { self.url = url }
    func acquireReadLease() throws {
        let path = url.appendingPathComponent(".lease").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        lease = handle
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL),
                          userInfo: [NSLocalizedDescriptionKey: "Lease is not a regular file: \(path)"])
        }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    func close() throws {
        guard active else { return }
        try lease?.close()
        lease = nil
        active = false
        url.stopAccessingSecurityScopedResource()
    }
    deinit {
        do { try close() }
        catch {
            Logger(subsystem: "local.dynamicwallpaper.screensaver.probe", category: "release")
                .error("Directory access release failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

final class ProbeAccess {
    private let defaults: UserDefaults
    private let bookmarkKey = "directoryBookmark"
    init(defaults: UserDefaults) { self.defaults = defaults }

    func authorize(_ directory: URL) throws {
        guard directory.isFileURL else { throw ProbeAccessError.notDirectory }
        let data = try directory.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        let access = try resolve(data)
        try access.close()
        defaults.set(data, forKey: bookmarkKey)
        guard defaults.synchronize() else { throw ProbeAccessError.saveFailed }
    }

    func acquire() throws -> ProbeDirectoryAccess {
        guard let data = defaults.data(forKey: bookmarkKey) else { throw ProbeAccessError.authorizationRequired }
        return try resolve(data)
    }

    private func resolve(_ data: Data) throws -> ProbeDirectoryAccess {
        var stale = false
        let directory = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw ProbeAccessError.staleBookmark }
        guard directory.startAccessingSecurityScopedResource() else { throw ProbeAccessError.accessDenied }
        let access = ProbeDirectoryAccess(url: directory)
        do {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw ProbeAccessError.notDirectory
            }
            try access.acquireReadLease()
            return access
        } catch {
            do { try access.close() }
            catch let cleanup {
                throw NSError(domain: "ScreenSaverProbeAccess", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(error.localizedDescription); release: \(cleanup.localizedDescription)"
                ])
            }
            throw error
        }
    }
}
