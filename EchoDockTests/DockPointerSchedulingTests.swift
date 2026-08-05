import XCTest
@testable import EchoDock

final class DockPointerSchedulingTests: XCTestCase {
    func testPrimaryShortPressActivatesOnlyWhenReleasedInside() {
        XCTAssertEqual(
            DockPrimaryPressPolicy.action(
                eventType: .leftMouseUp,
                elapsed: DockPrimaryPressPolicy.minimumPressDuration - 0.01,
                movementToleranceExceeded: false,
                isPointerInside: true,
                supportsFileDrag: false
            ),
            .activate
        )
        XCTAssertEqual(
            DockPrimaryPressPolicy.action(
                eventType: .leftMouseUp,
                elapsed: DockPrimaryPressPolicy.minimumPressDuration - 0.01,
                movementToleranceExceeded: false,
                isPointerInside: false,
                supportsFileDrag: false
            ),
            .cancel
        )
    }

    func testStationaryPrimaryPressPresentsContextMenuAtThreshold() {
        XCTAssertEqual(
            DockPrimaryPressPolicy.action(
                eventType: nil,
                elapsed: DockPrimaryPressPolicy.minimumPressDuration - 0.01,
                movementToleranceExceeded: false,
                isPointerInside: true,
                supportsFileDrag: false
            ),
            .continueTracking
        )
        XCTAssertEqual(
            DockPrimaryPressPolicy.action(
                eventType: nil,
                elapsed: DockPrimaryPressPolicy.minimumPressDuration,
                movementToleranceExceeded: false,
                isPointerInside: true,
                supportsFileDrag: false
            ),
            .presentContextMenu
        )
    }

    func testLongPressWinsOverMouseUpDeliveredAfterThreshold() {
        XCTAssertEqual(
            DockPrimaryPressPolicy.action(
                eventType: .leftMouseUp,
                elapsed: DockPrimaryPressPolicy.minimumPressDuration + 0.01,
                movementToleranceExceeded: false,
                isPointerInside: true,
                supportsFileDrag: false
            ),
            .presentContextMenu
        )
    }

    func testShortcutMovementStartsDragBeforeLongPress() {
        for eventType: NSEvent.EventType in [.leftMouseDragged, .mouseMoved] {
            XCTAssertEqual(
                DockPrimaryPressPolicy.action(
                    eventType: eventType,
                    elapsed: DockPrimaryPressPolicy.minimumPressDuration + 0.1,
                    movementToleranceExceeded: true,
                    isPointerInside: true,
                    supportsFileDrag: true
                ),
                .beginFileDrag
            )
        }
        XCTAssertEqual(
            DockPrimaryPressPolicy.action(
                eventType: .leftMouseDragged,
                elapsed: DockPrimaryPressPolicy.minimumPressDuration + 0.1,
                movementToleranceExceeded: true,
                isPointerInside: true,
                supportsFileDrag: false
            ),
            .continueTracking
        )
    }

    func testLongPressMenuAndFallbackDragKeepPrimaryMouseEventFamily() {
        XCTAssertEqual(
            DockPrimaryPressPolicy.contextMenuEventType(for: .leftMouseDown),
            .leftMouseDown
        )
        XCTAssertEqual(
            DockPrimaryPressPolicy.contextMenuEventType(for: .rightMouseDown),
            .rightMouseDown
        )
        XCTAssertEqual(
            DockPrimaryPressPolicy.fileDragEventType(for: .mouseMoved),
            .leftMouseDragged
        )
        XCTAssertEqual(
            DockPrimaryPressPolicy.fileDragEventType(for: .leftMouseDragged),
            .leftMouseDragged
        )
    }

    func testMovementToleranceIsInclusiveAndCancelsLongPress() {
        let start = NSPoint(x: 10, y: 10)
        XCTAssertFalse(DockPrimaryPressPolicy.exceededMovementTolerance(
            from: start,
            to: NSPoint(x: 13.99, y: 10)
        ))
        XCTAssertTrue(DockPrimaryPressPolicy.exceededMovementTolerance(
            from: start,
            to: NSPoint(x: 14, y: 10)
        ))
        XCTAssertEqual(
            DockPrimaryPressPolicy.action(
                eventType: nil,
                elapsed: DockPrimaryPressPolicy.minimumPressDuration,
                movementToleranceExceeded: true,
                isPointerInside: true,
                supportsFileDrag: false
            ),
            .continueTracking
        )
    }

    func testTrackingAreaIsReadOnlyForEntryAndExitEvents() {
        XCTAssertTrue(DockTrackingAreaEventPolicy.carriesTrackingArea(.mouseEntered))
        XCTAssertTrue(DockTrackingAreaEventPolicy.carriesTrackingArea(.mouseExited))
        XCTAssertFalse(DockTrackingAreaEventPolicy.carriesTrackingArea(.mouseMoved))
        XCTAssertFalse(DockTrackingAreaEventPolicy.carriesTrackingArea(.leftMouseDragged))
    }

