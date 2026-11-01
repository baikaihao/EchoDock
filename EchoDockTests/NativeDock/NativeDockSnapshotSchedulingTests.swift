import AppKit
import Testing
@testable import EchoDock

@MainActor
struct NativeDockSnapshotSchedulingTests {
    private let displays = [NativeDockLockDisplayGeometry(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1_440, height: 900), isMirrorSecondary: false)]

    @Test
    func aSlowSnapshotRunsOffMainAndUpdatesTheCachedDisplayAsynchronously() async throws {
        let service = NativeDockLockService(windowSnapshotProvider: { _ in
            precondition(!Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.12)
            return NativeDockWindowSnapshot(dockLists: [NativeDockWindowGeometry(frame: CGRect(x: 400, y: 840, width: 600, height: 60))], windows: [])
        }, isAccessibilityGranted: { true })
        defer { service.stop() }
        let start = ContinuousClock.now
        #expect(service.refreshCurrentDockDisplay(displays: displays, edge: .bottom) == nil)
        #expect(start.duration(to: .now) < .milliseconds(80))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.currentDockDisplayID == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(service.currentDockDisplayID == 1)
    }

    @Test
    func stoppingBeforeTheSnapshotReturnsDiscardsItsResult() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let service = NativeDockLockService(windowSnapshotProvider: { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return NativeDockWindowSnapshot(dockLists: [NativeDockWindowGeometry(frame: CGRect(x: 400, y: 840, width: 600, height: 60))], windows: [])
        }, isAccessibilityGranted: { true })
        defer { release.signal() }
        service.refreshCurrentDockDisplay(displays: displays, edge: .bottom)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while entered.wait(timeout: .now()) != .success, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        service.stop()
        release.signal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(service.currentDockDisplayID == nil)
    }
}
