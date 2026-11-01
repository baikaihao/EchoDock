import Foundation

/// AXObserver needs a live run loop, rather than an arbitrary dispatch thread.
/// Submitted work and observer callbacks all execute on this one background thread.
final class AccessibilityRunLoop {
    private final class State {
        let lock = NSLock()
        var runLoop: CFRunLoop?
        var pending: [() -> Void] = []
        var isStopped = false
    }

    private let state = State()
    private let delayedQueue = DispatchQueue(label: "com.baikaihao.EchoDock.reservation-delays", qos: .utility)

    init() {
        let state = state
        let thread = Thread {
            let runLoop = CFRunLoopGetCurrent()!
            var context = CFRunLoopSourceContext()
            context.perform = { _ in }
            let source = CFRunLoopSourceCreate(nil, 0, &context)!
            CFRunLoopAddSource(runLoop, source, .commonModes)
            state.lock.lock()
            state.runLoop = runLoop
            let pending = state.pending
            state.pending.removeAll()
            state.lock.unlock()
            pending.forEach { CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, $0) }
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            state.lock.lock()
            state.runLoop = nil
            state.isStopped = true
            state.lock.unlock()
        }
        thread.name = "EchoDock Window Reservation AX"
        thread.qualityOfService = .utility
        thread.start()
    }

    func perform(_ work: @escaping () -> Void) {
        state.lock.lock()
        guard !state.isStopped else { state.lock.unlock(); return }
        guard let runLoop = state.runLoop else {
            state.pending.append(work)
            state.lock.unlock()
            return
        }
        state.lock.unlock()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    func asyncAfter(deadline: DispatchTime, execute work: @escaping () -> Void) {
        delayedQueue.asyncAfter(deadline: deadline) { [weak self] in self?.perform(work) }
    }

    func asyncAfter(deadline: DispatchTime, execute work: DispatchWorkItem) {
        asyncAfter(deadline: deadline) { if !work.isCancelled { work.perform() } }
    }

    func finish(_ cleanup: @escaping () -> Void) {
        perform { [state] in
            cleanup()
            state.lock.lock()
            state.isStopped = true
            state.pending.removeAll()
            state.lock.unlock()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}
