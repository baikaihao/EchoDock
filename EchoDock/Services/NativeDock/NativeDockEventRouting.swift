import CoreGraphics

enum NativeDockEventPolicy {
    static func canBeBlocked(_ eventType: CGEventType) -> Bool {
        switch eventType {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    static func requiresApplicationDelivery(
        _ eventType: CGEventType,
        pressedMouseButtons: Int
    ) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Trust the event even if AppKit's button-state sample is delayed.
            return true
        case .mouseMoved:
            return pressedMouseButtons != 0
        default:
            return false
        }
    }
}

enum NativeDockProtectedEdgeEventRouter {
    /// Called only for motion inside a non-target display's protected edge.
    static func route(
        _ event: CGEvent,
        pressedMouseButtons: Int,
        postEvent: (CGEvent, CGEventTapLocation) -> Void = { event, location in
            event.post(tap: location)
        }
    ) -> CGEvent? {
        guard NativeDockEventPolicy.canBeBlocked(event.type) else { return event }
        guard NativeDockEventPolicy.requiresApplicationDelivery(
            event.type,
            pressedMouseButtons: pressedMouseButtons
        ) else { return nil }
        guard let forwardedEvent = event.copy() else {
            // If forwarding is unavailable, preserve the drag rather than
            // swallowing its movement or changing the pointer's position.
            return event
        }

        // Skip the session-stage edge trigger, but retain application delivery
        // for AppKit's drag session. Rewriting coordinates here makes the drag
        // image fight the hardware cursor at the screen boundary.
        postEvent(forwardedEvent, .cgAnnotatedSessionEventTap)
        return nil
    }
}
