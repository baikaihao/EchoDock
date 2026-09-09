import AppKit

@MainActor
final class MouseEdgeMonitor: NSObject {
    var onSample: ((CGPoint, Int, Date, Bool) -> Void)?

    private var globalMovementMonitor: Any?
    private var localMovementMonitor: Any?
    private var dragPasteboardChangeCount = -1
    private var dragPasteboardContainsFiles = false
    private var pendingDragSample: PointerSample?
    private var isDragSampleScheduled = false
    private var isRunning = false

    private struct PointerSample {
        let location: CGPoint
        let pressedButtons: Int
        let date: Date
    }

    private static let monitoredEvents: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .leftMouseUp,
        .rightMouseUp,
        .otherMouseUp
    ]

    func start() {
        guard !isRunning else { return }
        isRunning = true

        globalMovementMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: Self.monitoredEvents
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
        localMovementMonitor = NSEvent.addLocalMonitorForEvents(
            matching: Self.monitoredEvents
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }

        publishSample(
            isFileDrag: isFileDragInProgress(
                pressedButtons: NSEvent.pressedMouseButtons
            )
        )
    }

    func stop() {
        isRunning = false
        pendingDragSample = nil
        isDragSampleScheduled = false
        removeEventMonitors()
    }

    deinit {
        if let globalMovementMonitor {
            NSEvent.removeMonitor(globalMovementMonitor)
        }
        if let localMovementMonitor {
            NSEvent.removeMonitor(localMovementMonitor)
        }
    }

    private func handle(_ event: NSEvent) {
        guard isRunning else { return }
        let sample = PointerSample(
            location: event.cgEvent?.unflippedLocation ?? NSEvent.mouseLocation,
            pressedButtons: NSEvent.pressedMouseButtons,
            date: Date()
        )
        switch event.type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Drag pasteboard reads are more expensive than pointer delivery.
            // Merge only drag samples into the next main-run-loop turn.
            scheduleDragMovementSample(sample)
        default:
            publishSample(
                sample,
                isFileDrag: isFileDragInProgress(
                    pressedButtons: sample.pressedButtons
                )
            )
        }
    }

    private func publishSample(isFileDrag: Bool) {
        publishSample(
            PointerSample(
                location: NSEvent.mouseLocation,
                pressedButtons: NSEvent.pressedMouseButtons,
                date: Date()
            ),
            isFileDrag: isFileDrag
        )
    }

    private func publishSample(_ sample: PointerSample, isFileDrag: Bool) {
        onSample?(
            sample.location,
            sample.pressedButtons,
            sample.date,
            isFileDrag
        )
    }

    private func isFileDragInProgress(pressedButtons: Int) -> Bool {
        guard pressedButtons != 0 else {
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
        guard let sample = pendingDragSample else { return }
        pendingDragSample = nil
        publishSample(
            sample,
            isFileDrag: isFileDragInProgress(
                pressedButtons: sample.pressedButtons
            )
        )
    }

    private func scheduleDragMovementSample(_ sample: PointerSample) {
        pendingDragSample = sample
        guard !isDragSampleScheduled else { return }
        isDragSampleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDragSampleScheduled = false
            guard self.isRunning else { return }
            self.sampleDragMovement()
        }
    }

    private func removeEventMonitors() {
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
