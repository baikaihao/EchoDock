import CoreGraphics
import XCTest
@testable import EchoDock

final class FullScreenWindowPolicyTests: XCTestCase {
    private let currentProcessIdentifier: pid_t = 42

    func testPhysicalFullScreenWindowMatchesItsDisplay() {
        let display = makeDisplay(
            id: 1,
            bounds: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(
            detect(displays: [display], windows: [
                makeWindow(bounds: display.bounds)
            ]),
            [display.displayID]
        )
    }

    func testOrdinaryMaximizedWindowDoesNotMatchPhysicalDisplay() {
        let display = makeDisplay(
            id: 1,
            bounds: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let visibleFrame = CGRect(x: 0, y: 24, width: 1_440, height: 876)

        XCTAssertTrue(detect(
            displays: [display],
            windows: [makeWindow(bounds: visibleFrame)]
        ).isEmpty)
    }

    func testIneligibleWindowsAreIgnored() {
        let display = makeDisplay(
            id: 1,
            bounds: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertTrue(detect(displays: [display], windows: [
            makeWindow(bounds: display.bounds, layer: 25),
            makeWindow(bounds: display.bounds, ownerPID: currentProcessIdentifier),
            makeWindow(bounds: display.bounds, isRegularApplication: false),
            makeWindow(bounds: display.bounds, alpha: 0),
            makeWindow(bounds: display.bounds, isOnScreen: false)
        ]).isEmpty)
    }

    func testDetectionIsIndependentForDisplaysWithNegativeCoordinates() {
        let left = makeDisplay(
            id: 1,
            bounds: CGRect(x: -1_280, y: 100, width: 1_280, height: 800)
        )
        let right = makeDisplay(
            id: 2,
            bounds: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let nearlyFullScreen = left.bounds.insetBy(dx: 2, dy: 2)

        XCTAssertEqual(
            detect(displays: [left, right], windows: [
                makeWindow(bounds: nearlyFullScreen)
            ]),
            [left.displayID]
        )
    }

    func testSplitViewWindowsCanCoverOnePhysicalDisplayTogether() {
        let display = makeDisplay(
            id: 1,
            bounds: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let left = CGRect(x: 0, y: 0, width: 714, height: 900)
        let right = CGRect(x: 726, y: 0, width: 714, height: 900)

        XCTAssertEqual(
            detect(displays: [display], windows: [
                makeWindow(bounds: left),
                makeWindow(bounds: right, ownerPID: 101)
            ]),
            [display.displayID]
        )
    }

    private func detect(
        displays: [FullScreenDisplayGeometry],
        windows: [FullScreenWindowSnapshot]
    ) -> Set<CGDirectDisplayID> {
        FullScreenWindowPolicy.fullScreenDisplayIDs(
            displays: displays,
            windows: windows,
            excludingProcessIdentifier: currentProcessIdentifier
        )
    }

    private func makeDisplay(
        id: CGDirectDisplayID,
        bounds: CGRect
    ) -> FullScreenDisplayGeometry {
        FullScreenDisplayGeometry(displayID: id, bounds: bounds)
    }

    private func makeWindow(
        bounds: CGRect,
        layer: Int = 0,
        ownerPID: pid_t = 100,
        isRegularApplication: Bool = true,
        alpha: CGFloat = 1,
        isOnScreen: Bool = true
    ) -> FullScreenWindowSnapshot {
        FullScreenWindowSnapshot(
            bounds: bounds,
            layer: layer,
            ownerProcessIdentifier: ownerPID,
            isRegularApplication: isRegularApplication,
            alpha: alpha,
            isOnScreen: isOnScreen
        )
    }
}

final class DockPanelPresentationPolicyTests: XCTestCase {
    func testFullScreenSuppressionTakesPriorityOverAutoHide() {
        XCTAssertEqual(
            DockPanelPresentationPolicy.mode(
                autoHide: false,
                autoHideInFullScreen: true,
                isFullScreenActive: true
            ),
            .suppressed
        )
        XCTAssertEqual(
            DockPanelPresentationPolicy.mode(
                autoHide: true,
                autoHideInFullScreen: true,
                isFullScreenActive: true
            ),
            .suppressed
        )
    }

    func testNormalVisibilityReturnsAfterFullScreen() {
        XCTAssertEqual(
            DockPanelPresentationPolicy.mode(
                autoHide: false,
                autoHideInFullScreen: true,
                isFullScreenActive: false
            ),
            .alwaysVisible
        )
        XCTAssertEqual(
            DockPanelPresentationPolicy.mode(
                autoHide: true,
                autoHideInFullScreen: true,
                isFullScreenActive: false
            ),
            .autoHidden
        )
    }

    func testDisabledFullScreenSettingPreservesNormalVisibilityMode() {
        XCTAssertEqual(
            DockPanelPresentationPolicy.mode(
                autoHide: false,
                autoHideInFullScreen: false,
                isFullScreenActive: true
            ),
            .alwaysVisible
        )
        XCTAssertEqual(
            DockPanelPresentationPolicy.mode(
                autoHide: true,
                autoHideInFullScreen: false,
                isFullScreenActive: true
            ),
            .autoHidden
        )
    }
}

final class FullScreenAutoHidePreferencesTests: XCTestCase {
    @MainActor
    func testPreferenceDefaultsOnAndPersistsAcrossStoreInstances() {
        let suiteName = "EchoDockTests.FullScreenAutoHide.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstStore = PreferencesStore(defaults: defaults)
        XCTAssertTrue(firstStore.autoHideInFullScreen)

        firstStore.autoHideInFullScreen = false
        let secondStore = PreferencesStore(defaults: defaults)
        XCTAssertFalse(secondStore.autoHideInFullScreen)
    }
}
