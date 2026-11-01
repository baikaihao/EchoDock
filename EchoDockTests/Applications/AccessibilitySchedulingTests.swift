import AppKit
import Testing
@testable import EchoDock

@MainActor
struct AccessibilitySchedulingTests {
    @Test
    func aBlockedWorkerDoesNotBlockTheMainActorAndAnObsoleteResultIsDiscarded() async throws {
        let worker = AccessibilityWorkQueue(backend: 0, name: "AccessibilitySchedulingTests")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); worker.cancelAll() }
        var values: [Int] = []
        worker.submit(key: "query", work: { _, _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return 1
        }) { values.append($0) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while entered.wait(timeout: .now()) != .success, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        // This main-actor turn is reached while the background request waits.
        worker.submit(key: "query", work: { _, _ in 2 }) { values.append($0) }
        release.signal()
        while values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(values == [2])
    }

    @Test
    func stoppingCancelsAlreadyRunningCallbacks() async throws {
        let worker = AccessibilityWorkQueue(backend: 0, name: "AccessibilitySchedulingStopTests")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var didComplete = false
        worker.submit(key: "action", work: { _, _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return 1
        }) { _ in didComplete = true }
        defer { release.signal() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while entered.wait(timeout: .now()) != .success, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        worker.cancelAll()
        release.signal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!didComplete)
    }

    @Test
    func observerRunLoopRunsSeriallyOffMainAndFinishesCleanupBeforeCompletion() async throws {
        let executor = AccessibilityRunLoop()
        var values: [Int] = []
        var wasMain = false
        var finished = false
        for value in 0..<3 {
            executor.perform {
                let isMain = Thread.isMainThread
                DispatchQueue.main.async { values.append(value); wasMain = wasMain || isMain }
            }
        }
        executor.finish { DispatchQueue.main.async { finished = true } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(finished)
        #expect(values == [0, 1, 2])
        #expect(!wasMain)
    }

    @Test
    func reservationInputsAndStopCompletionStayOnTheMainActor() async throws {
        var inputWasMain = true
        let service = WindowReservationService(
            permissionService: AccessibilityPermissionService(trustCheck: { false }),
            isReservationEnabled: { false }, isDockEnabled: { true }, isAutoHide: { false },
            isDisplayEnabled: { _ in true }, reservationHeightProvider: { _ in 72 },
            snapRegionsProvider: { inputWasMain = inputWasMain && Thread.isMainThread; return [] }
        )
        service.start()
        service.reconcile(refreshAllWindows: true)
        var stopped = false
        service.stop { stopped = Thread.isMainThread }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !stopped, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(inputWasMain)
        #expect(stopped)
    }

    @Test
    func changingReservationInputsInvalidatesAnExistingMutationVersion() {
        let context = WindowReservationContext()
        var value = WindowReservationInput(isConfigured: true)
        context.update(value)
        let first = context.current.revision
        context.update(value)
        #expect(context.current.revision == first)
        value.isConfigured = false
        context.update(value)
        #expect(context.current.revision != first)
    }
}
