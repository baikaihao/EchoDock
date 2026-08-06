import CoreGraphics
import XCTest
@testable import EchoDock

final class WindowReservationGeometryTests: XCTestCase {
    private let primaryIdentity = DisplayIdentity(rawValue: "primary")

    func testReservedHeightIncludesDockBodyInsetsAndWindowGap() {
        XCTAssertEqual(WindowReservationMetrics.reservedHeight(iconSize: 48), 79)
        XCTAssertEqual(WindowReservationMetrics.reservedHeight(iconSize: 64), 95)
    }

    func testAvailableFrameReservesOnlyTheBottomStrip() {
        let display = makeDisplay(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876),
            reservedHeight: 78
        )

        XCTAssertEqual(
            display.availableFrame,
            CGRect(x: 0, y: 24, width: 1_440, height: 798)
        )
    }

    func testMaximizedWindowIsAdjustedAboveEchoDock() {
        let visibleFrame = CGRect(x: 0, y: 24, width: 1_440, height: 876)
        let display = makeDisplay(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: visibleFrame,
            reservedHeight: 78
        )

        let adjustment = WindowReservationGeometryPolicy.adjustment(
            for: visibleFrame,
            displays: [display]
        )

        XCTAssertEqual(adjustment?.displayIdentity, primaryIdentity)
        XCTAssertEqual(
            adjustment?.targetFrame,
            CGRect(x: 0, y: 24, width: 1_440, height: 798)
        )
    }

    func testManuallySizedWindowIsNotAdjusted() {
        let display = makeDisplay(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876),
            reservedHeight: 78
        )
        let manualFrame = CGRect(x: 80, y: 80, width: 1_000, height: 650)

        XCTAssertNil(WindowReservationGeometryPolicy.adjustment(
            for: manualFrame,
            displays: [display]
        ))
    }

    func testFillWindowKeepsItsExistingOuterMargins() {
        let display = makeDisplay(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876),
            reservedHeight: 78
        )
        let fillFrame = CGRect(x: 10, y: 34, width: 1_420, height: 856)

        let adjustment = WindowReservationGeometryPolicy.adjustment(
            for: fillFrame,
            displays: [display]
        )

        XCTAssertEqual(
            adjustment?.targetFrame,
            CGRect(x: 10, y: 34, width: 1_420, height: 788)
        )
    }

    func testLeftHalfWindowIsAdjustedWithoutChangingItsWidth() {
        let display = makeDisplay(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876),
            reservedHeight: 78
        )
        let leftHalf = CGRect(x: 8, y: 32, width: 704, height: 860)

        let adjustment = WindowReservationGeometryPolicy.adjustment(
            for: leftHalf,
            displays: [display]
        )

        XCTAssertEqual(
            adjustment?.targetFrame,
            CGRect(x: 8, y: 32, width: 704, height: 790)
        )
    }

    func testRightHalfWindowIsAdjustedWithoutChangingItsPosition() {
        let display = makeDisplay(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876),
            reservedHeight: 78
        )
        let rightHalf = CGRect(x: 728, y: 32, width: 704, height: 860)

        let adjustment = WindowReservationGeometryPolicy.adjustment(
            for: rightHalf,
            displays: [display]
        )

        XCTAssertEqual(
            adjustment?.targetFrame,
            CGRect(x: 728, y: 32, width: 704, height: 790)
        )
    }

    func testBottomQuarterWindowIsAdjusted() {
        let display = makeDisplay(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876),
            reservedHeight: 78
        )
        let bottomRightQuarter = CGRect(x: 728, y: 470, width: 704, height: 422)

        let adjustment = WindowReservationGeometryPolicy.adjustment(
            for: bottomRightQuarter,
            displays: [display]
        )

        XCTAssertEqual(
            adjustment?.targetFrame,
            CGRect(x: 728, y: 470, width: 704, height: 352)
        )
    }

    func testTopQuarterWindowDoesNotNeedBottomClearance() {
        let display = makeDisplay(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876),
            reservedHeight: 78
        )
        let topLeftQuarter = CGRect(x: 8, y: 32, width: 704, height: 422)

        XCTAssertNil(WindowReservationGeometryPolicy.adjustment(
            for: topLeftQuarter,
            displays: [display]
        ))
    }

    func testManualBottomWindowOutsideTileGridIsNotAdjusted() {
        let display = makeDisplay(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876),
            reservedHeight: 78
        )
        let manuallyPlaced = CGRect(x: 120, y: 32, width: 900, height: 860)

        XCTAssertNil(WindowReservationGeometryPolicy.adjustment(
            for: manuallyPlaced,
            displays: [display]
        ))
    }

    func testPhysicalFullScreenWindowIsNotAdjusted() {
        let physicalFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let display = makeDisplay(
            frame: physicalFrame,
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876),
            reservedHeight: 78
        )

        XCTAssertNil(WindowReservationGeometryPolicy.adjustment(
            for: physicalFrame,
            displays: [display]
        ))
    }

    func testNearlyPhysicalFullScreenWindowIsNotAdjusted() {
        let display = makeDisplay(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876),
            reservedHeight: 78
        )
        let nearlyPhysicalFrame = CGRect(x: 1, y: 1, width: 1_438, height: 898)

        XCTAssertNil(WindowReservationGeometryPolicy.adjustment(
            for: nearlyPhysicalFrame,
            displays: [display]
        ))
    }

    func testExistingLargerSystemClearanceWins() {
        let visibleFrame = CGRect(x: 0, y: 24, width: 1_440, height: 760)
        let display = makeDisplay(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: visibleFrame,
            reservedHeight: 78
        )

        XCTAssertEqual(display.availableFrame, visibleFrame)
        XCTAssertNil(WindowReservationGeometryPolicy.adjustment(
            for: visibleFrame,
            displays: [display]
        ))
    }

    func testDisplayWithLargestIntersectionIsSelected() {
        let left = WindowReservationDisplayGeometry(
            identity: DisplayIdentity(rawValue: "left"),
            frame: CGRect(x: -1_280, y: 0, width: 1_280, height: 800),
            visibleFrame: CGRect(x: -1_280, y: 24, width: 1_280, height: 776),
            reservedHeight: 70
        )
        let right = WindowReservationDisplayGeometry(
            identity: DisplayIdentity(rawValue: "right"),
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_440, height: 876),
            reservedHeight: 78
        )
        let mostlyRight = CGRect(x: -100, y: 40, width: 1_400, height: 820)

        XCTAssertEqual(
            WindowReservationGeometryPolicy.bestDisplay(
                for: mostlyRight,
                displays: [left, right]
            )?.identity,
            right.identity
        )
    }

    func testNegativeDisplayCoordinatesReserveTheLocalBottomEdge() {
        let identity = DisplayIdentity(rawValue: "above")
        let visibleFrame = CGRect(x: -1_280, y: -776, width: 1_280, height: 776)
        let display = WindowReservationDisplayGeometry(
            identity: identity,
            frame: CGRect(x: -1_280, y: -800, width: 1_280, height: 800),
            visibleFrame: visibleFrame,
            reservedHeight: 70
        )

        let adjustment = WindowReservationGeometryPolicy.adjustment(
            for: visibleFrame,
            displays: [display]
        )

        XCTAssertEqual(adjustment?.displayIdentity, identity)
        XCTAssertEqual(
            adjustment?.targetFrame,
            CGRect(x: -1_280, y: -776, width: 1_280, height: 706)
        )
    }

    func testMovedWindowSnapsToRightSideOfDockWithoutChangingItsSize() {
        let dock = makeSnapRegion()
        let window = CGRect(x: 947, y: 700, width: 400, height: 200)

        let adjustment = WindowEdgeSnapGeometryPolicy.adjustment(
            for: window,
            interaction: .move,
            regions: [dock]
        )

        XCTAssertEqual(
            adjustment?.targetFrame,
            CGRect(x: 941, y: 700, width: 400, height: 200)
        )
    }

    func testResizedWindowSnapsItsLeftEdgeAndKeepsRightEdgeFixed() {
        let dock = makeSnapRegion()
        let window = CGRect(x: 947, y: 700, width: 400, height: 200)

        let adjustment = WindowEdgeSnapGeometryPolicy.adjustment(
            for: window,
            interaction: .resize,
            regions: [dock]
        )

        XCTAssertEqual(
            adjustment?.targetFrame,
            CGRect(x: 941, y: 700, width: 406, height: 200)
        )
    }

    func testMovedWindowSnapsToLeftSideOfDock() {
        let dock = makeSnapRegion()
        let window = CGRect(x: 93, y: 700, width: 400, height: 200)

        let adjustment = WindowEdgeSnapGeometryPolicy.adjustment(
            for: window,
            interaction: .move,
            regions: [dock]
        )

        XCTAssertEqual(
            adjustment?.targetFrame,
            CGRect(x: 99, y: 700, width: 400, height: 200)
        )
    }

    func testResizedWindowSnapsItsBottomEdgeAboveDock() {
        let dock = makeSnapRegion()
        let window = CGRect(x: 550, y: 200, width: 500, height: 615)

        let adjustment = WindowEdgeSnapGeometryPolicy.adjustment(
            for: window,
            interaction: .resize,
            regions: [dock]
        )

        XCTAssertEqual(
            adjustment?.targetFrame,
            CGRect(x: 550, y: 200, width: 500, height: 621)
        )
    }

    func testWindowOutsideSnapDistanceOrOverlapIsNotAdjusted() {
        let dock = makeSnapRegion()

        XCTAssertNil(WindowEdgeSnapGeometryPolicy.adjustment(
            for: CGRect(x: 970, y: 700, width: 400, height: 200),
            interaction: .move,
            regions: [dock]
        ))
        XCTAssertNil(WindowEdgeSnapGeometryPolicy.adjustment(
            for: CGRect(x: 947, y: 100, width: 400, height: 500),
            interaction: .move,
            regions: [dock]
        ))
    }

    func testDockFrameConversionUsesTheLocalDisplayCoordinateSpace() {
        let converted = WindowEdgeSnapGeometryPolicy.accessibilityFrame(
            forCocoaFrame: CGRect(x: 2_000, y: -894, width: 400, height: 72),
            cocoaDisplayFrame: CGRect(x: 1_440, y: -900, width: 1_920, height: 900),
            accessibilityDisplayFrame: CGRect(x: 1_440, y: 900, width: 1_920, height: 900)
        )

        XCTAssertEqual(
            converted,
            CGRect(x: 2_000, y: 1_722, width: 400, height: 72)
        )
    }

    func testInteractiveSnapWaitsUntilEveryMouseButtonIsReleased() {
        XCTAssertTrue(WindowEdgeSnapInteractionPolicy.shouldDeferUntilMouseRelease(
            interaction: .move,
            pressedMouseButtons: 1
        ))
        XCTAssertFalse(WindowEdgeSnapInteractionPolicy.shouldDeferUntilMouseRelease(
            interaction: .resize,
            pressedMouseButtons: 0
        ))
        XCTAssertFalse(WindowEdgeSnapInteractionPolicy.shouldDeferUntilMouseRelease(
            interaction: nil,
            pressedMouseButtons: 1
        ))
    }

    private func makeSnapRegion() -> WindowEdgeSnapRegion {
        WindowEdgeSnapRegion(
            displayIdentity: primaryIdentity,
            frame: CGRect(x: 500, y: 822, width: 440, height: 72)
        )
    }

    private func makeDisplay(
        frame: CGRect,
        visibleFrame: CGRect,
        reservedHeight: CGFloat
    ) -> WindowReservationDisplayGeometry {
        WindowReservationDisplayGeometry(
            identity: primaryIdentity,
            frame: frame,
            visibleFrame: visibleFrame,
            reservedHeight: reservedHeight
        )
    }
}
