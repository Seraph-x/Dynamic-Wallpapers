import AppKit
import WallpaperCore

@MainActor
final class OtherAppFullScreenMonitor {
    struct Window {
        let owner: pid_t
        let layer: Int
        let bounds: CGRect
    }

    private let sample: @MainActor () throws -> Bool
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var lastReportedError: String?
    private(set) var isActive = false
    var onChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(sample: @escaping @MainActor () throws -> Bool = OtherAppFullScreenMonitor.sampleSystemWindows) {
        self.sample = sample
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification)
        observe(workspace, NSWorkspace.didActivateApplicationNotification)
        observe(.default, NSApplication.didChangeScreenParametersNotification)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != (timer != nil) else { return }
        if enabled {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
            lastReportedError = nil
            publish(false)
        }
    }

    func refresh() {
        guard timer != nil else { return }
        do {
            publish(try sample())
            lastReportedError = nil
        } catch {
            let description = error.localizedDescription
            if lastReportedError != description { onError?(error) }
            lastReportedError = description
        }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
    }

    private func publish(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        onChange?(active)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append((center, token))
    }

    private static func sampleSystemWindows() throws -> Bool {
        guard let values = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            throw WallpaperError("无法读取系统窗口列表，无法判断其他应用是否全屏。")
        }
        let windows = try values.map { value -> Window in
            guard let owner = value[kCGWindowOwnerPID as String] as? Int,
                  let layer = value[kCGWindowLayer as String] as? Int,
                  let dictionary = value[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else {
                throw WallpaperError("系统窗口列表缺少有效的进程、层级或范围。")
            }
            return Window(owner: pid_t(owner), layer: layer, bounds: bounds)
        }
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
        guard displays.count == NSScreen.screens.count else {
            throw WallpaperError("无法读取显示器范围，无法判断其他应用是否全屏。")
        }
        return containsFullScreenWindow(windows, displays: displays,
                                        ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    static func containsFullScreenWindow(_ windows: [Window], displays: [CGRect],
                                         ownPID: pid_t) -> Bool {
        let externalWindows = windows.filter { $0.owner != ownPID && $0.layer == 0 }
        let windowsByOwner = Dictionary(grouping: externalWindows, by: \.owner)
        return windowsByOwner.values.contains { ownedWindows in
            displays.contains { display in
                let bounds = ownedWindows.map(\.bounds).filter { contains($0, in: display) }
                return covers(display, with: bounds)
            }
        }
    }

    private static let edgeTolerance: CGFloat = 1

    private static func contains(_ bounds: CGRect, in display: CGRect) -> Bool {
        bounds.width > 0 && bounds.height > 0 && display.intersects(bounds)
            && bounds.minX >= display.minX - edgeTolerance && bounds.minY >= display.minY - edgeTolerance
            && bounds.maxX <= display.maxX + edgeTolerance && bounds.maxY <= display.maxY + edgeTolerance
    }

    private static func covers(_ display: CGRect, with bounds: [CGRect]) -> Bool {
        let rectangles = bounds.map { $0.intersection(display) }
        let xEdges = ([display.minX, display.maxX] + rectangles.flatMap { [$0.minX, $0.maxX] }).sorted()
        for (left, right) in zip(xEdges, xEdges.dropFirst()) where right - left > edgeTolerance {
            let midX = (left + right) / 2
            let verticalSpans = rectangles.filter { $0.minX <= midX && $0.maxX >= midX }
                .sorted { $0.minY < $1.minY }
            var coveredY = display.minY
            for span in verticalSpans {
                if span.minY > coveredY + edgeTolerance { return false }
                coveredY = max(coveredY, span.maxY)
                if coveredY >= display.maxY - edgeTolerance { break }
            }
            if coveredY < display.maxY - edgeTolerance { return false }
        }
        return !rectangles.isEmpty
    }
}