    func testTrackingExitKeepsMagnificationWhileMouseButtonIsPressed() {
        XCTAssertFalse(DockPointerExitPolicy.shouldCancelInteraction(
            pressedMouseButtons: 1
        ))
        XCTAssertFalse(DockPointerExitPolicy.shouldCancelInteraction(
            pressedMouseButtons: 1 << 2
        ))
        XCTAssertTrue(DockPointerExitPolicy.shouldCancelInteraction(
            pressedMouseButtons: 0
        ))
    }

    func testPointerSequenceRejectsDuplicateAndOutOfOrderEvents() {
        var sequence = DockPointerSampleSequence()

        XCTAssertTrue(sequence.accept(10))
        XCTAssertFalse(sequence.accept(10))
        XCTAssertFalse(sequence.accept(9.99))
        XCTAssertTrue(sequence.accept(10.01))
    }

    func testPointerSequenceRejectsNonFiniteTimestamp() {
        var sequence = DockPointerSampleSequence()

        XCTAssertFalse(sequence.accept(.infinity))
        XCTAssertNil(sequence.lastAcceptedTimestamp)
    }

    func testFrameClockStaysWarmDuringContinuousPointerMovement() {
        let lastRequest = 100.0

        XCTAssertTrue(DockMagnificationFrameClockPolicy.keepsClockWarm(
            isPointerInside: true,
            lastPointerRequestTime: lastRequest,
            now: lastRequest + DockMagnificationFrameClockPolicy.pointerIdleGrace / 2
        ))
    }

    func testFrameClockStopsAfterIdleGraceOrPointerExit() {
        let lastRequest = 100.0
        let idleTime = lastRequest
            + DockMagnificationFrameClockPolicy.pointerIdleGrace
            + 0.001

        XCTAssertFalse(DockMagnificationFrameClockPolicy.keepsClockWarm(
            isPointerInside: true,
            lastPointerRequestTime: lastRequest,
            now: idleTime
        ))
        XCTAssertFalse(DockMagnificationFrameClockPolicy.keepsClockWarm(
            isPointerInside: false,
            lastPointerRequestTime: lastRequest,
            now: lastRequest + 0.001
        ))
    }

    func testButtonPresentationKeepsViewFrameStableWhileVisualSlotMoves() {
        let baseFrame = NSRect(x: 100, y: 0, width: 54, height: 72)
        let leftVisualFrame = NSRect(x: 86, y: 0, width: 62, height: 72)
        let rightVisualFrame = NSRect(x: 118, y: 0, width: 64, height: 72)

        let left = DockButtonPresentationGeometry.make(
            baseFrame: baseFrame,
            visualFrame: leftVisualFrame
        )
        let right = DockButtonPresentationGeometry.make(
            baseFrame: baseFrame,
            visualFrame: rightVisualFrame
        )

        XCTAssertEqual(left.viewFrame, baseFrame)
        XCTAssertEqual(right.viewFrame, baseFrame)
        XCTAssertEqual(
            baseFrame.midX + left.visualSlotCenterOffsetX,
            leftVisualFrame.midX,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            baseFrame.midX + right.visualSlotCenterOffsetX,
            rightVisualFrame.midX,
            accuracy: 0.0001
        )
    }

    func testMagnificationKeepsPointerInTheSameLogicalButtonSlot() {
        let baseLayout = DockMagnificationLayout.make(
            itemCount: 6,
            pinnedItemCount: 2,
            iconSize: 48,
            spacing: 6,
            maximumScale: 1.5,
            influenceRange: 3,
            containerWidth: 620,
            height: 80,
            pointerX: nil
        )

        for progress in [CGFloat(0.2), 0.65, 1] {
            for (index, baseFrame) in baseLayout.baseButtonFrames.enumerated() {
                for fraction in [CGFloat(0.05), 0.5, 0.95] {
                    let pointerX = baseFrame.minX + baseFrame.width * fraction
                    let magnifiedLayout = DockMagnificationLayout.make(
                        itemCount: 6,
                        pinnedItemCount: 2,
                        iconSize: 48,
                        spacing: 6,
                        maximumScale: 1.5,
                        influenceRange: 3,
                        containerWidth: 620,
                        height: 80,
                        pointerX: pointerX,
                        magnificationProgress: progress
                    )

                    XCTAssertTrue(
                        magnifiedLayout.buttonFrames[index].contains(
                            NSPoint(x: pointerX, y: 40)
                        ),
                        "pointer escaped logical slot \(index) at progress \(progress)"
                    )
                }
            }
        }
    }
}
