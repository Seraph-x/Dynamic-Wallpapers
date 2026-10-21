import XCTest

/// FIFO suspension point for async tests. Each release opens exactly one waiter.
actor AsyncTestGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var permits = 0
    private var waiters: [Waiter] = []
    private var arrivals = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var departures = 0
    private var departureWaiters: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { waiters.count }

    func pause() async throws {
        if arrivalWaiters.isEmpty {
            arrivals += 1
        } else {
            arrivalWaiters.removeFirst().resume()
        }
        let id = UUID()
        let released = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if permits > 0 {
                    permits -= 1
                    continuation.resume(returning: true)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        guard released else { throw CancellationError() }
        try Task.checkCancellation()
        if departureWaiters.isEmpty {
            departures += 1
        } else {
            departureWaiters.removeFirst().resume()
        }
    }

    func waitForArrival() async {
        if arrivals > 0 {
            arrivals -= 1
        } else {
            await withCheckedContinuation { arrivalWaiters.append($0) }
        }
    }

    func waitForDeparture() async {
        if departures > 0 {
            departures -= 1
        } else {
            await withCheckedContinuation { departureWaiters.append($0) }
        }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

}

@MainActor
final class AsyncTestGateTests: XCTestCase {
    func testEachReleaseResumesExactlyOneWaiter() async throws {
        let gate = AsyncTestGate()
        let first = Task { try await gate.pause() }
        let second = Task { try await gate.pause() }
        await gate.waitForArrival()
        await gate.waitForArrival()

        await gate.release()
        await gate.waitForDeparture()
        let afterFirstRelease = await gate.waitingCount
        XCTAssertEqual(afterFirstRelease, 1)

        await gate.release()
        try await first.value
        try await second.value
        let afterSecondRelease = await gate.waitingCount
        XCTAssertEqual(afterSecondRelease, 0)
    }

    func testCancellationIsObservedAndRemovesTheWaiter() async throws {
        let gate = AsyncTestGate()
        let waiting = Task { try await gate.pause() }
        await gate.waitForArrival()
        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("A cancelled gate waiter must not continue")
        } catch is CancellationError { }
        let remaining = await gate.waitingCount
        XCTAssertEqual(remaining, 0)
    }

    func testWaiterCannotContinueBeforeItsCallbackArrivesAndIsReleased() async throws {
        let gate = AsyncTestGate()
        let witness = AsyncGateWitness()
        let waiting = Task {
            try await gate.pause()
            await witness.markContinued()
        }
        await gate.waitForArrival()
        let beforeRelease = await witness.continued
        XCTAssertFalse(beforeRelease)
        await gate.release()
        try await waiting.value
        let afterRelease = await witness.continued
        XCTAssertTrue(afterRelease)
    }
}

private actor AsyncGateWitness {
    private(set) var continued = false
    func markContinued() { continued = true }
}
