import CoreFoundation
import Foundation
import WallpaperCore

public enum DiagnosticFloatingPoint: Equatable, Sendable {
    case nan
    case positiveZero
    case negativeZero
    case positiveInfinity
    case negativeInfinity
    case finite(bitPattern: UInt64)

    public init(_ value: Double) {
        if value.isNaN { self = .nan }
        else if value == 0 { self = value.sign == .minus ? .negativeZero : .positiveZero }
        else if value == .infinity { self = .positiveInfinity }
        else if value == -.infinity { self = .negativeInfinity }
        else { self = .finite(bitPattern: value.bitPattern) }
    }
}

public struct DiagnosticEntry: Equatable, Sendable {
    public let key: String
    public let value: DiagnosticValue

    public init(key: String, value: DiagnosticValue) {
        self.key = key
        self.value = value
    }
}

public indirect enum DiagnosticValue: Equatable, Sendable {
    case null
    case string(String)
    case signed(Int64)
    case unsigned(UInt64)
    case floating(DiagnosticFloatingPoint)
    case bool(Bool)
    case url(String)
    case date(String)
    case data(String)
    case array([DiagnosticValue])
    case map([DiagnosticEntry])
    case error(FailureDiagnostic)
    case unsupported(type: String)
    case cycle(type: String, path: String)
}

public struct FailureDiagnostic: Equatable, Sendable {
    public let domain: String
    public let code: Int
    public let localizedDescription: String
    public let failureReason: String?
    public let recoverySuggestion: String?
    public let userInfo: [DiagnosticEntry]
    public let underlying: DiagnosticValue?

    public init(capturing error: Error) {
        var context = DiagnosticCaptureContext()
        guard case .error(let diagnostic) = context.capture(error as NSError, path: "error") else {
            preconditionFailure("Root NSError capture must produce an error diagnostic")
        }
        self = diagnostic
    }

    fileprivate init(domain: String, code: Int, localizedDescription: String,
                     failureReason: String?, recoverySuggestion: String?,
                     userInfo: [DiagnosticEntry], underlying: DiagnosticValue?) {
        self.domain = domain
        self.code = code
        self.localizedDescription = localizedDescription
        self.failureReason = failureReason
        self.recoverySuggestion = recoverySuggestion
        self.userInfo = userInfo
        self.underlying = underlying
    }
}

private struct DiagnosticCaptureContext {
    private var active = Set<ObjectIdentifier>()

    mutating func capture(_ value: Any, path: String) -> DiagnosticValue {
        if value is NSNull { return .null }
        // Conditional scalar casts bridge NSNumber by value, conflating 0/1 with Bool.
        // Inspect only actual objects so native Swift unsigned/float types stay intact.
        if type(of: value) is NSNumber.Type, let number = value as? NSNumber {
            return Self.captureNumber(number)
        }
        if let value = value as? String { return .string(value) }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? Int { return .signed(Int64(value)) }
        if let value = value as? Int8 { return .signed(Int64(value)) }
        if let value = value as? Int16 { return .signed(Int64(value)) }
        if let value = value as? Int32 { return .signed(Int64(value)) }
        if let value = value as? Int64 { return .signed(value) }
        if let value = value as? UInt { return .unsigned(UInt64(value)) }
        if let value = value as? UInt8 { return .unsigned(UInt64(value)) }
        if let value = value as? UInt16 { return .unsigned(UInt64(value)) }
        if let value = value as? UInt32 { return .unsigned(UInt64(value)) }
        if let value = value as? UInt64 { return .unsigned(value) }
        if let value = value as? Double { return .floating(DiagnosticFloatingPoint(value)) }
        if let value = value as? Float { return .floating(DiagnosticFloatingPoint(Double(value))) }
        if let value = value as? URL { return .url(value.absoluteString) }
        if let value = value as? Date { return .date(Self.date(value)) }
        if let value = value as? Data { return .data(value.base64EncodedString()) }
        if let value = value as? NSError { return captureError(value, path: path) }
        if let value = value as? Error { return captureError(value as NSError, path: path) }
        if let value = value as? NSArray { return captureArray(value, path: path) }
        if let value = value as? NSDictionary { return captureMap(value, path: path) }
        return .unsupported(type: Self.typeName(value))
    }

