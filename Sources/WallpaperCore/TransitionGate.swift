import Foundation

/// Serializes visible transitions while allowing obsolete preparations to be cancelled.
public struct TransitionGate {
    public private(set) var preparing: UUID?
    public private(set) var transitioning: UUID?
    private var queued: UUID?
    public init() {}
    public mutating func request(_ id: UUID) -> Bool {
        if transitioning != nil { queued = id; return false }
        preparing = id
        return true
    }
    public mutating func beginTransition(_ id: UUID) -> Bool {
        guard preparing == id, transitioning == nil else { return false }
        preparing = nil; transitioning = id
        return true
    }
    public mutating func finish(_ id: UUID) -> UUID? {
        guard transitioning == id else { return nil }
        transitioning = nil
        preparing = queued; queued = nil
        return preparing
    }
    public mutating func fail(_ id: UUID) { if preparing == id { preparing = nil } }
}
