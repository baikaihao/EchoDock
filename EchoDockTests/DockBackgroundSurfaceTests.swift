import XCTest
@testable import EchoDock

final class DockBackgroundSurfaceTests: XCTestCase {
    private let standardAccessibility = DockBackgroundAccessibilityOptions(
        reduceTransparency: false,
        increaseContrast: false,
        reduceMotion: false
    )

    func testLiquidGlassUsesNativeMaterialWhenAvailable() {
        let configuration = DockBackgroundSurfaceConfiguration.resolve(
            supportsLiquidGlass: true,
            selectedStyle: .liquidGlass,
            accessibility: standardAccessibility
        )

        XCTAssertEqual(configuration.material, .liquidGlass)
        XCTAssertFalse(configuration.increasesContrast)
    }

    func testLiquidGlassFallsBackToVisualEffectOnOlderSystems() {
        let configuration = DockBackgroundSurfaceConfiguration.resolve(
            supportsLiquidGlass: false,
            selectedStyle: .liquidGlass,
            accessibility: standardAccessibility
        )

        XCTAssertEqual(configuration.material, .visualEffect)
    }

    func testNativeLiquidGlassLetsAppKitHandleAccessibilityAdaptation() {
        let configuration = DockBackgroundSurfaceConfiguration.resolve(
            supportsLiquidGlass: true,
            selectedStyle: .liquidGlass,
            accessibility: DockBackgroundAccessibilityOptions(
                reduceTransparency: true,
                increaseContrast: true,
                reduceMotion: false
            )
        )

        XCTAssertEqual(configuration.material, .liquidGlass)
        XCTAssertTrue(configuration.increasesContrast)
    }

    func testClassicReduceTransparencyUsesSolidSurface() {
        let configuration = DockBackgroundSurfaceConfiguration.resolve(
            supportsLiquidGlass: true,
            selectedStyle: .classic,
            accessibility: DockBackgroundAccessibilityOptions(
                reduceTransparency: true,
                increaseContrast: false,
                reduceMotion: false
            )
        )

        XCTAssertEqual(configuration.material, .solid)
        XCTAssertFalse(configuration.increasesContrast)
    }

    func testClassicStyleUsesVisualEffectWhenTransparencyIsAllowed() {
        let configuration = DockBackgroundSurfaceConfiguration.resolve(
            supportsLiquidGlass: true,
            selectedStyle: .classic,
            accessibility: standardAccessibility
        )

        XCTAssertEqual(configuration.material, .visualEffect)
    }

    func testNativeGlassUsesItsOwnFrameWithoutAncestorMask() {
        let bounds = NSRect(x: 0, y: 0, width: 500, height: 72)
        let bodyRect = NSRect(x: 34, y: 0, width: 432, height: 72)

        XCTAssertEqual(
            DockBackgroundSurfaceLayout.rootFrame(
                material: .liquidGlass,
                bounds: bounds,
                bodyRect: bodyRect
            ),
            bodyRect
        )
        XCTAssertFalse(DockBackgroundSurfaceLayout.usesVisibilityMask(
            material: .liquidGlass
        ))
    }

    func testClassicSurfaceRetainsFullBoundsAndVisibilityMask() {
        let bounds = NSRect(x: 0, y: 0, width: 500, height: 72)
        let bodyRect = NSRect(x: 34, y: 0, width: 432, height: 72)

        XCTAssertEqual(
            DockBackgroundSurfaceLayout.rootFrame(
                material: .visualEffect,
                bounds: bounds,
                bodyRect: bodyRect
            ),
            bounds
        )
        XCTAssertTrue(DockBackgroundSurfaceLayout.usesVisibilityMask(
            material: .visualEffect
        ))
    }

    func testLiquidGlassExposesTransparencyButNotBlurTuning() {
        XCTAssertTrue(DockBackgroundTuningPolicy.allowsTransparencyTuning())
        XCTAssertTrue(DockBackgroundTuningPolicy.allowsBackgroundBlurTuning(
            supportsLiquidGlass: true,
            selectedStyle: .classic
        ))
        XCTAssertFalse(DockBackgroundTuningPolicy.allowsBackgroundBlurTuning(
            supportsLiquidGlass: true,
            selectedStyle: .liquidGlass
        ))
        XCTAssertFalse(DockBackgroundTuningPolicy.allowsTransparencyTuning(
            reduceTransparency: true
        ))
        XCTAssertFalse(DockBackgroundTuningPolicy.allowsBackgroundBlurTuning(
            supportsLiquidGlass: false,
            selectedStyle: .classic,
            reduceTransparency: true
        ))
    }

    func testLiquidGlassPresentationUsesBackgroundTransparency() {
        XCTAssertEqual(
            DockLiquidGlassPresentation.effectOpacity(
                transparency: 0.47,
                accessibility: standardAccessibility
            ),
            0.53
        )
        XCTAssertEqual(
            DockLiquidGlassPresentation.rimOpacity(
                accessibility: standardAccessibility
            ),
            0.38
        )
    }

    func testLiquidGlassPresentationUsesFullStrengthForAccessibility() {
        for accessibility in [
            DockBackgroundAccessibilityOptions(
                reduceTransparency: true,
                increaseContrast: false,
                reduceMotion: false
            ),
            DockBackgroundAccessibilityOptions(
                reduceTransparency: false,
                increaseContrast: true,
                reduceMotion: false
            )
        ] {
            XCTAssertEqual(
                DockLiquidGlassPresentation.effectOpacity(
                    transparency: 0.47,
                    accessibility: accessibility
                ),
                1
            )
        }
    }

    @MainActor
    func testNativeGlassViewUsesClearSystemMaterial() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("NSGlassEffectView requires macOS 26")
        }

        let view = DockBackgroundSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 72)
        )
        let bodyFrame = NSRect(x: 50, y: 0, width: 400, height: 72)
        view.configure(
            transparency: 0.9,
            blurStrength: 1,
            bodyHeight: 72,
            style: .liquidGlass
        )
        view.setVisibleBodyFrame(bodyFrame)
        view.layoutSubtreeIfNeeded()

        let glassViews = view.subviews.compactMap { $0 as? NSGlassEffectView }
        let glassView = try XCTUnwrap(glassViews.first)
        let accessibility = DockBackgroundAccessibilityOptions(
            reduceTransparency: NSWorkspace.shared
                .accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared
                .accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        let rimLayer = try XCTUnwrap(
            view.layer?.sublayers?.first { $0.zPosition == 10 }
        )
        XCTAssertEqual(glassViews.count, 1)
        XCTAssertEqual(view.subviews.count, 1)
        XCTAssertEqual(glassView.style, .clear)
        XCTAssertNil(glassView.tintColor)
        XCTAssertEqual(
            glassView.alphaValue,
            DockLiquidGlassPresentation.effectOpacity(
                transparency: 0.9,
                accessibility: accessibility
            )
        )
        XCTAssertNil(glassView.layer?.mask)
        XCTAssertEqual(glassView.frame, bodyFrame)
        XCTAssertFalse(rimLayer.isHidden)
        XCTAssertEqual(rimLayer.borderWidth, 0.7)
        XCTAssertEqual(
            rimLayer.borderColor?.alpha ?? -1,
            DockLiquidGlassPresentation.rimOpacity(
                accessibility: accessibility
            ),
            accuracy: 0.001
        )
    }
}
