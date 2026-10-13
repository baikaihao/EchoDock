import ApplicationServices
import XCTest
@testable import EchoDock

final class ApplicationWindowMinimizeTests: XCTestCase {
    @MainActor
    func testRestoresExactlyTheRememberedWindow() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1, 2])
        let service = ApplicationWindowService(adapter: adapter)
        XCTAssertEqual(
            service.minimizePreferredWindow(processIdentifiers: [10]),
            .requested,
            "Minimize requested"
        )
        XCTAssertEqual(
            adapter.minimized[1],
            true,
            "First window minimized"
        )
        adapter.addProcess(10, windows: [2, 1], focused: 2)
        XCTAssertEqual(
            service.minimizePreferredWindow(processIdentifiers: [10]),
            .requested,
            "Duplicate minimize is idempotent"
        )
        XCTAssertEqual(
            adapter.minimizeCalls,
            [1],
            "Never minimize the second window in the same cycle"
        )
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .restored(processIdentifier: 10),
            "Restore succeeds"
        )
        XCTAssertEqual(
            adapter.restoreCalls,
            [1],
            "Restore the originally minimized window despite changed focus"
        )
        XCTAssertTrue(
            adapter.minimized[1] == false && adapter.minimized[2] == false,
            "Both windows restored"
        )
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .none,
            "Completed cycle forgets the window"
        )
    }

    @MainActor
    func testPermissionDenialDoesNothing() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1])
        adapter.isTrusted = false
        let service = ApplicationWindowService(adapter: adapter)
        XCTAssertEqual(
            service.minimizePreferredWindow(processIdentifiers: [10]),
            .permissionDenied,
            "Minimize requires permission"
        )
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .permissionDenied,
            "Restore requires permission"
        )
        XCTAssertEqual(
            service.reapplyLastMinimization(processIdentifiers: [10]),
            .permissionDenied,
            "Reapply requires permission"
        )
        XCTAssertTrue(
            adapter.minimizeCalls.isEmpty && adapter.restoreCalls.isEmpty,
            "Denied calls have no side effects"
        )
    }

    @MainActor
    func testModalBlocksTheUnderlyingDocument() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1])
        adapter.showModal(in: 10, document: 1)
        let service = ApplicationWindowService(adapter: adapter)
        XCTAssertEqual(
            service.minimizePreferredWindow(processIdentifiers: [10]),
            .noMinimizableWindow,
            "Modal blocks its document"
        )
        XCTAssertTrue(
            adapter.minimizeCalls.isEmpty,
            "Do not minimize behind modal"
        )
        adapter.addProcess(20, windows: [2])
        XCTAssertEqual(
            service.minimizePreferredWindow(processIdentifiers: [10, 20]),
            .requested,
            "Another process can still be used"
        )
        XCTAssertEqual(
            adapter.minimizeCalls,
            [2],
            "Only minimize the other regular instance"
        )
    }

    @MainActor
    func testUnsupportedWindowsAreSkipped() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1])
        adapter.minimizable = []
        let service = ApplicationWindowService(adapter: adapter)
        XCTAssertEqual(
            service.minimizePreferredWindow(processIdentifiers: [10]),
            .noMinimizableWindow,
            "Unsupported window is not minimized"
        )
        XCTAssertTrue(
            adapter.minimizeCalls.isEmpty,
            "No unsupported action"
        )
        XCTAssertEqual(
            service.reapplyLastMinimization(processIdentifiers: [10]),
            .noMinimizableWindow,
            "No reapply without a remembered window"
        )
    }

    @MainActor
    func testManualRestoreClearsTheRecord() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1, 2])
        let service = ApplicationWindowService(adapter: adapter)
        _ = service.minimizePreferredWindow(processIdentifiers: [10])
        adapter.minimized[1] = false
        adapter.minimized[2] = true
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .none,
            "Recognize a manual restore"
        )
        XCTAssertTrue(
            adapter.restoreCalls.isEmpty,
            "Do not restore the other minimized document"
        )
        XCTAssertEqual(
            service.reapplyLastMinimization(processIdentifiers: [10]),
            .noMinimizableWindow,
            "Manual restore clears the record"
        )
    }

    @MainActor
    func testInvalidWindowClearsTheRecord() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1, 2])
        let service = ApplicationWindowService(adapter: adapter)
        _ = service.minimizePreferredWindow(processIdentifiers: [10])
        adapter.minimized.removeValue(forKey: 1)
        adapter.minimized[2] = true
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .none,
            "Forget invalid AX object"
        )
        XCTAssertTrue(
            adapter.restoreCalls.isEmpty,
            "Do not restore a different valid object"
        )
        XCTAssertEqual(
            service.reapplyLastMinimization(processIdentifiers: [10]),
            .noMinimizableWindow,
            "Invalid object record removed"
        )
    }

    @MainActor
    func testFailedMinimizationDoesNotFallThrough() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1, 2])
        adapter.addProcess(20, windows: [3])
        adapter.minimizeResult = .failure
        let service = ApplicationWindowService(adapter: adapter)
        XCTAssertEqual(
            service.minimizePreferredWindow(processIdentifiers: [10, 20]),
            .failed,
            "Report action failure"
        )
        XCTAssertEqual(
            adapter.minimizeCalls,
            [1],
            "Failure must not minimize a second window or process"
        )
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10, 20]),
            .none,
            "Do not remember failed action"
        )
    }

    @MainActor
    func testUncertainMinimizationNeedsReadback() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1, 2])
        adapter.minimizeResult = .cannotComplete
        let service = ApplicationWindowService(adapter: adapter)
        XCTAssertEqual(
            service.minimizePreferredWindow(processIdentifiers: [10]),
            .failed,
            "Timeout without minimized readback fails"
        )
        XCTAssertEqual(
            adapter.minimizeCalls,
            [1],
            "Uncertain action is not retried"
        )
        adapter.applyMinimizeDespiteTimeout = true
        XCTAssertEqual(
            service.minimizePreferredWindow(processIdentifiers: [10]),
            .requested,
            "Minimized readback confirms timeout action"
        )
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .restored(processIdentifier: 10),
            "Confirmed window is remembered"
        )
    }

    @MainActor
    func testFailedRestoreCanBeRetriedOnTheSameWindow() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1, 2])
        let service = ApplicationWindowService(adapter: adapter)
        _ = service.minimizePreferredWindow(processIdentifiers: [10])
        adapter.restoreResult = .failure
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .failed,
            "Report restore failure"
        )
        adapter.restoreResult = .success
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .restored(processIdentifier: 10),
            "Retry still-valid remembered object"
        )
        XCTAssertEqual(
            adapter.restoreCalls,
            [1, 1],
            "Retry affects the same object only"
        )
    }

    @MainActor
    func testInvalidRestoreFailureClearsTheRecord() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1, 2])
        let service = ApplicationWindowService(adapter: adapter)
        _ = service.minimizePreferredWindow(processIdentifiers: [10])
        adapter.restoreResult = .failure
        adapter.invalidateOnRestoreFailure = true
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .failed,
            "Report invalidated action failure"
        )
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .none,
            "Invalid record discarded"
        )
        XCTAssertEqual(
            adapter.restoreCalls,
            [1],
            "No action on another window"
        )
    }

    @MainActor
    func testUncertainRestoreNeedsReadback() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1])
        let service = ApplicationWindowService(adapter: adapter)
        _ = service.minimizePreferredWindow(processIdentifiers: [10])
        adapter.restoreResult = .cannotComplete
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .failed,
            "Restore timeout without readback fails"
        )
        adapter.applyRestoreDespiteTimeout = true
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .restored(processIdentifier: 10),
            "Readback confirms restored state"
        )
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .none,
            "Confirmed restore clears the record"
        )
    }

    @MainActor
    func testMultipleProcessesRespectCallerOrder() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1])
        adapter.addProcess(20, windows: [2])
        let service = ApplicationWindowService(adapter: adapter)
        _ = service.minimizePreferredWindow(processIdentifiers: [10])
        _ = service.minimizePreferredWindow(processIdentifiers: [20])
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [20, 10]),
            .restored(processIdentifier: 20),
            "Restore prioritized process"
        )
        XCTAssertEqual(
            adapter.restoreCalls,
            [2],
            "Caller PID order wins"
        )
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [20, 10]),
            .restored(processIdentifier: 10),
            "Restore remaining remembered process next"
        )
        XCTAssertEqual(
            adapter.restoreCalls,
            [2, 1],
            "Both records remain independent"
        )
    }

    @MainActor
    func testStalePriorityRecordDoesNotRestoreAnotherProcess() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1])
        adapter.addProcess(20, windows: [2])
        let service = ApplicationWindowService(adapter: adapter)
        _ = service.minimizePreferredWindow(processIdentifiers: [10])
        _ = service.minimizePreferredWindow(processIdentifiers: [20])
        adapter.minimized[2] = false
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [20, 10]),
            .none,
            "Manual restore of prioritized PID stops this click"
        )
        XCTAssertTrue(
            adapter.restoreCalls.isEmpty,
            "Do not restore another process during stale-record cleanup"
        )
    }

    @MainActor
    func testReapplyUsesTheRememberedWindowOnly() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1, 2])
        let service = ApplicationWindowService(adapter: adapter)
        _ = service.minimizePreferredWindow(processIdentifiers: [10])
        XCTAssertEqual(
            service.reapplyLastMinimization(processIdentifiers: [10]),
            .requested,
            "Already minimized is an idempotent success"
        )
        XCTAssertEqual(
            adapter.minimizeCalls,
            [1],
            "No duplicate press while minimized"
        )
        adapter.minimized[1] = false
        adapter.addProcess(10, windows: [2, 1], focused: 2)
        XCTAssertEqual(
            service.reapplyLastMinimization(processIdentifiers: [10]),
            .requested,
            "Reapply after delayed application reopen"
        )
        XCTAssertEqual(
            adapter.minimizeCalls,
            [1, 1],
            "Reapply original window despite changed focus"
        )
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .restored(processIdentifier: 10),
            "Restore still targets original window"
        )
        XCTAssertEqual(
            service.reapplyLastMinimization(processIdentifiers: [10]),
            .noMinimizableWindow,
            "Late callback cannot undo a completed restore"
        )
    }

    @MainActor
    func testReapplyCannotBypassAModal() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1])
        let service = ApplicationWindowService(adapter: adapter)
        _ = service.minimizePreferredWindow(processIdentifiers: [10])
        adapter.minimized[1] = false
        adapter.showModal(in: 10, document: 1)
        XCTAssertEqual(
            service.reapplyLastMinimization(processIdentifiers: [10]),
            .failed,
            "Do not reapply behind a new modal"
        )
        XCTAssertEqual(
            adapter.minimizeCalls,
            [1],
            "Modal prevents another button press"
        )
    }

    @MainActor
    func testRestoreCannotBypassAModal() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1])
        let service = ApplicationWindowService(adapter: adapter)
        _ = service.minimizePreferredWindow(processIdentifiers: [10])
        adapter.showModal(in: 10, document: 1)
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .failed,
            "Do not restore through a modal"
        )
        XCTAssertTrue(
            adapter.restoreCalls.isEmpty,
            "No AX restore through modal"
        )
    }

    @MainActor
    func testReapplyInvalidWindowDoesNotFallThrough() {
        let adapter = MinimizeWindowAdapter()
        adapter.addProcess(10, windows: [1, 2])
        let service = ApplicationWindowService(adapter: adapter)
        _ = service.minimizePreferredWindow(processIdentifiers: [10])
        adapter.minimized.removeValue(forKey: 1)
        XCTAssertEqual(
            service.reapplyLastMinimization(processIdentifiers: [10]),
            .noMinimizableWindow,
            "Invalid remembered object cannot be reapplied"
        )
        XCTAssertEqual(
            adapter.minimizeCalls,
            [1],
            "Do not minimize another document"
        )
        XCTAssertEqual(
            service.restoreLastMinimizedWindow(processIdentifiers: [10]),
            .none,
            "Invalid reapply clears record"
        )
    }
}

