import Foundation

/// The backend is confined to this serial queue. Only value results return to
/// the main actor; AX elements and remembered windows never cross that boundary.
@MainActor
final class AccessibilityWorkQueue<Backend> {
    private let backend: Backend
    private let queue: OperationQueue
    private var requests: [String: BlockOperation] = [:]

    init(backend: Backend, name: String) {
        self.backend = backend
        queue = OperationQueue()
        queue.name = name
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
    }

    func contains(_ key: String) -> Bool { requests[key] != nil }

    func submit<Value>(
        key: String,
        priority: Operation.QueuePriority = .normal,
        work: @escaping (Backend, @escaping () -> Bool) -> Value,
        completion: @escaping @MainActor (Value) -> Void
    ) {
        requests.removeValue(forKey: key)?.cancel()
        let operation = BlockOperation()
        let backend = backend
        operation.queuePriority = priority
        operation.addExecutionBlock { [weak operation, weak self] in
            guard let operation, !operation.isCancelled else { return }
            let result = work(backend, { [weak operation] in operation?.isCancelled == false })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requests[key] === operation, !operation.isCancelled else { return }
                self.requests.removeValue(forKey: key)
                completion(result)
            }
        }
        requests[key] = operation
        queue.addOperation(operation)
    }

    func cancelAll() {
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        queue.cancelAllOperations()
    }
}

/// Queue-confined budget shared by one backend's synchronous AX helpers.
final class AccessibilityOperationBudget {
    private var deadline: TimeInterval = .infinity
    private var isCurrent: () -> Bool = { true }

    func begin(duration: TimeInterval, isCurrent: @escaping () -> Bool) {
        deadline = ProcessInfo.processInfo.systemUptime + duration
        self.isCurrent = isCurrent
    }

    var remaining: TimeInterval {
        isCurrent() ? max(0, deadline - ProcessInfo.processInfo.systemUptime) : 0
    }

    var canContinue: Bool { remaining > 0 }
}