    private static func captureNumber(_ number: NSNumber) -> DiagnosticValue {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q": return .signed(number.int64Value)
        case "C", "S", "I", "L", "Q": return .unsigned(number.uint64Value)
        case "f", "d": return .floating(DiagnosticFloatingPoint(number.doubleValue))
        default: return .unsupported(type: Self.typeName(number))
        }
    }

    private mutating func captureError(_ error: NSError, path: String) -> DiagnosticValue {
        let identity = ObjectIdentifier(error)
        if active.contains(identity) { return .cycle(type: Self.typeName(error), path: path) }
        active.insert(identity)
        defer { active.remove(identity) }
        let entries = error.userInfo.keys
            .filter { $0 != NSUnderlyingErrorKey }
            .sorted()
            .map { key in
                DiagnosticEntry(key: key, value: capture(error.userInfo[key]!, path: "\(path).userInfo.\(key)"))
            }
        let underlying = error.userInfo[NSUnderlyingErrorKey]
            .map { capture($0, path: "\(path).underlying") }
        return .error(FailureDiagnostic(domain: error.domain, code: error.code,
            localizedDescription: error.localizedDescription,
            failureReason: error.localizedFailureReason,
            recoverySuggestion: error.localizedRecoverySuggestion,
            userInfo: entries, underlying: underlying))
    }

    private mutating func captureArray(_ array: NSArray, path: String) -> DiagnosticValue {
        let identity = ObjectIdentifier(array)
        if active.contains(identity) { return .cycle(type: Self.typeName(array), path: path) }
        active.insert(identity)
        defer { active.remove(identity) }
        return .array((0..<array.count).map { capture(array.object(at: $0), path: "\(path)[\($0)]") })
    }

    private mutating func captureMap(_ map: NSDictionary, path: String) -> DiagnosticValue {
        let identity = ObjectIdentifier(map)
        if active.contains(identity) { return .cycle(type: Self.typeName(map), path: path) }
        active.insert(identity)
        defer { active.remove(identity) }
        let keys = map.allKeys.map { key -> (String, Any) in
            if let text = key as? String { return (text, key) }
            return ("<unsupported-key:\(Self.typeName(key))>", key)
        }.sorted { $0.0 < $1.0 }
        return .map(keys.map { key, original in
            DiagnosticEntry(key: key, value: capture(map.object(forKey: original)!,
                path: "\(path).\(key)"))
        })
    }

    private static func typeName(_ value: Any) -> String {
        String(reflecting: type(of: value))
    }

    private static func date(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
}

