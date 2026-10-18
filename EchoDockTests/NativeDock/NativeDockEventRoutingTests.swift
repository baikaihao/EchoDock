import CoreGraphics
import Testing
@testable import EchoDock

struct NativeDockEventRoutingTests {
    @Test(arguments: [CGEventType.leftMouseDragged, .rightMouseDragged, .otherMouseDragged],
          [0, 1, 1 << 2])
    func protectedDragIsForwardedOnceWithItsOriginalData(
        eventType: CGEventType,
        pressedMouseButtons: Int
    ) throws {
        let point = CGPoint(x: 150, y: 100)
        let event = try #require(CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: .left
        ))
        event.flags = [.maskAlternate, .maskShift]
        event.setIntegerValueField(.eventSourceUserData, value: 1234)
        event.setIntegerValueField(.mouseEventNumber, value: 42)
        event.setIntegerValueField(.mouseEventDeltaX, value: 3)
        event.setIntegerValueField(.mouseEventDeltaY, value: 8)
        let originalTimestamp = event.timestamp
        var deliveries: [(event: CGEvent, location: CGEventTapLocation)] = []

        let sessionEvent = NativeDockProtectedEdgeEventRouter.route(
            event,
            pressedMouseButtons: pressedMouseButtons,
            postEvent: { deliveries.append(($0, $1)) }
        )

        #expect(sessionEvent == nil)
        #expect(deliveries.count == 1)
        let delivery = try #require(deliveries.first)
        #expect(delivery.location == .cgAnnotatedSessionEventTap)
        #expect(delivery.event !== event)
        #expect(delivery.event.type == eventType)
        #expect(delivery.event.location == point)
        #expect(delivery.event.timestamp == originalTimestamp)
        #expect(delivery.event.flags == event.flags)
        for field in [CGEventField.eventSourceUserData, .mouseEventNumber,
                      .mouseEventDeltaX, .mouseEventDeltaY, .mouseEventButtonNumber,
                      .eventSourceUnixProcessID] {
            #expect(delivery.event.getIntegerValueField(field) == event.getIntegerValueField(field))
        }
        #expect(event.location == point)
    }

    @Test(arguments: [0, 1, 1 << 2, 1 << 4])
    func mouseMovementKeepsDragDeliveryOnlyWhileAButtonIsHeld(pressedMouseButtons: Int) throws {
        let event = try #require(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 150, y: 100),
            mouseButton: .left
        ))
        var deliveryCount = 0

        let sessionEvent = NativeDockProtectedEdgeEventRouter.route(
            event,
            pressedMouseButtons: pressedMouseButtons,
            postEvent: { forwardedEvent, location in
                deliveryCount += 1
                #expect(forwardedEvent.location == event.location)
                #expect(location == .cgAnnotatedSessionEventTap)
            }
        )

        #expect(sessionEvent == nil)
        #expect(deliveryCount == (pressedMouseButtons == 0 ? 0 : 1))
    }

    @Test(arguments: [CGEventType.leftMouseUp, .rightMouseUp, .otherMouseUp,
                      .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel])
    func releaseClickAndScrollEventsPassThrough(eventType: CGEventType) throws {
        let event = try #require(CGEvent(source: nil))
        event.type = eventType
        var deliveryCount = 0

        let sessionEvent = NativeDockProtectedEdgeEventRouter.route(
            event,
            pressedMouseButtons: 1,
            postEvent: { _, _ in deliveryCount += 1 }
        )

        #expect(sessionEvent === event)
        #expect(deliveryCount == 0)
    }
}
