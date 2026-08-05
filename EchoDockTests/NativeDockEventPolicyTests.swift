import CoreGraphics
import XCTest
@testable import EchoDock

final class NativeDockEventPolicyTests: XCTestCase {
    func testMouseMovedCanBeBlocked() {
        XCTAssertTrue(NativeDockEventPolicy.canBeBlocked(.mouseMoved))
    }

    func testMouseMovedWithPressedButtonPassesThrough() {
        let pressedButtonMasks = [
            1,
            1 << 2,
            1 << 4
        ]

        for pressedMouseButtons in pressedButtonMasks {
            XCTAssertFalse(
                NativeDockEventPolicy.canBeBlocked(
                    .mouseMoved,
                    pressedMouseButtons: pressedMouseButtons
                )
            )
        }
    }

    func testDraggedEventsPassThrough() {
        let eventTypes: [CGEventType] = [
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]

        for eventType in eventTypes {
            XCTAssertFalse(NativeDockEventPolicy.canBeBlocked(eventType))
        }
    }

    func testTapDisabledEventsPassThrough() {
        let eventTypes: [CGEventType] = [
            .tapDisabledByTimeout,
            .tapDisabledByUserInput
        ]

        for eventType in eventTypes {
            XCTAssertFalse(NativeDockEventPolicy.canBeBlocked(eventType))
        }
    }
}

final class NativeDockRelocationInputPolicyTests: XCTestCase {
    func testRelocationWaitsUntilEveryMouseButtonIsReleased() {
        XCTAssertTrue(NativeDockRelocationInputPolicy.canRelocate(
            pressedMouseButtons: 0
        ))
        XCTAssertFalse(NativeDockRelocationInputPolicy.canRelocate(
            pressedMouseButtons: 1
        ))
        XCTAssertFalse(NativeDockRelocationInputPolicy.canRelocate(
            pressedMouseButtons: 1 << 2
        ))
    }
}
