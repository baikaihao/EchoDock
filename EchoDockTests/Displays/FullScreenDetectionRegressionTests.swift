import AppKit
import Testing
@testable import EchoDock

struct FullScreenDetectionRegressionTests {
    private let display = FullScreenDisplayGeometry(
        displayID: 1,
        bounds: CGRect(x: 0, y: 0, width: 1_512, height: 982),
        topSafeAreaInset: 38
    )

    @Test
    func chromeNativeFullScreenCanLeaveSpaceAboveItsContentWindow() {
        let window = makeWindow(
            bounds: CGRect(x: 0, y: 90, width: 1_512, height: 892),
            nativeFullScreen: true
        )
        #expect(detect([window]) == [1])
    }

    @Test
    func notchedScreenHasGeometryFallbackWithoutAccessibilityPermission() {
        #expect(detect([makeWindow(bounds: CGRect(x: 0, y: 38, width: 1_512, height: 944))]) == [1])
    }

    @Test
    func explicitlyWindowedMaximizedWindowDoesNotMatchNotchFallback() {
        let window = makeWindow(
            bounds: CGRect(x: 0, y: 38, width: 1_512, height: 944),
            nativeFullScreen: false
        )
        #expect(detect([window]).isEmpty)
    }

    @Test
    func maximizedWindowAboveTheDockDoesNotCountAsFullScreen() {
        #expect(detect([makeWindow(bounds: CGRect(x: 0, y: 38, width: 1_512, height: 870))]).isEmpty)
    }

    @Test
    func splitViewCanCoverTheAreaBelowTheNotch() {
        #expect(detect([
            makeWindow(bounds: CGRect(x: 0, y: 38, width: 750, height: 944)),
            makeWindow(bounds: CGRect(x: 762, y: 38, width: 750, height: 944))
        ]) == [1])
    }

    @Test
    func nativeFullScreenBelongsOnlyToItsOwnDisplay() {
        let left = FullScreenDisplayGeometry(
            displayID: 2,
            bounds: CGRect(x: -1_280, y: -200, width: 1_280, height: 800)
        )
        let window = makeWindow(
            bounds: CGRect(x: -1_280, y: -176, width: 1_280, height: 776),
            nativeFullScreen: true
        )
        #expect(FullScreenWindowPolicy.fullScreenDisplayIDs(
            displays: [display, left], windows: [window], excludingProcessIdentifier: 42
        ) == [2])
    }

    @Test
    func nativeFullScreenOnAnotherSpaceIsIgnored() {
        let window = FullScreenWindowSnapshot(
            bounds: display.bounds, layer: 0, ownerProcessIdentifier: 100,
            isRegularApplication: true, alpha: 1, isOnScreen: false,
            isNativeFullScreen: true
        )
        #expect(detect([window]).isEmpty)
    }

    @Test
    func invalidWindowGeometryCannotSuppressADisplay() {
        let invalid = CGRect(x: CGFloat.nan, y: 0, width: 1_512, height: 982)
        #expect(detect([makeWindow(bounds: invalid, nativeFullScreen: true)]).isEmpty)
    }

    private func detect(_ windows: [FullScreenWindowSnapshot]) -> Set<CGDirectDisplayID> {
        FullScreenWindowPolicy.fullScreenDisplayIDs(
            displays: [display], windows: windows, excludingProcessIdentifier: 42
        )
    }
}

@MainActor
struct FullScreenDisplayMonitorTests {
    private let display = FullScreenDisplayGeometry(
        displayID: 1,
        bounds: CGRect(x: 0, y: 0, width: 1_440, height: 900)
    )

