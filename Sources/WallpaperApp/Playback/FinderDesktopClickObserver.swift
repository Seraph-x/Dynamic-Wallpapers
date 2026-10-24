import AppKit
import ApplicationServices
import WallpaperCore

struct WebInteractionStatus: Equatable {
    let message: String
    let diagnostics: String?
    init(_ message: String, diagnostics: String? = nil) {
        self.message = message; self.diagnostics = diagnostics
    }
    var diagnosticDescription: String { diagnostics.map { "\(message)\n\($0)" } ?? message }

    static func failure(_ error: Error) -> Self {
        if let failure = error as? WallpaperError {
            return Self("网页交互不可用：\(failure.message)", diagnostics: failure.diagnostic)
        }
        return Self("网页交互不可用：无法监听桌面点击。", diagnostics: String(describing: error as NSError))
    }
}

/// The observer owns this pair exclusively; releasing it always disables the tap.
private final class FinderTapResources {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(tap: CFMachPort, source: CFRunLoopSource) {
        self.tap = tap
        self.source = source
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    deinit { stop() }
}

/// Observes the original delivery without consuming or posting any system event.
@MainActor
final class FinderDesktopClickObserver {
    typealias TargetProvider = (CGPoint) -> FinderClickTarget?
    var onStatus: ((WebInteractionStatus) -> Void)?
    var onClick: ((CGPoint, Int, FinderClickTarget) throws -> Bool)?
    var onPointer: ((CGPoint, String, FinderClickTarget) throws -> Void)?
    private var pointerQueryActive = false
    private var pendingPointer: CGPoint?
    private var lastPointerTarget: FinderClickTarget?
    private(set) var status = WebInteractionStatus("网页交互已关闭")
    private(set) var isRunning = false
    var isReady: Bool { isRunning && menuObserver.evidence.state == .observedClosed }
    private let targetAtPoint: TargetProvider
    private let queryQueue = DispatchQueue(label: "local.dynamicwallpaper.finder-hit")
    private let menuObserver = FinderDesktopMenuObserver()
    private var tapResources: FinderTapResources?
    private var finderPID: pid_t = 0
    private var sessionID = UUID()
    private var candidate: Candidate?
    private var lastDecision: String?

    private final class Candidate {
        let id = UUID()
        let downTime: UInt64
        let clickCount: Int
        let target: FinderClickTarget
        var down: FinderDesktopSample?
        var up: FinderDesktopSample?
        var upPoint: CGPoint?
        init(downTime: UInt64, clickCount: Int, target: FinderClickTarget) {
            self.downTime = downTime; self.clickCount = clickCount; self.target = target
        }
    }

    init(targetAtPoint: @escaping TargetProvider) {
        self.targetAtPoint = targetAtPoint
        menuObserver.onChange = { [weak self] in
            self?.candidate = nil
            self?.updateStatus()
        }
    }

