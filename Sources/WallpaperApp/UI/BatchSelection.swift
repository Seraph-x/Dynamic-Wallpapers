import Foundation

struct BatchSelection: Equatable {
    private(set) var isActive = false
    private(set) var ids = Set<UUID>()

    mutating func start() { isActive = true; ids.removeAll() }
    mutating func finish() { isActive = false; ids.removeAll() }
    mutating func clear() { ids.removeAll() }
    mutating func toggle(_ id: UUID) {
        guard isActive else { return }
        if !ids.insert(id).inserted { ids.remove(id) }
    }
    mutating func selectAll(_ visible: Set<UUID>) { if isActive { ids = visible } }
    mutating func retain(_ visible: Set<UUID>) { ids.formIntersection(visible) }
}
