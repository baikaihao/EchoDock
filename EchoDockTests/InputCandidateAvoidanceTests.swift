import AppKit
import CoreGraphics
import XCTest
@testable import EchoDock

final class InputCandidateAvoidancePolicyTests: XCTestCase {
    private let currentProcessIdentifier: pid_t = 42
    private let dockWindowLevel = 20
    private let primaryIdentity = DisplayIdentity(rawValue: "primary")
    private let secondaryIdentity = DisplayIdentity(rawValue: "secondary")

    func testVisibleTransientWindowIntersectingDockOccludesDisplay() {
        let region = makeRegion(
            identity: primaryIdentity,
            frame: CGRect(x: 420, y: 810, width: 600, height: 72)
        )
        let candidate = makeWindow(
            bounds: CGRect(x: 610, y: 780, width: 360, height: 70)
        )

        XCTAssertEqual(
            occludedDisplays(regions: [region], windows: [candidate]),
            [primaryIdentity]
        )
    }

    func testRegularApplicationFloatingWindowDoesNotOccludeDock() {
        let region = makeRegion(identity: primaryIdentity)
        let regularApplicationWindow = makeWindow(
            bounds: region.frame,
            isRegularApplication: true
        )

        XCTAssertTrue(occludedDisplays(
            regions: [region],
            windows: [regularApplicationWindow]
        ).isEmpty)
    }

    func testWindowsAtOrAboveDockLevelDoNotRequireAvoidance() {
        let region = makeRegion(identity: primaryIdentity)

        XCTAssertTrue(occludedDisplays(regions: [region], windows: [
            makeWindow(bounds: region.frame, layer: dockWindowLevel),
            makeWindow(bounds: region.frame, layer: dockWindowLevel + 1)
        ]).isEmpty)
    }

    func testOnlyActuallyIntersectedDisplayIsOccluded() {
        let primary = makeRegion(
            identity: primaryIdentity,
            frame: CGRect(x: 420, y: 810, width: 600, height: 72)
        )
        let secondary = makeRegion(
            identity: secondaryIdentity,
            frame: CGRect(x: 1_720, y: 730, width: 500, height: 64)
        )
        let secondaryCandidate = makeWindow(
            bounds: CGRect(x: 1_800, y: 700, width: 300, height: 70)
        )

        XCTAssertEqual(
            occludedDisplays(
                regions: [primary, secondary],
                windows: [secondaryCandidate]
            ),
            [secondaryIdentity]
        )
    }

    func testTransientWindowWithoutIntersectionDoesNotOccludeDock() {
        let region = makeRegion(identity: primaryIdentity)
        let candidateAboveDock = makeWindow(
            bounds: CGRect(x: region.frame.minX, y: 700, width: 300, height: 80)
        )

        XCTAssertTrue(occludedDisplays(
            regions: [region],
            windows: [candidateAboveDock]
        ).isEmpty)
    }

    func testInvisibleLayerZeroAndOwnWindowsAreIgnored() {
        let region = makeRegion(identity: primaryIdentity)

        XCTAssertTrue(occludedDisplays(regions: [region], windows: [
            makeWindow(bounds: region.frame, layer: 0),
            makeWindow(bounds: region.frame, alpha: 0),
            makeWindow(bounds: region.frame, isOnScreen: false),
            makeWindow(
                bounds: region.frame,
                ownerPID: currentProcessIdentifier
            )
        ]).isEmpty)
    }

    private func occludedDisplays(
        regions: [InputCandidateDockRegion],
        windows: [InputCandidateWindowSnapshot]
    ) -> Set<DisplayIdentity> {
        InputCandidateAvoidancePolicy.occludedDisplayIdentities(
            regions: regions,
            windows: windows,
            excludingProcessIdentifier: currentProcessIdentifier,
            dockWindowLevel: dockWindowLevel
        )
    }

    private func makeRegion(
        identity: DisplayIdentity,
        frame: CGRect = CGRect(x: 420, y: 810, width: 600, height: 72)
    ) -> InputCandidateDockRegion {
        InputCandidateDockRegion(displayIdentity: identity, frame: frame)
    }

    private func makeWindow(
        bounds: CGRect,
        layer: Int = 1,
        ownerPID: pid_t = 100,
        isRegularApplication: Bool = false,
        alpha: CGFloat = 1,
        isOnScreen: Bool = true
    ) -> InputCandidateWindowSnapshot {
        InputCandidateWindowSnapshot(
            bounds: bounds,
            layer: layer,
            ownerProcessIdentifier: ownerPID,
            isRegularApplication: isRegularApplication,
            alpha: alpha,
            isOnScreen: isOnScreen
        )
    }
}

final class InputCandidateOcclusionDebouncerTests: XCTestCase {
    private let primaryIdentity = DisplayIdentity(rawValue: "primary")
    private let secondaryIdentity = DisplayIdentity(rawValue: "secondary")

    func testOcclusionPublishesImmediatelyAndDuplicateSamplesDoNotRepublish() {
        var debouncer = InputCandidateOcclusionDebouncer()

        XCTAssertEqual(debouncer.accept([primaryIdentity]), [primaryIdentity])
        XCTAssertNil(debouncer.accept([primaryIdentity]))
    }

    func testEachDisplayRequiresTwoConsecutiveMissesBeforeRestore() {
        var debouncer = InputCandidateOcclusionDebouncer()
        XCTAssertEqual(
            debouncer.accept([primaryIdentity, secondaryIdentity]),
            [primaryIdentity, secondaryIdentity]
        )

        XCTAssertNil(debouncer.accept([secondaryIdentity]))
        XCTAssertEqual(debouncer.accept([secondaryIdentity]), [secondaryIdentity])
        XCTAssertNil(debouncer.accept([]))
        XCTAssertEqual(debouncer.accept([]), [])
    }

    func testObservedDisplayResetsItsPendingRestore() {
        var debouncer = InputCandidateOcclusionDebouncer()
        XCTAssertEqual(debouncer.accept([primaryIdentity]), [primaryIdentity])

        XCTAssertNil(debouncer.accept([]))
        XCTAssertNil(debouncer.accept([primaryIdentity]))
        XCTAssertNil(debouncer.accept([]))
        XCTAssertEqual(debouncer.accept([]), [])
    }
}

final class EchoDockWindowLevelTests: XCTestCase {
    func testDockPanelsOccupyTheSystemDockWindowBand() {
        let systemDockLevel = Int(CGWindowLevelForKey(.dockWindow))

        XCTAssertEqual(EchoDockWindowLevel.dock.rawValue, systemDockLevel)
        XCTAssertEqual(
            EchoDockWindowLevel.dragReceiver.rawValue,
            systemDockLevel + 1
        )
        XCTAssertGreaterThan(
            EchoDockWindowLevel.dock.rawValue,
            NSWindow.Level.normal.rawValue
        )
        XCTAssertLessThan(
            EchoDockWindowLevel.dock.rawValue,
            NSWindow.Level.mainMenu.rawValue
        )
    }
}
