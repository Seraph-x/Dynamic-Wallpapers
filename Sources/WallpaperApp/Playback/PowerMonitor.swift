import AppKit
import WallpaperCore

@MainActor
final class PowerMonitor {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var reasons = Set<String>()
    var settings = AppSettings() { didSet { refreshPower() } }
    var onChange: ((Set<String>) -> Void)?

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, reason, active) in [
            (NSWorkspace.willSleepNotification, "系统休眠", true),
            (NSWorkspace.didWakeNotification, "系统休眠", false),
            (NSWorkspace.screensDidSleepNotification, "显示器休眠", true),
            (NSWorkspace.screensDidWakeNotification, "显示器休眠", false),
            (NSWorkspace.sessionDidResignActiveNotification, "用户会话未激活", true),
            (NSWorkspace.sessionDidBecomeActiveNotification, "用户会话未激活", false)
        ] {
            observe(workspace, name) { [weak self] in self?.set(reason, active: active) }
        }
        observe(.default, .NSProcessInfoPowerStateDidChange) { [weak self] in self?.refreshPower() }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in self?.refreshPower() }
        // macOS distributed lock notifications complement public sleep/session notifications.
        for (name, active) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let token = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.set("已锁屏", active: active) }
            }
            distributedObservers.append(token)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor @Sendable () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in action() } }
        observers.append((center, token))
    }
    private func set(_ reason: String, active: Bool) {
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        onChange?(reasons)
    }
    private func refreshPower() {
        set("低电量模式", active: settings.pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled)
        let state = ProcessInfo.processInfo.thermalState
        set("设备温度较高", active: settings.pauseOnHighTemperature && (state == .serious || state == .critical))
    }
    func shutdown() {
        observers.forEach { $0.0.removeObserver($0.1) }; observers.removeAll()
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributedObservers.removeAll()
    }
}
