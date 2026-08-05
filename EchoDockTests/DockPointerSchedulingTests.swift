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
}
