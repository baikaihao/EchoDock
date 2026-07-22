import AppKit

@MainActor
final class MouseEdgeMonitor: NSObject {
    var onSample: ((CGPoint, Int, Date) -> Void)?
    var needsImmediateMovementSample: (() -> Bool)?

    private var timer: Timer?
    private var globalMovementMonitor: Any?
    private var localMovementMonitor: Any?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(
            timeInterval: 0.05,
            target: self,
            selector: #selector(sampleMouse),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        globalMovementMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .mouseMoved
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleMovementIfNeeded()
            }
        }
        localMovementMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .mouseMoved
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.sampleMovementIfNeeded()
            }
            return event
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        removeMovementMonitors()
    }

    deinit {
        timer?.invalidate()
        if let globalMovementMonitor {
            NSEvent.removeMonitor(globalMovementMonitor)
        }
        if let localMovementMonitor {
            NSEvent.removeMonitor(localMovementMonitor)
        }
    }

    @objc private func sampleMouse() {
        onSample?(NSEvent.mouseLocation, NSEvent.pressedMouseButtons, Date())
    }

    private func sampleMovementIfNeeded() {
        guard needsImmediateMovementSample?() == true else { return }
        sampleMouse()
    }

    private func removeMovementMonitors() {
        if let globalMovementMonitor {
            NSEvent.removeMonitor(globalMovementMonitor)
            self.globalMovementMonitor = nil
        }
        if let localMovementMonitor {
            NSEvent.removeMonitor(localMovementMonitor)
            self.localMovementMonitor = nil
        }
    }
}
