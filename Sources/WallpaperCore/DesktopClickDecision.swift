import Foundation

public struct DesktopClickSample: Equatable, Sendable {
    public let screenID: String
    public let instanceID: UUID
    public let isConfirmedBlank: Bool
    public init(screenID: String, instanceID: UUID, isConfirmedBlank: Bool) {
        self.screenID = screenID; self.instanceID = instanceID; self.isConfirmedBlank = isConfirmedBlank
    }
}

public enum DesktopMouseButton: Sendable { case left, right, other }

public struct DesktopClickState: Sendable {
    public var enabled: Bool
    public var visibleInstanceID: UUID?
    public var isInteractive: Bool
    public var button: DesktopMouseButton
    public var didDrag: Bool
    public var clickCount: Int
    public init(enabled: Bool, visibleInstanceID: UUID?, isInteractive: Bool,
                button: DesktopMouseButton, didDrag: Bool, clickCount: Int) {
        self.enabled = enabled; self.visibleInstanceID = visibleInstanceID; self.isInteractive = isInteractive
        self.button = button; self.didDrag = didDrag; self.clickCount = clickCount
    }
}

public enum DesktopClickRejection: Equatable, Sendable {
    case disabled, inactive, unsupportedButton, dragged, invalidCount, unconfirmedDesktop, changedTarget
}

public enum DesktopClickDecision: Equatable, Sendable {
    case forward(clickCount: Int)
    case reject(DesktopClickRejection)

    /// Pure routing decision. The observer keeps original events untouched and captures both hit results.
    public static func decide(down: DesktopClickSample, up: DesktopClickSample,
                              state: DesktopClickState) -> DesktopClickDecision {
        guard state.enabled else { return .reject(.disabled) }
        guard state.isInteractive else { return .reject(.inactive) }
        guard state.button == .left else { return .reject(.unsupportedButton) }
        guard !state.didDrag else { return .reject(.dragged) }
        guard state.clickCount > 0 else { return .reject(.invalidCount) }
        guard down.isConfirmedBlank, up.isConfirmedBlank else { return .reject(.unconfirmedDesktop) }
        guard down.screenID == up.screenID, down.instanceID == up.instanceID,
              up.instanceID == state.visibleInstanceID else { return .reject(.changedTarget) }
        return .forward(clickCount: state.clickCount)
    }
}