    func start() throws {
        guard !isRunning else { return }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            throw WallpaperError("请在系统设置中检查“辅助功能”和“输入监控”权限。")
        }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw WallpaperError("Finder 未运行，无法观察桌面点击。")
        }
        finderPID = finder.processIdentifier
        sessionID = UUID(); lastDecision = nil
        do {
            try menuObserver.start(finderPID: finderPID)
            let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                       .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                       .otherMouseDown, .otherMouseUp, .otherMouseDragged]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
            // Annotated events carry the original destination PID. Unknown values are rejected.
            guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap,
                options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                    if let context {
                        MainActor.assumeIsolated {
                            Unmanaged<FinderDesktopClickObserver>.fromOpaque(context).takeUnretainedValue().receive(type, event)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                throw WallpaperError("无法建立只读桌面鼠标监听。")
            }
            tapResources = FinderTapResources(tap: tap, source: source)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            isRunning = true
            CGEvent.tapEnable(tap: tap, enable: true)
            updateStatus()
        } catch {
            let status = WebInteractionStatus.failure(error)
            stop(reason: status.message, diagnostics: status.diagnostics)
            throw error
        }
    }

    func stop(reason: String = "网页交互已关闭", diagnostics: String? = nil) {
        leavePointer()
        pendingPointer = nil
        isRunning = false; sessionID = UUID(); candidate = nil; lastDecision = nil
        tapResources?.stop()
        tapResources = nil
        menuObserver.stop()
        setStatus(WebInteractionStatus(reason, diagnostics: diagnostics))
    }

    func refreshStatus() {
        guard isRunning else { return }
        guard validateObservation() else { return }
        menuObserver.refresh()
        updateStatus()
    }

    private func validateObservation() -> Bool {
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            stop(reason: "网页交互不可用，请在系统设置中检查“辅助功能”和“输入监控”权限。"); return false
        }
        guard NSRunningApplication(processIdentifier: finderPID)?.isTerminated == false else {
            stop(reason: "网页交互不可用：Finder 已退出。"); return false
        }
        return true
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop(reason: "网页交互不可用：系统已停用桌面鼠标监听。"); return
        }
        guard isRunning, validateObservation() else { return }
        if type == .mouseMoved {
            pendingPointer = event.location
            inspectLatestPointer()
            return
        }
        guard type == .leftMouseDown || type == .leftMouseUp else {
            reject("拖动或非左键操作不转发"); menuObserver.refresh(); return
        }
        guard !event.flags.contains(.maskControl) else {
            reject("Control 点击属于系统菜单操作"); menuObserver.invalidate(); return
        }
        let destinationPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        guard destinationPID > 0, destinationPID == Int64(finderPID) else {
            reject(destinationPID <= 0 ? "原始事件目标进程不可用" : "原始点击由其他应用处理")
            menuObserver.refresh()
            return
        }
        guard let since = menuObserver.knownClosedSince,
              menuObserver.evidence.state == .observedClosed, event.timestamp >= since else {
            candidate = nil; updateStatus(); menuObserver.refresh(); return
        }
        let point = event.location
        guard point.x.isFinite, point.y.isFinite, let target = targetAtPoint(point) else {
            reject("当前网页未稳定显示或点击位置不可交互"); return
        }
        let count = Int(event.getIntegerValueField(.mouseEventClickState))
        guard count > 0 else { reject("点击次数无效"); return }
        if type == .leftMouseDown {
            let pending = Candidate(downTime: event.timestamp, clickCount: count, target: target)
            candidate = pending
            inspect(point: point, candidate: pending, isDown: true)
        } else {
            guard let pending = candidate, pending.target == target, pending.clickCount == count,
                  pending.upPoint == nil, event.timestamp > pending.downTime else {
                reject("没有匹配的完整左键按下记录"); return
            }
            pending.upPoint = point
            inspect(point: point, candidate: pending, isDown: false)
        }
    }

    /// Coalesce movement while AX is querying: only the latest cursor position
    /// matters, and a slow query must never build an unbounded event backlog.
    private func inspectLatestPointer() {
        guard !pointerQueryActive, let point = pendingPointer else { return }
        pendingPointer = nil
        guard isRunning, point.x.isFinite, point.y.isFinite,
              menuObserver.evidence.state == .observedClosed,
              let target = targetAtPoint(point) else { leavePointer(); return }
        pointerQueryActive = true
        let session = sessionID, pid = finderPID, menu = menuObserver.evidence
        queryQueue.async { [weak self] in
            // Movement has no click destination. Exact Finder AX ancestry and
            // window occlusion establish whether it is above desktop blank space.
            let sample = FinderDesktopHitSampler.sample(point: point, target: target, menu: menu,
                                                        finderPID: pid, destination: .finder)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pointerQueryActive = false
                defer { self.inspectLatestPointer() }
                guard self.isRunning, self.sessionID == session else { return }
                let decision = FinderDesktopClickDecision.decide(down: sample, up: sample,
                    currentMenu: self.menuObserver.evidence, currentTarget: self.targetAtPoint(point),
                    didDrag: false, clickCount: 1)
                guard decision == .forward else { self.leavePointer(); return }
                if self.lastPointerTarget != target { self.leavePointer() }
                do {
                    try self.onPointer?(point, "move", target)
                    self.lastPointerTarget = target
                } catch { self.reject("场景鼠标转发失败：\(error.localizedDescription)") }
            }
        }
    }

    private func leavePointer() {
        guard let target = lastPointerTarget else { return }
        lastPointerTarget = nil
        do { try onPointer?(.zero, "leave", target) }
        catch { reject("场景鼠标离开事件失败：\(error.localizedDescription)") }
    }

    private func inspect(point: CGPoint, candidate pending: Candidate, isDown: Bool) {
        let id = pending.id, target = pending.target, menu = menuObserver.evidence
        let session = sessionID, pid = finderPID
        queryQueue.async { [weak self] in
            let sample = FinderDesktopHitSampler.sample(point: point, target: target, menu: menu,
                                                        finderPID: pid, destination: .finder)
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.sessionID == session,
                      let pending = self.candidate, pending.id == id else { return }
                if isDown { pending.down = sample } else { pending.up = sample }
                self.finishIfReady(pending)
            }
        }
    }

    private func finishIfReady(_ pending: Candidate) {
        guard let down = pending.down, let up = pending.up, let point = pending.upPoint else { return }
        candidate = nil
        guard validateObservation() else { return }
        let decision = FinderDesktopClickDecision.decide(down: down, up: up, currentMenu: menuObserver.evidence,
            currentTarget: targetAtPoint(point), didDrag: false, clickCount: pending.clickCount)
        switch decision {
        case .forward:
            guard let onClick else { reject("网页点击接收器未连接"); return }
            do {
                guard try onClick(point, pending.clickCount, pending.target) else {
                    reject("点击处没有网页内容"); return
                }
                lastDecision = "已转发桌面空白左键点击"
                updateStatus()
            } catch { reject("网页点击转发失败：\(error.localizedDescription)") }
        case .reject(let reason):
            let detail = down.failureReason ?? up.failureReason ?? down.menu.failureReason ?? up.menu.failureReason
            reject(reason.rawValue + (detail.map { "：\($0)" } ?? ""))
        }
    }

    private func reject(_ reason: String) {
        candidate = nil
        lastDecision = "未转发：\(reason)"
        updateStatus()
    }

    private func updateStatus() {
        guard isRunning else { return }
        switch menuObserver.evidence.state {
        case .observedClosed:
            setStatus(WebInteractionStatus("网页交互可用 · 仅响应桌面空白处的左键点击",
                diagnostics: lastDecision.map { "最近一次点击：\($0)" }))
        case .open: setStatus(WebInteractionStatus("网页交互暂不可用：Finder 菜单已打开。"))
        case .unknown:
            if let reason = menuObserver.evidence.failureReason {
                setStatus(WebInteractionStatus("网页交互暂不可用：无法确认 Finder 菜单状态。", diagnostics: reason))
            } else { setStatus(WebInteractionStatus("正在确认 Finder 菜单状态…")) }
        }
    }

    private func setStatus(_ value: WebInteractionStatus) {
        guard value != status else { return }
        status = value
        onStatus?(value)
    }
}
