import XCTest
@testable import EchoDock

final class DockPointerSchedulingTests: XCTestCase {
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
