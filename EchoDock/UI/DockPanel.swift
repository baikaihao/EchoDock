import AppKit

final class DockPanel: NSPanel {
    var onPointerEvent: ((NSEvent) -> Void)?

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
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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