    @Test
    func rechecksAfterAnEarlySpaceNotification() async throws {
        let center = NotificationCenter()
        let source = FullScreenSnapshotSource(sequence: [[]])
        let monitor = FullScreenDisplayMonitor(
            workspaceNotificationCenter: center,
            refreshInterval: 60,
            windowSnapshotProvider: { _ in source.read() }
        )
        var changes: [Set<CGDirectDisplayID>] = []
        monitor.onFullScreenDisplaysChange = { changes.append($0) }
        monitor.updateDisplayGeometries([display])
        monitor.start()
        defer { monitor.stop() }
        #expect(try await eventually { source.readCount >= 1 })

        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // The final geometry arrives after the old implementation's only check.
        try await Task.sleep(for: .milliseconds(300))
        source.replaceSequence([[makeWindow(bounds: display.bounds)]])
        #expect(try await eventually { changes == [[1]] })
        #expect(!source.wasReadOnMainThread)
    }

    @Test
    func detectsBorderlessFullScreenWithoutAnySpaceChange() async throws {
        let source = FullScreenSnapshotSource(sequence: [[]])
        let monitor = makeMonitor(source: source)
        var changes: [Set<CGDirectDisplayID>] = []
        monitor.onFullScreenDisplaysChange = { changes.append($0) }
        monitor.updateDisplayGeometries([display])
        monitor.start()
        defer { monitor.stop() }
        // Let the startup transition rechecks finish before changing the window.
        try await Task.sleep(for: .milliseconds(1_500))
        source.replaceSequence([[makeWindow(bounds: display.bounds)]])
        #expect(try await eventually { changes == [[1]] })
    }

    @Test
    func transientMissingAndFailedSnapshotsDoNotFlashTheDock() async throws {
        let fullScreen = [makeWindow(bounds: display.bounds)]
        let source = FullScreenSnapshotSource(sequence: [fullScreen, [], nil, fullScreen, [], []])
        let monitor = makeMonitor(source: source)
        var changes: [Set<CGDirectDisplayID>] = []
        monitor.onFullScreenDisplaysChange = { changes.append($0) }
        monitor.updateDisplayGeometries([display])
        monitor.start()
        defer { monitor.stop() }
        #expect(try await eventually { changes == [[1], []] })
        #expect(source.readCount >= 6)
    }

    @Test
    func failedSnapshotsKeepTheLastKnownFullScreenState() async throws {
        let source = FullScreenSnapshotSource(sequence: [[makeWindow(bounds: display.bounds)], nil])
        let monitor = makeMonitor(source: source)
        var changes: [Set<CGDirectDisplayID>] = []
        monitor.onFullScreenDisplaysChange = { changes.append($0) }
        monitor.updateDisplayGeometries([display])
        monitor.start()
        defer { monitor.stop() }
        #expect(try await eventually { source.readCount >= 4 })
        #expect(changes == [[1]])
    }

    @Test(arguments: [false, true])
    func inFlightSnapshotCannotRestoreOldDisplayState(restart: Bool) async throws {
        let gate = DispatchSemaphore(value: 0)
        let source = FullScreenSnapshotSource(
            sequence: [[makeWindow(bounds: display.bounds)]], firstReadGate: gate
        )
        let monitor = makeMonitor(source: source)
        var changes: [Set<CGDirectDisplayID>] = []
        monitor.onFullScreenDisplaysChange = { changes.append($0) }
        monitor.updateDisplayGeometries([display])
        monitor.start()
        defer { gate.signal(); monitor.stop() }
        #expect(try await eventually { source.readCount == 1 })

        let replacement = FullScreenDisplayGeometry(
            displayID: 2, bounds: CGRect(x: -1_280, y: 100, width: 1_280, height: 800)
        )
        if restart { monitor.stop() }
        source.replaceSequence([[makeWindow(bounds: replacement.bounds)]])
        monitor.updateDisplayGeometries([replacement])
        if restart { monitor.start() }
        gate.signal()

        #expect(try await eventually { changes == [[2]] })
        #expect(!source.wasReadOnMainThread)
    }

