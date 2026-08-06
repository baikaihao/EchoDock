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

    func testLiquidRimAlignsEveryEdgeToPhysicalPixels() {
        let scale: CGFloat = 2
        let aligned = DockBackgroundRim.pixelAligned(
            NSRect(x: 10.24, y: 0.26, width: 101.39, height: 71.51),
            scale: scale
        )

        for edge in [aligned.minX, aligned.minY, aligned.maxX, aligned.maxY] {
            XCTAssertEqual(edge * scale, (edge * scale).rounded())
        }
    }

    func testLiquidGlassExposesTransparencyButNotBlurTuning() {
        XCTAssertTrue(DockBackgroundTuningPolicy.allowsTransparencyTuning(
            supportsLiquidGlass: true,
            selectedStyle: .classic
        ))
        XCTAssertTrue(DockBackgroundTuningPolicy.allowsTransparencyTuning(
            supportsLiquidGlass: true,
            selectedStyle: .liquidGlass
        ))
        XCTAssertTrue(DockBackgroundTuningPolicy.allowsTransparencyTuning(
            supportsLiquidGlass: false,
            selectedStyle: .classic
        ))
        XCTAssertTrue(DockBackgroundTuningPolicy.allowsBackgroundBlurTuning(
            supportsLiquidGlass: true,
            selectedStyle: .classic
        ))
        XCTAssertFalse(DockBackgroundTuningPolicy.allowsBackgroundBlurTuning(
            supportsLiquidGlass: true,
            selectedStyle: .liquidGlass
        ))
        XCTAssertFalse(DockBackgroundTuningPolicy.allowsTransparencyTuning(
            supportsLiquidGlass: true,
            selectedStyle: .classic,
            reduceTransparency: true
        ))
        XCTAssertFalse(DockBackgroundTuningPolicy.allowsBackgroundBlurTuning(
            supportsLiquidGlass: false,
            selectedStyle: .classic,
            reduceTransparency: true
        ))
    }

    @MainActor
    func testNativeGlassViewHostsContentWithoutMovingItWithTheBody() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("NSGlassEffectView requires macOS 26")
        }

        let view = DockBackgroundSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 120)
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let bodyFrame = NSRect(x: 50, y: 0, width: 400, height: 72)
        let hostedFrame = NSRect(x: 10, y: 4, width: 480, height: 108)
        let scrollView = NSScrollView()
        scrollView.clipsToBounds = false
        scrollView.contentView.clipsToBounds = false
        view.hostContent(scrollView, interactionRoot: scrollView)
        view.setHostedContentFrame(hostedFrame)
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
        let rimLayer = try XCTUnwrap(
            view.layer?.sublayers?.first { $0.zPosition == 10 }
        )
        let glassContentProxy = try XCTUnwrap(glassView.contentView)
        let contentHost = try XCTUnwrap(scrollView.superview)
        let liquidOuterRimLayer = try XCTUnwrap(
            contentHost.layer?.sublayers?.first { $0.zPosition == -2 }
                as? CAShapeLayer
        )
        let liquidSpecularRimLayer = try XCTUnwrap(
            contentHost.layer?.sublayers?.first { $0.zPosition == -1 }
                as? CAGradientLayer
        )
        let liquidSpecularMaskLayer = try XCTUnwrap(
            liquidSpecularRimLayer.mask as? CAShapeLayer
        )
        let expectedLiquidRimFrame = contentHost.convert(
            bodyFrame,
            from: view
        )
        XCTAssertEqual(glassViews.count, 1)
        XCTAssertEqual(view.subviews.count, 2)
        XCTAssertTrue(contentHost.superview === view)
        XCTAssertFalse(isDescendant(scrollView, of: glassView))
        XCTAssertNil(firstDescendant(of: NSScrollView.self, in: glassContentProxy))
        XCTAssertEqual(glassView.style, .clear)
        XCTAssertNil(glassView.tintColor)
        let expectedOpacity = NSWorkspace.shared
            .accessibilityDisplayShouldIncreaseContrast ? 0.68 : 0.1
        XCTAssertEqual(glassView.alphaValue, expectedOpacity, accuracy: 0.000_1)
        XCTAssertEqual(contentHost.alphaValue, 1)
        XCTAssertNil(glassView.layer?.mask)
        XCTAssertEqual(glassView.frame, bodyFrame)
        XCTAssertEqual(scrollView.convert(scrollView.bounds, to: view), hostedFrame)
        XCTAssertEqual(
            glassView.cornerRadius,
            DockBackgroundGeometry.cornerRadius(forBodyHeight: bodyFrame.height)
        )
        XCTAssertTrue(rimLayer.isHidden)
        XCTAssertNil(rimLayer.borderColor)
        XCTAssertFalse(liquidOuterRimLayer.isHidden)
        XCTAssertFalse(liquidSpecularRimLayer.isHidden)
        XCTAssertEqual(liquidOuterRimLayer.frame, expectedLiquidRimFrame)
        XCTAssertEqual(liquidSpecularRimLayer.frame, expectedLiquidRimFrame)
        XCTAssertNotNil(liquidOuterRimLayer.path)
        XCTAssertNotNil(liquidSpecularMaskLayer.path)
        XCTAssertEqual(
            liquidOuterRimLayer.lineWidth,
            1 / window.backingScaleFactor,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            liquidSpecularMaskLayer.lineWidth,
            1 / window.backingScaleFactor,
            accuracy: 0.000_1
        )

        let expandedBodyFrame = NSRect(x: 20, y: 0, width: 460, height: 72)
        view.setVisibleBodyFrame(expandedBodyFrame)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(glassView.frame, expandedBodyFrame)
        XCTAssertEqual(scrollView.convert(scrollView.bounds, to: view), hostedFrame)
        XCTAssertNil(glassView.layer?.mask)
        XCTAssertTrue(rimLayer.isHidden)
        XCTAssertNil(rimLayer.borderColor)
        let expectedExpandedLiquidRimFrame = contentHost.convert(
            expandedBodyFrame,
            from: view
        )
        XCTAssertEqual(
            liquidOuterRimLayer.frame,
            expectedExpandedLiquidRimFrame
        )
        XCTAssertEqual(
            liquidSpecularRimLayer.frame,
            expectedExpandedLiquidRimFrame
        )
        XCTAssertNotNil(liquidOuterRimLayer.path)
        XCTAssertNotNil(liquidSpecularMaskLayer.path)
    }

    @MainActor
    func testNativeGlassForwardsHitsIntoContentAboveItsBody() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("NSGlassEffectView requires macOS 26")
        }

        let view = DockBackgroundSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 120)
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let bodyFrame = NSRect(x: 50, y: 0, width: 400, height: 72)
        let interactionView = NSView()
        interactionView.clipsToBounds = false
        let button = NSButton(
            frame: NSRect(x: 100, y: 80, width: 40, height: 30)
        )
        interactionView.addSubview(button)
        view.hostContent(
            interactionView,
            interactionRoot: interactionView
        ) { pointInInteractionView in
            let pointInButton = button.convert(
                pointInInteractionView,
                from: interactionView
            )
            return button.bounds.contains(pointInButton) ? button : nil
        }
        view.setHostedContentFrame(view.bounds)
        view.setVisibleBodyFrame(bodyFrame)
        view.layoutSubtreeIfNeeded()

        let buttonCenter = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: view
        )
        XCTAssertGreaterThan(buttonCenter.y, bodyFrame.maxY)
        let pointInInteraction = interactionView.convert(buttonCenter, from: view)
        let expectedPointInInteraction = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: interactionView
        )
        XCTAssertEqual(pointInInteraction, expectedPointInInteraction)
        let hitView = view.hitTest(buttonCenter)
        XCTAssertTrue(
            hitView.map { $0 === button || isDescendant($0, of: button) } == true,
            "Expected button at \(buttonCenter), got \(String(describing: hitView))"
        )

        var ancestor = button.superview
        while let current = ancestor, current !== view {
            XCTAssertFalse(current.clipsToBounds)
            ancestor = current.superview
        }
    }

    @MainActor
    func testHostedVisualHitMissDoesNotFallBackToStableButtonFrame() {
        let view = DockBackgroundSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 100)
        )
        let interactionView = NSView()
        let staleButton = NSButton(
            frame: NSRect(x: 80, y: 12, width: 48, height: 48)
        )
        interactionView.addSubview(staleButton)
        view.hostContent(
            interactionView,
            interactionRoot: interactionView,
            hostedHitTest: { _ in nil }
        )
        view.setHostedContentFrame(view.bounds)
        view.layoutSubtreeIfNeeded()

        let staleButtonCenter = staleButton.convert(
            NSPoint(x: staleButton.bounds.midX, y: staleButton.bounds.midY),
            to: view
        )
        XCTAssertTrue(view.hitTest(staleButtonCenter) === interactionView)
    }

    @MainActor
    func testDockContentKeepsOneHostedScrollTreeAcrossStyleChanges() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("NSGlassEffectView requires macOS 26")
        }

        let dock = DockContentView()
        func apply(style: DockBackgroundStyle) {
            dock.apply(
                snapshot: .empty,
                iconSize: 48,
                maxWidth: 500,
                backgroundTransparency: 0.47,
                backgroundStyle: style,
                magnificationEnabled: false
            )
            dock.layoutSubtreeIfNeeded()
        }

        apply(style: .liquidGlass)
        let backgroundView = try XCTUnwrap(
            dock.subviews.compactMap { $0 as? DockBackgroundSurfaceView }.first
        )
        let firstGlass = try XCTUnwrap(
            backgroundView.subviews.compactMap { $0 as? NSGlassEffectView }.first
        )
        let scrollView = try XCTUnwrap(firstDescendant(
            of: NSScrollView.self,
            in: backgroundView
        ))
        XCTAssertEqual(dock.subviews.count, 1)
        XCTAssertFalse(isDescendant(scrollView, of: firstGlass))
        XCTAssertNil(firstDescendant(
            of: NSScrollView.self,
            in: try XCTUnwrap(firstGlass.contentView)
        ))

        apply(style: .classic)
        XCTAssertEqual(dock.subviews.count, 1)
        XCTAssertTrue(isDescendant(scrollView, of: backgroundView))
        XCTAssertTrue(backgroundView.subviews.compactMap { $0 as? NSGlassEffectView }.isEmpty)

        apply(style: .liquidGlass)
        let secondGlass = try XCTUnwrap(
            backgroundView.subviews.compactMap { $0 as? NSGlassEffectView }.first
        )
        XCTAssertFalse(isDescendant(scrollView, of: secondGlass))
        XCTAssertNil(firstDescendant(
            of: NSScrollView.self,
            in: try XCTUnwrap(secondGlass.contentView)
        ))
        XCTAssertTrue(firstDescendant(
            of: NSScrollView.self,
            in: backgroundView
        ) === scrollView)
    }

    private func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current === ancestor { return true }
            candidate = current.superview
        }
        return false
    }

    private func firstDescendant<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> View? {
        if let match = root as? View { return match }
        for subview in root.subviews {
            if let match = firstDescendant(of: type, in: subview) {
                return match
            }
        }
        return nil
    }
}
