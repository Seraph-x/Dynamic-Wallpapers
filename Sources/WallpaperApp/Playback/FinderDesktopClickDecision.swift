import Foundation

struct FinderClickTarget: Equatable, Sendable {
    let screenID: String
    let pageID: UUID
    let windowID: UInt32
    let interactionGeneration: UUID

    init(screenID: String, pageID: UUID, windowID: UInt32, interactionGeneration: UUID = UUID()) {
        self.screenID = screenID; self.pageID = pageID; self.windowID = windowID
        self.interactionGeneration = interactionGeneration
    }
}

enum FinderMenuSnapshot: Equatable, Sendable {
    case closed, open, unavailable(String)
}

enum FinderMouseDestination: Sendable { case finder, otherProcess, unavailable }

struct FinderMenuEvidence: Equatable, Sendable {
    enum State: Equatable, Sendable { case unknown, open, observedClosed }
    private(set) var state: State = .unknown
    private(set) var generation = UUID()
    private(set) var failureReason: String?
    mutating func opened() { state = .open; generation = UUID(); failureReason = nil }
    mutating func closed() { state = .observedClosed; generation = UUID(); failureReason = nil }
    mutating func invalidate() { state = .unknown; generation = UUID(); failureReason = nil }

    @discardableResult
    mutating func apply(_ snapshot: FinderMenuSnapshot, ifUnchanged expected: UUID) -> Bool {
        guard generation == expected else { return false }
        let next: State
        let failure: String?
        switch snapshot {
        case .closed: next = .observedClosed; failure = nil
        case .open: next = .open; failure = nil
        case .unavailable(let reason): next = .unknown; failure = reason
        }
        if state != next || failureReason != failure { generation = UUID() }
        state = next; failureReason = failure
        return true
    }
}

struct FinderDesktopSample: Sendable {
    let target: FinderClickTarget
    let menu: FinderMenuEvidence
    let roles: [String]
    let allOwnersAreFinder: Bool
    let completeAncestry: Bool
    let windowsClear: Bool
    var destination: FinderMouseDestination = .unavailable
    var failureReason: String?
}

enum FinderDesktopClickDecision: Equatable {
    enum Rejection: String {
        case menuUnknown = "Finder 菜单状态尚未确认"
        case menuOpen = "Finder 菜单已打开"
        case menuChanged = "点击期间 Finder 菜单发生变化"
        case targetChanged = "网页目标已变化或不可交互"
        case dragged = "拖动操作不转发"
        case invalidCount = "点击次数无效"
        case notFinderDesktop = "未确认 Finder 桌面空白"
        case windowObscured = "点击位置存在窗口遮挡或窗口信息不可用"
        case eventNotFinder = "原始点击由其他应用处理或事件目标不明确"
    }
    case forward
    case reject(Rejection)

    static func decide(down: FinderDesktopSample, up: FinderDesktopSample,
                       currentMenu: FinderMenuEvidence, currentTarget: FinderClickTarget?,
                       didDrag: Bool, clickCount: Int) -> Self {
        guard down.menu.generation == up.menu.generation,
              up.menu.generation == currentMenu.generation else { return .reject(.menuChanged) }
        guard currentMenu.state != .unknown else { return .reject(.menuUnknown) }
        guard currentMenu.state == .observedClosed else { return .reject(.menuOpen) }
        guard down.target == up.target, up.target == currentTarget else { return .reject(.targetChanged) }
        guard !didDrag else { return .reject(.dragged) }
        guard clickCount > 0 else { return .reject(.invalidCount) }
        guard down.destination == .finder, up.destination == .finder else { return .reject(.eventNotFinder) }
        let desktopRoles = ["AXGroup", "AXScrollArea", "AXApplication"]
        guard [down, up].allSatisfy({ $0.completeAncestry && $0.allOwnersAreFinder && $0.roles == desktopRoles })
        else { return .reject(.notFinderDesktop) }
        guard down.windowsClear, up.windowsClear else { return .reject(.windowObscured) }
        return .forward
    }
}
