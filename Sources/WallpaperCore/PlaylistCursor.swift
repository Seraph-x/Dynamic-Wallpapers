import Foundation

public struct PlaybackProposal: Equatable, Sendable {
    public let token: UUID
    public let entryID: UUID
}

public struct PlaylistCursor {
    public private(set) var current: UUID?
    public private(set) var pending: PlaybackProposal?
    private var played = Set<UUID>()
    private var startsNewRound = false

    public init(current: UUID? = nil) { self.current = current; if let current { played.insert(current) } }

    @discardableResult
    public mutating func prepare(ids: [UUID], mode: PlaybackMode,
                                 shuffled: ([UUID]) -> [UUID] = { $0.shuffled() }) throws -> PlaybackProposal {
        guard !ids.isEmpty else { throw WallpaperError("播放列表为空，请先添加壁纸。") }
        let base = pending?.entryID ?? current
        startsNewRound = false
        let next: UUID
        switch mode {
        case .ordered:
            next = base.flatMap { ids.firstIndex(of: $0) }.map { ids[($0 + 1) % ids.count] } ?? ids[0]
        case .repeatOne: next = current.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]
        case .shuffle:
            var candidates = ids.filter { !played.contains($0) }
            if candidates.isEmpty {
                startsNewRound = true
                candidates = ids.filter { $0 != current || ids.count == 1 }
            }
            next = shuffled(candidates)[0]
        }
        let result = PlaybackProposal(token: UUID(), entryID: next)
        pending = result
        return result
    }

    public mutating func prepare(entryID: UUID) -> PlaybackProposal {
        startsNewRound = false
        let result = PlaybackProposal(token: UUID(), entryID: entryID)
        pending = result
        return result
    }

    @discardableResult
    public mutating func commit(_ proposal: PlaybackProposal) -> Bool {
        guard proposal == pending else { return false }
        if startsNewRound { played.removeAll() }
        played.insert(proposal.entryID)
        current = proposal.entryID; pending = nil
        return true
    }
    public mutating func cancel() { pending = nil; startsNewRound = false }
}

public struct PlaybackClock {
    private var duration: Double
    private var elapsedAtAnchor: Double = 0
    private var anchor: Double?
    public init(duration: Double, now: Double) { self.duration = duration; anchor = now }
    public func remaining(now: Double) -> Double {
        max(0, duration - elapsed(now: now))
    }
    private func elapsed(now: Double) -> Double { elapsedAtAnchor + (anchor.map { max(0, now - $0) } ?? 0) }
    public mutating func pause(now: Double) {
        guard anchor != nil else { return }
        elapsedAtAnchor = elapsed(now: now); anchor = nil
    }
    public mutating func resume(now: Double) { if anchor == nil { anchor = now } }
    public mutating func updateDuration(_ duration: Double) { self.duration = duration }
}
