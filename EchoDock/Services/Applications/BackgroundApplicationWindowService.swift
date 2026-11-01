import AppKit
import ApplicationServices

@MainActor
final class BackgroundApplicationWindowService<Adapter: ApplicationWindowAccessibilityAdapting>: ApplicationWindowControlling {
    private let worker: AccessibilityWorkQueue<ApplicationWindowService<Adapter>>
    private let permissionCheck: () -> Bool
    private let budget: AccessibilityOperationBudget?
    private var closeCache: [[pid_t]: (value: Bool, time: TimeInterval)] = [:]
    private var pendingQuery: [pid_t]?

    init(
        backend: ApplicationWindowService<Adapter>,
        permissionCheck: @escaping () -> Bool,
        budget: AccessibilityOperationBudget? = nil
    ) {
        worker = AccessibilityWorkQueue(backend: backend, name: "com.baikaihao.EchoDock.application-windows")
        self.permissionCheck = permissionCheck
        self.budget = budget
    }

    var hasAccessibilityPermission: Bool { permissionCheck() }

    func canCloseWindow(processIdentifiers: [pid_t]) -> Bool {
        guard hasAccessibilityPermission, !processIdentifiers.isEmpty else { return false }
        let cached = closeCache[processIdentifiers]
        if cached == nil || ProcessInfo.processInfo.systemUptime - (cached?.time ?? 0) >= 2 {
            if pendingQuery != processIdentifiers {
                pendingQuery = processIdentifiers
                let budget = budget
                worker.submit(key: "query", priority: .low, work: { backend, isCurrent in
                    budget?.begin(duration: 0.6, isCurrent: isCurrent)
                    return backend.canCloseWindow(processIdentifiers: processIdentifiers)
                }) { [weak self] value in
                    guard let self else { return }
                    self.pendingQuery = nil
                    if self.closeCache.count >= 64 { self.closeCache.removeAll() }
                    self.closeCache[processIdentifiers] = (value, ProcessInfo.processInfo.systemUptime)
                    NotificationCenter.default.post(name: .echoDockApplicationWindowStateDidChange, object: self)
                }
            }
        }
        return cached?.value ?? false
    }

    func closePreferredWindow(processIdentifiers: [pid_t], completion: @escaping @MainActor (ApplicationWindowCloseResult) -> Void) {
        submit({ $0.closePreferredWindow(processIdentifiers: processIdentifiers) }, completion: completion)
    }

    func minimizePreferredWindow(processIdentifiers: [pid_t], completion: @escaping @MainActor (ApplicationWindowMinimizeResult) -> Void) {
        submit({ $0.minimizePreferredWindow(processIdentifiers: processIdentifiers) }, completion: completion)
    }

    func restoreLastMinimizedWindow(processIdentifiers: [pid_t], completion: @escaping @MainActor (ApplicationWindowRestoreResult) -> Void) {
        submit({ $0.restoreLastMinimizedWindow(processIdentifiers: processIdentifiers) }, completion: completion)
    }

    func reapplyLastMinimization(processIdentifiers: [pid_t], completion: @escaping @MainActor (ApplicationWindowMinimizeResult) -> Void) {
        submit({ $0.reapplyLastMinimization(processIdentifiers: processIdentifiers) }, completion: completion)
    }

    func invalidatePendingOperations() {
        worker.cancelAll()
        pendingQuery = nil
        closeCache.removeAll()
    }

    private func submit<Value>(
        _ work: @escaping (ApplicationWindowService<Adapter>) -> Value,
        completion: @escaping @MainActor (Value) -> Void
    ) {
        let budget = budget
        worker.submit(key: "action", priority: .veryHigh, work: { backend, isCurrent in
            budget?.begin(duration: 1.5, isCurrent: isCurrent)
            return work(backend)
        }) { [weak self] result in
            self?.closeCache.removeAll()
            completion(result)
        }
    }
}

extension BackgroundApplicationWindowService where Adapter == SystemApplicationWindowAccessibilityAdapter {
    static func system() -> BackgroundApplicationWindowService {
        let budget = AccessibilityOperationBudget()
        return BackgroundApplicationWindowService(
            backend: SystemApplicationWindowService(adapter: SystemApplicationWindowAccessibilityAdapter(budget: budget)),
            permissionCheck: { AXIsProcessTrusted() },
            budget: budget
        )
    }
}