public struct ScreenSaverFailure: LocalizedError, Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case configuration, load, publish, commit, cleanup, release, preview, install, shutdown
    }

    public enum Code: Equatable, Sendable {
        case unsupportedSchema(schema: String, actualVersion: Int)
        case emptySource, noSupportedMedia, confirmationRequired
        case missingMedia(UUID), sourceMissing(ScreenSaverSource)
        case invalidSourceMetadata(String), missingDuration(String), unsupportedDuration
        case invalidProjection, invalidConsent
        case invalidPath(String), nonRegularFile(String), sourceChanged(String), copyMismatch(String)
        case integrityMismatch(String), unknownGeneration(UUID), identityMissing, identityChanged
        case lockBusy, leaseFailure(Phase), transactionConflict(Phase)
        case publicationFailed, committedThenFailed, settingsUnavailable, pointerUnavailable
        case resourceReleaseFailed, cancelled(Phase), applicationClosing(Phase)
        case bundleMetadataInvalid(String), bundleExecutableInvalid(String)
        case infoPlistTooLarge(String), infoPlistInvalid(String), installationFailed
        case previewUnavailable, authorizationRequired, bookmarkInvalid, unexpected
    }

    public let code: Code
    public let reasons: [ScreenSaverFailure]
    public let diagnostic: FailureDiagnostic?

    public init(code: Code, reasons: [ScreenSaverFailure] = [], diagnostic: FailureDiagnostic? = nil) {
        self.code = code
        self.reasons = reasons
        self.diagnostic = diagnostic
    }

    public init(capturing error: Error, phase: Phase? = nil) {
        if let failure = error as? ScreenSaverFailure { self = failure; return }
        if let projection = error as? ScreenSaverProjectionError {
            switch projection {
            case .sourceMissing(let source): self.init(code: .sourceMissing(source))
            case .emptySource: self.init(code: .emptySource)
            case .missingMedia(let id): self.init(code: .missingMedia(id))
            case .noSupportedMedia: self.init(code: .noSupportedMedia)
            case .confirmationRequired: self.init(code: .confirmationRequired)
            }
            return
        }
        if error is ScreenSaverFileLockError { self.init(code: .lockBusy); return }
        if error is CancellationError {
            guard let phase else {
                self.init(code: .unexpected, diagnostic: FailureDiagnostic(capturing: error))
                return
            }
            self.init(code: .cancelled(phase), diagnostic: FailureDiagnostic(capturing: error))
            return
        }
        if let publication = error as? ScreenSaverPublicationFailure {
            self = publication.failure
            return
        }
        if let group = error as? WallpaperErrorGroup {
            let code: Code
            switch phase {
            case .publish: code = .publicationFailed
            case .commit: code = .transactionConflict(.commit)
            case .cleanup, .release, .shutdown: code = .resourceReleaseFailed
            default: code = .unexpected
            }
            self.init(code: code, reasons: group.errors.map { ScreenSaverFailure(capturing: $0, phase: phase) })
            return
        }
        self.init(code: .unexpected, diagnostic: FailureDiagnostic(capturing: error))
    }

    public var errorDescription: String? {
        let summary: String
        switch code {
        case .unsupportedSchema(let schema, let version): summary = "不支持的屏保\(schema)版本：\(version)。"
        case .emptySource: summary = "屏保来源为空。"
        case .noSupportedMedia: summary = "屏保来源没有支持的媒体。"
        case .confirmationRequired: summary = "需要确认被排除的屏保条目。"
        case .missingMedia(let id): summary = "屏保素材不存在：\(id)。"
        case .sourceMissing: summary = "屏保来源已不存在。"
        case .invalidSourceMetadata(let name): summary = "屏保来源素材元数据无效：\(name)。"
        case .missingDuration(let name): summary = "屏保媒体缺少有效时长：\(name)。"
        case .unsupportedDuration: summary = "屏保媒体的停留时长不受支持。"
        case .invalidProjection: summary = "屏保投影无效。"
        case .invalidConsent: summary = "屏保排除确认无效。"
        case .invalidPath(let path): summary = "屏保路径无效：\(path)。"
        case .nonRegularFile(let path): summary = "屏保文件不是普通文件：\(path)。"
        case .sourceChanged(let name): summary = "屏保来源已改变：\(name)。"
        case .copyMismatch(let name): summary = "屏保副本校验失败：\(name)。"
        case .integrityMismatch(let path): summary = "屏保内容完整性校验失败：\(path)。"
        case .unknownGeneration(let id): summary = "屏保目录包含未知代号：\(id)。"
        case .identityMissing: summary = "屏保导出身份缺失。"
        case .identityChanged: summary = "屏保导出身份已改变。"
        case .lockBusy: summary = "屏保文件锁正忙。"
        case .leaseFailure(let phase): summary = "屏保租约操作失败：\(phase.rawValue)。"
        case .transactionConflict(let phase): summary = "屏保事务冲突：\(phase.rawValue)。"
        case .publicationFailed: summary = "屏保发布失败。"
        case .committedThenFailed: summary = "屏保已提交，但后续操作失败。"
        case .settingsUnavailable: summary = "屏保设置不可用。"
        case .pointerUnavailable: summary = "屏保当前指针不可用。"
        case .resourceReleaseFailed: summary = "屏保资源释放失败。"
        case .cancelled(let phase): summary = "屏保操作已取消：\(phase.rawValue)。"
        case .applicationClosing(let phase): summary = "应用正在退出，无法执行屏保操作：\(phase.rawValue)。"
        case .bundleMetadataInvalid(let name): summary = "屏保 Bundle 元数据无效：\(name)。"
        case .bundleExecutableInvalid(let name): summary = "屏保 Bundle 可执行文件无效：\(name)。"
        case .infoPlistTooLarge(let name): summary = "屏保 Info.plist 过大：\(name)。"
        case .infoPlistInvalid(let name): summary = "屏保 Info.plist 无效：\(name)。"
        case .installationFailed: summary = "屏保安装失败。"
        case .previewUnavailable: summary = "屏保预览不可用。"
        case .authorizationRequired: summary = "需要授权屏保发布目录。"
        case .bookmarkInvalid: summary = "屏保目录授权记录无效。"
        case .unexpected: summary = "发生未预期的屏保错误。"
        }
        guard !reasons.isEmpty else { return summary }
        return summary + " " + reasons.compactMap(\.errorDescription).joined(separator: "；")
    }
}