    @Test
    func spaceSwitchDiscardsASnapshotCapturedInThePreviousSpace() async throws {
        let gate = DispatchSemaphore(value: 0)
        let center = NotificationCenter()
        let source = FullScreenSnapshotSource(
            sequence: [[makeWindow(bounds: display.bounds)]], firstReadGate: gate
        )
        let monitor = FullScreenDisplayMonitor(
            workspaceNotificationCenter: center,
            refreshInterval: 60,
            windowSnapshotProvider: { _ in source.read() }
        )
        var changes: [Set<CGDirectDisplayID>] = []
        monitor.onFullScreenDisplaysChange = { changes.append($0) }
        monitor.updateDisplayGeometries([display])
        monitor.start()
        defer { gate.signal(); monitor.stop() }
        #expect(try await eventually { source.readCount == 1 })
        source.replaceSequence([[]])
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        gate.signal()
        #expect(try await eventually { source.readCount >= 2 })
        try await Task.sleep(for: .milliseconds(20))
        #expect(changes.isEmpty)
    }

    @Test
    func stopDiscardsInFlightResultsAndCancelsScheduledChecks() async throws {
        let gate = DispatchSemaphore(value: 0)
        let source = FullScreenSnapshotSource(
            sequence: [[makeWindow(bounds: display.bounds)]], firstReadGate: gate
        )
        let monitor = makeMonitor(source: source)
        var changes: [Set<CGDirectDisplayID>] = []
        monitor.onFullScreenDisplaysChange = { changes.append($0) }
        monitor.updateDisplayGeometries([display])
        monitor.start()
        defer { gate.signal(); monitor.stop() }
        #expect(try await eventually { source.readCount == 1 })
        monitor.stop()
        gate.signal()
        try await Task.sleep(for: .milliseconds(200))
        #expect(changes.isEmpty)
        #expect(source.readCount == 1)
    }

    @Test
    func removingAllDisplaysClearsFullScreenStateWithoutAnotherSnapshot() async throws {
        let source = FullScreenSnapshotSource(sequence: [[makeWindow(bounds: display.bounds)]])
        let monitor = makeMonitor(source: source)
        var changes: [Set<CGDirectDisplayID>] = []
        monitor.onFullScreenDisplaysChange = { changes.append($0) }
        monitor.updateDisplayGeometries([display])
        monitor.start()
        defer { monitor.stop() }
        #expect(try await eventually { changes == [[1]] })
        monitor.updateDisplayGeometries([])
        #expect(changes == [[1], []])
    }

    private func makeMonitor(source: FullScreenSnapshotSource) -> FullScreenDisplayMonitor {
        FullScreenDisplayMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            refreshInterval: 0.03,
            windowSnapshotProvider: { _ in source.read() }
        )
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private func makeWindow(bounds: CGRect, nativeFullScreen: Bool? = nil) -> FullScreenWindowSnapshot {
    FullScreenWindowSnapshot(
        bounds: bounds, layer: 0, ownerProcessIdentifier: 100,
        isRegularApplication: true, alpha: 1, isOnScreen: true,
        isNativeFullScreen: nativeFullScreen
    )
}

// The provider runs on the snapshot queue; tests inspect and replace it on main.
// Every mutable property is protected by the lock.
private final class FullScreenSnapshotSource: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: [[FullScreenWindowSnapshot]?]
    private var sequenceIndex = 0
    private var count = 0
    private var readOnMainThread = false
    private let firstReadGate: DispatchSemaphore?

    init(sequence: [[FullScreenWindowSnapshot]?], firstReadGate: DispatchSemaphore? = nil) {
        self.sequence = sequence
        self.firstReadGate = firstReadGate
    }

    var readCount: Int { lock.withLock { count } }
    var wasReadOnMainThread: Bool { lock.withLock { readOnMainThread } }

    func read() -> [FullScreenWindowSnapshot]? {
        let (snapshot, isFirst) = lock.withLock {
            let snapshot = sequence[min(sequenceIndex, sequence.count - 1)]
            sequenceIndex += 1
            count += 1
            readOnMainThread = readOnMainThread || Thread.isMainThread
            return (snapshot, count == 1)
        }
        if isFirst { firstReadGate?.wait() }
        return snapshot
    }

    func replaceSequence(_ next: [[FullScreenWindowSnapshot]?]) {
        lock.withLock {
            sequence = next
            sequenceIndex = 0
        }
    }
}
