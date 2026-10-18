import CoreGraphics
import XCTest
@testable import EchoDock

final class NativeDockEventPolicyTests: XCTestCase {
    func testMouseMovedCanBeBlocked() {
        XCTAssertTrue(NativeDockEventPolicy.canBeBlocked(.mouseMoved))
    }

    func testMouseMovedCanBeProtectedWhileAButtonIsPressed() {
        let pressedButtonMasks = [
            1,
            1 << 2,
            1 << 4
        ]

        for pressedMouseButtons in pressedButtonMasks {
            XCTAssertTrue(
                NativeDockEventPolicy.requiresApplicationDelivery(
                    .mouseMoved,
                    pressedMouseButtons: pressedMouseButtons
                )
            )
        }
    }

    func testDraggedEventsCanBeProtectedWithoutBreakingDragDelivery() {
        let eventTypes: [CGEventType] = [
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]

        for eventType in eventTypes {
            XCTAssertTrue(NativeDockEventPolicy.canBeBlocked(eventType))
            XCTAssertTrue(NativeDockEventPolicy.requiresApplicationDelivery(
                eventType,
                pressedMouseButtons: 0
            ))
        }
        XCTAssertFalse(NativeDockEventPolicy.requiresApplicationDelivery(
            .mouseMoved,
            pressedMouseButtons: 0
        ))
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

final class NativeDockLockGeometryTests: XCTestCase {
    private let displays = [
        NativeDockLockDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMirrorSecondary: false
        ),
        NativeDockLockDisplayGeometry(
            displayID: 2,
            frame: CGRect(x: 100, y: 0, width: 100, height: 100),
            isMirrorSecondary: false
        )
    ]

    func testNonTargetBottomTriggerZoneIsProtected() {
        let point = CGPoint(x: 150, y: 99)

        XCTAssertTrue(NativeDockLockGeometry.shouldBlock(
            point: point,
            displays: displays,
            targetDisplayID: 1,
            edge: .bottom
        ))
    }

    func testTargetDisplayBottomEdgeRemainsUntouched() {
        let point = CGPoint(x: 50, y: 99)

        XCTAssertFalse(NativeDockLockGeometry.shouldBlock(
            point: point,
            displays: displays,
            targetDisplayID: 1,
            edge: .bottom
        ))
    }

    func testPhysicalBottomBoundaryIsIncludedOnProtectedDisplay() {
        XCTAssertTrue(NativeDockLockGeometry.shouldBlock(
            point: CGPoint(x: 150, y: 100),
            displays: displays,
            targetDisplayID: 1,
            edge: .bottom
        ))
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
