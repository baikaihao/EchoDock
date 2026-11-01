import AppKit
import Testing
@testable import EchoDock

@MainActor
struct BackgroundApplicationWindowServiceTests {
    @Test
    func menuQueriesReturnImmediatelyAndRefreshTheCacheOffMain() async throws {
        let service = BackgroundApplicationWindowService(
            backend: ApplicationWindowService(adapter: DelayedAccessibilityAdapter()), permissionCheck: { true }
        )
        defer { service.invalidatePendingOperations() }
        let start = ContinuousClock.now
        #expect(!service.canCloseWindow(processIdentifiers: [42]))
        #expect(start.duration(to: .now) < .milliseconds(80))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var ready = false
        while !ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            ready = service.canCloseWindow(processIdentifiers: [42])
        }
        #expect(ready)
    }

    @Test
    func windowActionsValidateOnTheWorkerAndCompleteOnMain() async throws {
        let service = BackgroundApplicationWindowService(
            backend: ApplicationWindowService(adapter: DelayedAccessibilityAdapter()), permissionCheck: { true }
        )
        defer { service.invalidatePendingOperations() }
        var result: ApplicationWindowCloseResult?
        service.closePreferredWindow(processIdentifiers: [42]) {
            #expect(Thread.isMainThread)
            result = $0
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while result == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(result == .requested)
    }
}

private final class DelayedAccessibilityAdapter: ApplicationWindowAccessibilityAdapting {
    typealias Window = Int
    var isTrusted: Bool { true }
    func inventory(for processIdentifier: pid_t) -> ApplicationWindowInventory<Int>? {
        precondition(!Thread.isMainThread)
        Thread.sleep(forTimeInterval: 0.12)
        return ApplicationWindowInventory(focusedTopLevelElement: 1, focusedWindow: 1, mainWindow: 1, orderedWindows: [1])
    }
    func isClosable(_ window: Int) -> Bool { true }
    func pressClose(_ window: Int) -> ApplicationWindowPressResult { .success }
    func isMinimizable(_ window: Int) -> Bool { true }
    func isMinimized(_ window: Int) -> Bool? { false }
    func pressMinimize(_ window: Int) -> ApplicationWindowPressResult { .success }
    func restore(_ window: Int) -> ApplicationWindowPressResult { .success }
}