private final class MinimizeWindowAdapter: ApplicationWindowAccessibilityAdapting {
    typealias Window = Int

    var isTrusted = true
    var inventories: [pid_t: ApplicationWindowInventory<Int>] = [:]
    var minimizable: Set<Int> = []
    var minimized: [Int: Bool] = [:]
    var minimizeResult: ApplicationWindowPressResult = .success
    var restoreResult: ApplicationWindowPressResult = .success
    var applyMinimizeDespiteTimeout = false
    var applyRestoreDespiteTimeout = false
    var invalidateOnRestoreFailure = false
    var minimizeCalls: [Int] = []
    var restoreCalls: [Int] = []

    func inventory(for processIdentifier: pid_t) -> ApplicationWindowInventory<Int>? {
        inventories[processIdentifier]
    }
    func isClosable(_ window: Int) -> Bool { false }
    func pressClose(_ window: Int) -> ApplicationWindowPressResult { .failure }
    func isMinimizable(_ window: Int) -> Bool {
        minimizable.contains(window) && minimized[window] == false
    }
    func isMinimized(_ window: Int) -> Bool? { minimized[window] }
    func pressMinimize(_ window: Int) -> ApplicationWindowPressResult {
        minimizeCalls.append(window)
        switch minimizeResult {
        case .success: minimized[window] = true
        case .cannotComplete:
            if applyMinimizeDespiteTimeout { minimized[window] = true }
        case .failure: break
        }
        return minimizeResult
    }
    func restore(_ window: Int) -> ApplicationWindowPressResult {
        restoreCalls.append(window)
        switch restoreResult {
        case .success: minimized[window] = false
        case .cannotComplete:
            if applyRestoreDespiteTimeout { minimized[window] = false }
        case .failure:
            if invalidateOnRestoreFailure { minimized.removeValue(forKey: window) }
        }
        return restoreResult
    }

    func addProcess(_ pid: pid_t, windows: [Int], focused: Int? = nil) {
        inventories[pid] = ApplicationWindowInventory(
            focusedTopLevelElement: focused ?? windows.first,
            focusedWindow: focused ?? windows.first,
            mainWindow: windows.first,
            orderedWindows: windows
        )
        minimizable.formUnion(windows)
        for window in windows where minimized[window] == nil { minimized[window] = false }
    }

    func showModal(in pid: pid_t, document: Int) {
        inventories[pid] = ApplicationWindowInventory(
            focusedTopLevelElement: 999,
            focusedTopLevelElementBlocksFallback: true,
            focusedWindow: document,
            mainWindow: document,
            orderedWindows: [document]
        )
    }
}
