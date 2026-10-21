import AppKit
import WallpaperCore

/// Owns only committed wallpaper windows, never the temporary desktop preview layer.
@MainActor
final class DesktopWallpaperSource {
    private struct Record {
        let window: DesktopWindow
        var target: SystemWallpaperTarget?
    }
    private let captureImage: (NSWindow) async throws -> CGImage
    private var records: [String: Record] = [:]
    private var activeDisplayIDs: Set<String> = []
    private var captures: [ObjectIdentifier: [UUID: Task<CGImage, Error>]] = [:]
    var onChange: (([SystemWallpaperTarget]) -> Void)?

    init(capture: @escaping (NSWindow) async throws -> CGImage = { try await WallpaperSnapshot.capture(window: $0) }) {
        captureImage = capture
    }

    var targets: [SystemWallpaperTarget] {
        records.values.compactMap(\.target).filter(isCurrent).sorted { $0.displayID < $1.displayID }
    }

    func updateActiveDisplays(_ displayIDs: Set<String>) {
        guard displayIDs != activeDisplayIDs else { return }
        for displayID in activeDisplayIDs.subtracting(displayIDs) { records[displayID]?.target = nil }
        activeDisplayIDs = displayIDs
        // Revocation survives a rapid rebind; only a new commit can publish another target.
        // Keep windows and captures owned until retire can wait for the real release barrier.
        onChange?(targets)
    }

    func commit(window: DesktopWindow, displayID: String, item: MediaItem, fit: ContentFit,
                sourceVersion: Result<String, WallpaperError>) throws {
        guard let revision = window.committedWallpaperID else {
            throw WallpaperError("正式壁纸尚未完成显示，无法同步系统底图。")
        }
        let size = try pixelSize(of: window)
        let target = SystemWallpaperTarget(displayID: displayID, revision: revision,
            content: SystemWallpaperContent(item: item, fit: fit, width: size.width, height: size.height),
            sourceVersion: sourceVersion)
        records[displayID] = Record(window: window, target: target)
        onChange?(targets)
    }

    func isCurrent(_ target: SystemWallpaperTarget) -> Bool {
        guard activeDisplayIDs.contains(target.displayID), let record = records[target.displayID], record.target == target,
              record.window.committedWallpaperID == target.revision else { return false }
        let window = record.window
        return (window.frame.width * window.backingScaleFactor).rounded() == CGFloat(target.content.width)
            && (window.frame.height * window.backingScaleFactor).rounded() == CGFloat(target.content.height)
    }

    func capture(_ target: SystemWallpaperTarget) async throws -> CGImage {
        try Task.checkCancellation()
        guard isCurrent(target), let record = records[target.displayID] else { throw CancellationError() }
        let window = record.window
        let windowID = ObjectIdentifier(window)
        let requestID = UUID()
        // The OS capture must really return before retirement may release this window's surfaces.
        let operation = Task { @MainActor [captureImage] in try await captureImage(window) }
        captures[windowID, default: [:]][requestID] = operation
        defer {
            captures[windowID]?.removeValue(forKey: requestID)
            if captures[windowID]?.isEmpty == true { captures.removeValue(forKey: windowID) }
        }
        let image = try await operation.value
        try Task.checkCancellation()
        guard isCurrent(target) else { throw CancellationError() }
        return image
    }

    func retire(displayID: String) -> Task<Void, Never>? {
        guard let record = records.removeValue(forKey: displayID) else { return nil }
        onChange?(targets)
        let pending = Array(captures[ObjectIdentifier(record.window)]?.values ?? [:].values)
        guard !pending.isEmpty else { return nil }
        return Task { @MainActor in
            // Capture callers report errors; this barrier only owns the source's release order.
            for operation in pending { _ = await operation.result }
        }
    }

    private func pixelSize(of window: DesktopWindow) throws -> (width: Int, height: Int) {
        guard let width = Int(exactly: (window.frame.width * window.backingScaleFactor).rounded()), width > 0,
              let height = Int(exactly: (window.frame.height * window.backingScaleFactor).rounded()), height > 0 else {
            throw WallpaperError("系统底图显示器尺寸无效。")
        }
        return (width, height)
    }
}
