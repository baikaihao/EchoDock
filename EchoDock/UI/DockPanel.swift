import AppKit
import CoreGraphics

enum EchoDockWindowLevel {
    static let dock = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.dockWindow))
    )
    static let dragReceiver = NSWindow.Level(rawValue: dock.rawValue + 1)
}

final class DockPanel: NSPanel {
    var onPointerEvent: ((NSEvent) -> Void)?
    var onDraggingEntered: ((NSDraggingInfo) -> NSDragOperation)?
    var onDraggingUpdated: ((NSDraggingInfo) -> NSDragOperation)?
    var onDraggingExited: ((NSDraggingInfo?) -> Void)?
    var onPrepareForDragOperation: ((NSDraggingInfo) -> Bool)?
    var onPerformDragOperation: ((NSDraggingInfo) -> Bool)?
    var onConcludeDragOperation: ((NSDraggingInfo?) -> Void)?
    var onDraggingEnded: ((NSDraggingInfo) -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // The Dock magnification curve follows mouse movement between child
        // buttons. A nonactivating panel can receive those events without
        // stealing key focus from the foreground app.
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        level = EchoDockWindowLevel.dock
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        registerForDraggedTypes([.fileURL, .echoDockInternalShortcut])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingEntered?(sender) ?? []
    }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDraggingUpdated?(sender) ?? []
    }

    @objc func draggingExited(_ sender: NSDraggingInfo?) {
        onDraggingExited?(sender)
    }

    @objc func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPrepareForDragOperation?(sender) ?? false
    }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPerformDragOperation?(sender) ?? false
    }

    @objc func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onConcludeDragOperation?(sender)
    }

    @objc func draggingEnded(_ sender: NSDraggingInfo) {
        onDraggingEnded?(sender)
    }

    @objc func wantsPeriodicDraggingUpdates() -> Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        if DockPointerEventRouting.shouldForward(event.type) {
            onPointerEvent?(event)
        }
        super.sendEvent(event)
    }
}

enum DockPointerEventRouting {
    static func shouldForward(_ eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .mouseMoved,
             .leftMouseDragged,
             .rightMouseDragged,
             .otherMouseDragged:
            return true
        default:
            return false
        }
    }
}
