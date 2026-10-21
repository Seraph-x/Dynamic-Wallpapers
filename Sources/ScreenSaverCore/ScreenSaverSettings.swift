import Darwin
import Foundation
import WallpaperCore

public struct ScreenSaverSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let schemaVersion: Int
    public let source: ScreenSaverSource?
    public let isMuted: Bool
    public let fit: ContentFit
    public let consent: ScreenSaverConsent?

    public init(source: ScreenSaverSource? = nil, isMuted: Bool = true, fit: ContentFit = .fill,
                consent: ScreenSaverConsent? = nil) {
        schemaVersion = Self.currentVersion
        self.source = source; self.isMuted = isMuted; self.fit = fit; self.consent = consent
    }

    public func selecting(_ source: ScreenSaverSource?) -> Self {
        Self(source: source, isMuted: isMuted, fit: fit, consent: self.source == source ? consent : nil)
    }

    public func confirming(_ consent: ScreenSaverConsent) throws -> Self {
        let result = Self(source: source, isMuted: isMuted, fit: fit, consent: consent)
        try result.validate()
        return result
    }

    public func validate() throws {
        guard schemaVersion == Self.currentVersion else {
            throw ScreenSaverFailure(code: .unsupportedSchema(schema: "settings", actualVersion: schemaVersion))
        }
        if let consent {
            guard source == consent.source else { throw ScreenSaverFailure(code: .invalidConsent) }
            try consent.validate()
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, source, isMuted, fit, consent }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentVersion else {
            throw ScreenSaverFailure(code: .unsupportedSchema(schema: "settings", actualVersion: schemaVersion))
        }
        source = try values.decodeIfPresent(ScreenSaverSource.self, forKey: .source)
        isMuted = try values.decode(Bool.self, forKey: .isMuted)
        fit = try values.decode(ContentFit.self, forKey: .fit)
        consent = try values.decodeIfPresent(ScreenSaverConsent.self, forKey: .consent)
        try validate()
    }

    /// Synchronous I/O boundary; callers performing application work must use their I/O executor.
    public static func read(from url: URL) throws -> Self? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", !url.path.contains("\0") else {
            throw ScreenSaverFailure(code: .invalidPath(url.path))
        }
        // Nonblocking open lets fstat reject a FIFO without waiting for a writer. No-follow rejects dangling links too.
        let descriptor = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw ScreenSaverFailure(code: .invalidPath(url.path)) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let result = Result<Self, Error> {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard info.st_mode & S_IFMT == S_IFREG else {
                throw ScreenSaverFailure(code: .nonRegularFile(url.path))
            }
            return try JSONDecoder().decode(Self.self, from: handle.readToEnd() ?? Data())
        }
        do { try handle.close() }
        catch {
            if case .failure(let original) = result { throw WallpaperErrorGroup([original, error]) }
            throw error
        }
        return try result.get()
    }
}
