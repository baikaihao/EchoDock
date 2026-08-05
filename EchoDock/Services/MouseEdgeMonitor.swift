import AppKit

@MainActor
final class MouseEdgeMonitor: NSObject {
    var onSample: ((CGPoint, Int, Date, Bool) -> Void)?

    private var timer: Timer?
    private var globalMovementMonitor: Any?
    private var localMovementMonitor: Any?
    private var dragPasteboardChangeCount = -1
    private var dragPasteboardContainsFiles = false
    private var isDragSampleScheduled = false

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
            matching: [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            // AppKit invokes event-monitor handlers on the main thread. Merge
            // high-frequency drag callbacks before touching the drag pasteboard.
            MainActor.assumeIsolated {
                self?.scheduleDragMovementSample()
            }
        }
        localMovementMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.scheduleDragMovementSample()
            }
            return event
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isDragSampleScheduled = false
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
        publishSample(isFileDrag: isFileDragInProgress)
    }

    private func publishSample(isFileDrag: Bool) {
        onSample?(
            NSEvent.mouseLocation,
            NSEvent.pressedMouseButtons,
            Date(),
            isFileDrag
        )
    }

    private var isFileDragInProgress: Bool {
        guard NSEvent.pressedMouseButtons != 0 else {
            dragPasteboardChangeCount = -1
            dragPasteboardContainsFiles = false
            return false
        }
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.changeCount != dragPasteboardChangeCount {
            dragPasteboardChangeCount = pasteboard.changeCount
            dragPasteboardContainsFiles = pasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) || pasteboard.types?.contains(.echoDockInternalShortcut) == true
        }
        return dragPasteboardContainsFiles
    }

    private func sampleDragMovement() {
        let isFileDrag = isFileDragInProgress
        guard isFileDrag else { return }
        publishSample(isFileDrag: isFileDrag)
    }

    private func scheduleDragMovementSample() {
        guard !isDragSampleScheduled else { return }
        isDragSampleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDragSampleScheduled = false
            guard self.timer != nil else { return }
            self.sampleDragMovement()
        }
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
