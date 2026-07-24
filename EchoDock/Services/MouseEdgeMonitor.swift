import AppKit

@MainActor
final class MouseEdgeMonitor: NSObject {
    var onSample: ((CGPoint, Int, Date, Bool) -> Void)?
    var needsImmediateMovementSample: (() -> Bool)?

    private var timer: Timer?
    private var globalMovementMonitor: Any?
    private var localMovementMonitor: Any?
    private var dragPasteboardChangeCount = -1
    private var dragPasteboardContainsFiles = false

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
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleMovementIfNeeded()
            }
        }
        localMovementMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
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
        guard NSEvent.pressedMouseButtons != 0 else { return false }
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

    private func sampleMovementIfNeeded() {
        let isFileDrag = isFileDragInProgress
        guard needsImmediateMovementSample?() == true || isFileDrag else {
            return
        }
        publishSample(isFileDrag: isFileDrag)
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
