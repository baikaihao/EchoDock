import XCTest
import CoreImage
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

    func testIceUsesCustomMaterialWhenAvailable() {
        let configuration = DockBackgroundSurfaceConfiguration.resolve(
            supportsLiquidGlass: true,
            selectedStyle: .ice,
            accessibility: standardAccessibility
        )

        XCTAssertEqual(configuration.material, .ice)
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

    func testIceFallsBackToVisualEffectOnOlderSystems() {
        let configuration = DockBackgroundSurfaceConfiguration.resolve(
            supportsLiquidGlass: false,
            selectedStyle: .ice,
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

    func testReduceTransparencyOverridesIceWithSolidSurface() {
        let configuration = DockBackgroundSurfaceConfiguration.resolve(
            supportsLiquidGlass: true,
            selectedStyle: .ice,
            accessibility: DockBackgroundAccessibilityOptions(
                reduceTransparency: true,
                increaseContrast: true,
                reduceMotion: false
            )
        )

        XCTAssertEqual(configuration.material, .solid)
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
        let bounds = NSRect(x: 0, y: 0, width: 500, height: 120)
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

    func testIceUsesStableCanvasAndShaderClipping() {
        let bounds = NSRect(x: 0, y: 0, width: 500, height: 120)
        let bodyRect = NSRect(x: 34, y: 0, width: 432, height: 72)

        XCTAssertEqual(
            DockBackgroundSurfaceLayout.rootFrame(
                material: .ice,
                bounds: bounds,
                bodyRect: bodyRect
            ),
            bounds
        )
        XCTAssertFalse(DockBackgroundSurfaceLayout.usesVisibilityMask(
            material: .ice
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

    func testLiquidGlassUsesDockOpticalPreset() {
        let optics = DockLiquidGlassOptics.dock

        XCTAssertEqual(optics.captureScale, 1)
        XCTAssertEqual(optics.sampleMargin, 32)
        XCTAssertEqual(optics.innerRefractionAmount, -30.24, accuracy: 0.000_1)
        XCTAssertEqual(optics.innerRefractionHeight, 9.144, accuracy: 0.000_1)
        XCTAssertEqual(optics.indexOfRefraction, 1.45)
        XCTAssertEqual(optics.maximumRefractionOffset, 17.28, accuracy: 0.000_1)
        XCTAssertEqual(optics.faceFillAlpha, 0.1)
        XCTAssertEqual(optics.keyLightAmount, 0.72)
        XCTAssertEqual(optics.fillLightAmount, 0.22)
    }

    func testLiquidGlassOpticsScaleContinuouslyWithDockHeight() {
        let compact = DockLiquidGlassOptics.dock(bodyHeight: 48)
        XCTAssertEqual(compact.innerRefractionAmount, -20.16, accuracy: 0.000_1)
        XCTAssertEqual(compact.innerRefractionHeight, 6.096, accuracy: 0.000_1)

        let large = DockLiquidGlassOptics.dock(bodyHeight: 120)
        XCTAssertEqual(large.innerRefractionAmount, -50.4, accuracy: 0.000_1)
        XCTAssertEqual(large.innerRefractionHeight, 15.24, accuracy: 0.000_1)
        XCTAssertGreaterThanOrEqual(
            compact.sampleMargin,
            compact.maximumRefractionOffset + 2
        )
        XCTAssertGreaterThanOrEqual(
            large.sampleMargin,
            large.maximumRefractionOffset + 2
        )
    }

    func testLiquidGlassMapEncodesSignedRefractionAndCoverage() throws {
        let descriptor = DockLiquidGlassMapDescriptor(
            bodyHeight: 72,
            cornerRadius: 20,
            backingScale: 2,
            optics: .dock
        )
        let map = try XCTUnwrap(
            DockLiquidGlassMapRenderer.makeMap(descriptor: descriptor)
        )
        let centerX = map.widthPixels / 2
        let centerY = map.heightPixels / 2

        let center = map.pixel(x: centerX, y: centerY)
        XCTAssertEqual(center.r, DockLiquidGlassDisplacementMap.neutralChannel)
        XCTAssertEqual(center.g, DockLiquidGlassDisplacementMap.neutralChannel)
        XCTAssertEqual(center.b, UInt8.max)

        let left = map.pixel(x: 0, y: centerY)
        let right = map.pixel(x: map.widthPixels - 1, y: centerY)
        let top = map.pixel(x: centerX, y: 0)
        let bottom = map.pixel(x: centerX, y: map.heightPixels - 1)
        XCTAssertGreaterThan(left.r, DockLiquidGlassDisplacementMap.neutralChannel)
        XCTAssertLessThan(right.r, DockLiquidGlassDisplacementMap.neutralChannel)
        XCTAssertLessThan(top.g, DockLiquidGlassDisplacementMap.neutralChannel)
        XCTAssertGreaterThan(bottom.g, DockLiquidGlassDisplacementMap.neutralChannel)

        let outsideCorner = map.pixel(x: 0, y: 0)
        XCTAssertEqual(outsideCorner.r, DockLiquidGlassDisplacementMap.neutralChannel)
        XCTAssertEqual(outsideCorner.g, DockLiquidGlassDisplacementMap.neutralChannel)
        XCTAssertEqual(outsideCorner.b, 0)
        XCTAssertEqual(outsideCorner.a, UInt8.max)
    }

    func testLiquidGlassMapHonorsRefractionAmountSign() throws {
        let negativeOptics = DockLiquidGlassOptics.dock
        let positiveOptics = DockLiquidGlassOptics(
            captureScale: negativeOptics.captureScale,
            sampleMargin: negativeOptics.sampleMargin,
            innerRefractionAmount: abs(negativeOptics.innerRefractionAmount),
            innerRefractionHeight: negativeOptics.innerRefractionHeight,
            indexOfRefraction: negativeOptics.indexOfRefraction,
            maximumRefractionOffset: negativeOptics.maximumRefractionOffset,
            faceFillAlpha: negativeOptics.faceFillAlpha,
            keyLightAmount: negativeOptics.keyLightAmount,
            fillLightAmount: negativeOptics.fillLightAmount
        )
        let negativeMap = try XCTUnwrap(
            DockLiquidGlassMapRenderer.makeMap(
                descriptor: DockLiquidGlassMapDescriptor(
                    bodyHeight: 72,
                    cornerRadius: 20,
                    backingScale: 2,
                    optics: negativeOptics
                )
            )
        )
        let positiveMap = try XCTUnwrap(
            DockLiquidGlassMapRenderer.makeMap(
                descriptor: DockLiquidGlassMapDescriptor(
                    bodyHeight: 72,
                    cornerRadius: 20,
                    backingScale: 2,
                    optics: positiveOptics
                )
            )
        )
        let centerX = negativeMap.widthPixels / 2
        let negativeTop = negativeMap.pixel(x: centerX, y: 0)
        let negativeBottom = negativeMap.pixel(
            x: centerX,
            y: negativeMap.heightPixels - 1
        )
        let positiveTop = positiveMap.pixel(x: centerX, y: 0)
        let positiveBottom = positiveMap.pixel(
            x: centerX,
            y: positiveMap.heightPixels - 1
        )

        XCTAssertLessThan(
            negativeTop.g,
            DockLiquidGlassDisplacementMap.neutralChannel
        )
        XCTAssertGreaterThan(
            positiveTop.g,
            DockLiquidGlassDisplacementMap.neutralChannel
        )
        XCTAssertGreaterThan(
            negativeBottom.g,
            DockLiquidGlassDisplacementMap.neutralChannel
        )
        XCTAssertLessThan(
            positiveBottom.g,
            DockLiquidGlassDisplacementMap.neutralChannel
        )
    }

    func testLiquidGlassMapKeepsVisibleRefractionBandOnEveryEdge() throws {
        let descriptor = DockLiquidGlassMapDescriptor(
            bodyHeight: 72,
            cornerRadius: 20,
            backingScale: 2,
            optics: .dock
        )
        let map = try XCTUnwrap(
            DockLiquidGlassMapRenderer.makeMap(descriptor: descriptor)
        )
        let depth = max(
            1,
            Int((descriptor.optics.innerRefractionHeight
                * descriptor.backingScale * 0.5).rounded())
        )
        let centerX = map.widthPixels / 2
        let centerY = map.heightPixels / 2
        let neutral = Int(DockLiquidGlassDisplacementMap.neutralChannel)
        let minimumVisibleDelta = 16
        for currentDepth in 0...depth {
            let samples = [
                map.pixel(x: currentDepth, y: centerY),
                map.pixel(
                    x: map.widthPixels - 1 - currentDepth,
                    y: centerY
                ),
                map.pixel(x: centerX, y: currentDepth),
                map.pixel(
                    x: centerX,
                    y: map.heightPixels - 1 - currentDepth
                )
            ]

            XCTAssertGreaterThan(
                Int(samples[0].r),
                neutral + minimumVisibleDelta
            )
            XCTAssertLessThan(
                Int(samples[1].r),
                neutral - minimumVisibleDelta
            )
            XCTAssertLessThan(
                Int(samples[2].g),
                neutral - minimumVisibleDelta
            )
            XCTAssertGreaterThan(
                Int(samples[3].g),
                neutral + minimumVisibleDelta
            )
            XCTAssertEqual(
                samples[0].g,
                DockLiquidGlassDisplacementMap.neutralChannel
            )
            XCTAssertEqual(
                samples[1].g,
                DockLiquidGlassDisplacementMap.neutralChannel
            )
            XCTAssertEqual(
                samples[2].r,
                DockLiquidGlassDisplacementMap.neutralChannel
            )
            XCTAssertEqual(
                samples[3].r,
                DockLiquidGlassDisplacementMap.neutralChannel
            )
            XCTAssertTrue(
                samples.allSatisfy { $0.b > 0 && $0.a == UInt8.max }
            )
        }
    }

    func testLiquidGlassMapKeepsVectorAlphaOpaque() throws {
        let descriptor = DockLiquidGlassMapDescriptor(
            bodyHeight: 72,
            cornerRadius: 20,
            backingScale: 2,
            optics: .dock
        )
        let map = try XCTUnwrap(
            DockLiquidGlassMapRenderer.makeMap(descriptor: descriptor)
        )
        let alphaValues = stride(from: 3, to: map.rgba8.count, by: 4).map {
            map.rgba8[$0]
        }
        let coverageValues = stride(from: 2, to: map.rgba8.count, by: 4).map {
            map.rgba8[$0]
        }

        XCTAssertTrue(alphaValues.allSatisfy { $0 == UInt8.max })
        XCTAssertTrue(coverageValues.contains(0))
        XCTAssertTrue(coverageValues.contains(UInt8.max))
        XCTAssertTrue(coverageValues.contains { $0 > 0 && $0 < UInt8.max })
    }

    func testLiquidGlassMapUsesOneStretchableNeutralColumn() throws {
        let descriptor = DockLiquidGlassMapDescriptor(
            bodyHeight: 72,
            cornerRadius: 20,
            backingScale: 2,
            optics: .dock
        )
        let map = try XCTUnwrap(
            DockLiquidGlassMapRenderer.makeMap(descriptor: descriptor)
        )
        let expectedCenterWidth = 1 / CGFloat(map.widthPixels)

        XCTAssertEqual(map.contentsCenter.width, expectedCenterWidth, accuracy: 0.000_1)
        XCTAssertEqual(map.contentsCenter.height, 1)
        XCTAssertEqual(
            map.contentsCenter.midX,
            0.5,
            accuracy: 0.000_1
        )
        XCTAssertLessThan(map.widthPixels, map.heightPixels)
    }

    func testLiquidGlassStretchColumnPreservesFullVerticalRefractionBand() throws {
        let descriptor = DockLiquidGlassMapDescriptor(
            bodyHeight: 72,
            cornerRadius: 20,
            backingScale: 2,
            optics: .dock
        )
        let map = try XCTUnwrap(
            DockLiquidGlassMapRenderer.makeMap(descriptor: descriptor)
        )
        let centerX = map.widthPixels / 2
        let halfBandRow = max(
            1,
            Int((descriptor.optics.innerRefractionHeight
                * descriptor.backingScale * 0.5).rounded())
        )
        let topSample = map.pixel(x: centerX, y: halfBandRow)
        let bottomSample = map.pixel(
            x: centerX,
            y: map.heightPixels - 1 - halfBandRow
        )

        XCTAssertEqual(topSample.r, DockLiquidGlassDisplacementMap.neutralChannel)
        XCTAssertLessThan(topSample.g, DockLiquidGlassDisplacementMap.neutralChannel)
        XCTAssertEqual(topSample.a, UInt8.max)
        XCTAssertEqual(bottomSample.r, DockLiquidGlassDisplacementMap.neutralChannel)
        XCTAssertGreaterThan(bottomSample.g, DockLiquidGlassDisplacementMap.neutralChannel)
        XCTAssertEqual(bottomSample.a, UInt8.max)
    }

    func testBackgroundStylesExposeOnlySupportedTuning() {
        XCTAssertTrue(DockBackgroundTuningPolicy.allowsTransparencyTuning(
            supportsLiquidGlass: true,
            selectedStyle: .classic
        ))
        XCTAssertFalse(DockBackgroundTuningPolicy.allowsTransparencyTuning(
            supportsLiquidGlass: true,
            selectedStyle: .liquidGlass
        ))
        XCTAssertTrue(DockBackgroundTuningPolicy.allowsTransparencyTuning(
            supportsLiquidGlass: true,
            selectedStyle: .ice
        ))
        XCTAssertTrue(DockBackgroundTuningPolicy.allowsTransparencyTuning(
            supportsLiquidGlass: false,
            selectedStyle: .liquidGlass
        ))
        XCTAssertTrue(DockBackgroundTuningPolicy.allowsBackgroundBlurTuning(
            supportsLiquidGlass: true,
            selectedStyle: .classic
        ))
        XCTAssertFalse(DockBackgroundTuningPolicy.allowsBackgroundBlurTuning(
            supportsLiquidGlass: true,
            selectedStyle: .liquidGlass
        ))
        XCTAssertFalse(DockBackgroundTuningPolicy.allowsBackgroundBlurTuning(
            supportsLiquidGlass: true,
            selectedStyle: .ice
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

    func testBackgroundGaussianBlurRadiusClampsAndScales() {
        XCTAssertEqual(
            DockBackgroundGaussianBlur.radius(strength: 0, bodyHeight: 72),
            0,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            DockBackgroundGaussianBlur.radius(strength: 0.5, bodyHeight: 72),
            10,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            DockBackgroundGaussianBlur.radius(strength: 1, bodyHeight: 72),
            40,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            DockBackgroundGaussianBlur.radius(strength: 2, bodyHeight: 72),
            40,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            DockBackgroundGaussianBlur.radius(strength: 1, bodyHeight: 20),
            12,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            DockBackgroundGaussianBlur.radius(strength: -1, bodyHeight: -20),
            0,
            accuracy: 0.000_1
        )
    }

    @MainActor
    func testNativeGlassKeepsContentAboveTheBodyWithoutMovingIt() throws {
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
        let glass = try XCTUnwrap(glassViews.first)
        let glassContentProxy = try XCTUnwrap(glass.contentView)
        let contentHost = try XCTUnwrap(scrollView.superview)
        let rimLayer = try XCTUnwrap(
            view.layer?.sublayers?.first { $0.zPosition == 10 }
        )
        let outerRim = try XCTUnwrap(
            contentHost.layer?.sublayers?.first {
                $0.name == "echoDockLiquidOuterRim"
            } as? CAShapeLayer
        )
        let specularRim = try XCTUnwrap(
            contentHost.layer?.sublayers?.first {
                $0.name == "echoDockLiquidSpecularRim"
            } as? CAGradientLayer
        )
        let specularMask = try XCTUnwrap(
            specularRim.mask as? CAShapeLayer
        )
        XCTAssertEqual(glassViews.count, 1)
        XCTAssertEqual(view.subviews.count, 2)
        XCTAssertTrue(contentHost.superview === view)
        XCTAssertFalse(isDescendant(scrollView, of: glass))
        XCTAssertNil(firstDescendant(
            of: NSScrollView.self,
            in: glassContentProxy
        ))
        XCTAssertEqual(glass.style, .clear)
        XCTAssertNil(glass.tintColor)
        XCTAssertEqual(glass.alphaValue, 1)
        XCTAssertNil(glass.layer?.mask)
        XCTAssertEqual(glass.frame, bodyFrame)
        XCTAssertEqual(scrollView.convert(scrollView.bounds, to: view), hostedFrame)
        XCTAssertEqual(
            glass.cornerRadius,
            DockBackgroundGeometry.cornerRadius(forBodyHeight: bodyFrame.height)
        )
        XCTAssertTrue(rimLayer.isHidden)
        XCTAssertNil(rimLayer.borderColor)
        XCTAssertFalse(outerRim.isHidden)
        XCTAssertFalse(specularRim.isHidden)
        XCTAssertNotNil(outerRim.path)
        XCTAssertNotNil(specularMask.path)
        XCTAssertGreaterThan(outerRim.strokeColor?.alpha ?? 0, 0)
        XCTAssertTrue(
            (specularRim.colors ?? []).map { ($0 as! CGColor).alpha }
                .contains { $0 > 0 }
        )
        let expectedRimFrame = contentHost.convert(
            DockBackgroundRim.pixelAligned(
                bodyFrame,
                scale: window.backingScaleFactor
            ),
            from: view
        )
        XCTAssertEqual(outerRim.frame, expectedRimFrame)
        XCTAssertEqual(specularRim.frame, expectedRimFrame)

        let expandedBodyFrame = NSRect(x: 20, y: 0, width: 460, height: 72)
        view.setVisibleBodyFrame(expandedBodyFrame)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            view.subviews.compactMap { $0 as? NSGlassEffectView }.first === glass
        )
        XCTAssertEqual(glass.frame, expandedBodyFrame)
        XCTAssertEqual(scrollView.convert(scrollView.bounds, to: view), hostedFrame)
        XCTAssertNil(glass.layer?.mask)
        XCTAssertTrue(rimLayer.isHidden)
        XCTAssertNil(rimLayer.borderColor)
        XCTAssertTrue(
            contentHost.layer?.sublayers?.first {
                $0.name == "echoDockLiquidOuterRim"
            } === outerRim
        )
        XCTAssertTrue(
            contentHost.layer?.sublayers?.first {
                $0.name == "echoDockLiquidSpecularRim"
            } === specularRim
        )
        let expectedExpandedRimFrame = contentHost.convert(
            DockBackgroundRim.pixelAligned(
                expandedBodyFrame,
                scale: window.backingScaleFactor
            ),
            from: view
        )
        XCTAssertEqual(outerRim.frame, expectedExpandedRimFrame)
        XCTAssertEqual(specularRim.frame, expectedExpandedRimFrame)
    }

    @MainActor
    func testIceHostsContentWithoutMovingItWithTheBody() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Liquid Glass requires macOS 26")
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
            style: .ice
        )
        view.setVisibleBodyFrame(bodyFrame)
        view.layoutSubtreeIfNeeded()

        let liquidSurfaces = view.subviews.compactMap {
            $0 as? DockLiquidGlassSurfaceView
        }
        let liquidSurface = try XCTUnwrap(liquidSurfaces.first)
        let initialRootLayer = try XCTUnwrap(liquidSurface.layer)
        let initialBackdropLayer = try XCTUnwrap(liquidSurface.backdropLayer)
        let bottomRightHighlight = try XCTUnwrap(
            initialRootLayer.sublayers?.first {
                $0.name == "echoDockIceBottomRightHighlight"
            } as? CAGradientLayer
        )
        let bottomRightHighlightMask = try XCTUnwrap(
            bottomRightHighlight.mask as? CAShapeLayer
        )
        let initialMapLayer = try XCTUnwrap(liquidSurface.displacementMapLayer)
        let initialMap = try XCTUnwrap(liquidSurface.displacementMap)
        let initialDisplacementFilter = try XCTUnwrap(
            liquidSurface.displacementFilter
        )
        let initialMapGenerationCount = liquidSurface.mapGenerationCount
        let initialGeometryApplicationCount =
            liquidSurface.geometryApplicationCount
        let rimLayer = try XCTUnwrap(
            view.layer?.sublayers?.first { $0.zPosition == 10 }
        )
        let contentHost = try XCTUnwrap(scrollView.superview)
        XCTAssertEqual(liquidSurfaces.count, 1)
        XCTAssertEqual(view.subviews.count, 2)
        XCTAssertTrue(contentHost.superview === view)
        XCTAssertFalse(isDescendant(scrollView, of: liquidSurface))
        XCTAssertTrue(
            view.subviews.compactMap { $0 as? NSGlassEffectView }.isEmpty
        )
        XCTAssertTrue(liquidSurface.isUsingCustomRenderer)
        XCTAssertEqual(
            NSStringFromClass(type(of: initialBackdropLayer)),
            "CABackdropLayer"
        )
        XCTAssertNotEqual(
            NSStringFromClass(type(of: initialRootLayer)),
            "CABackdropLayer"
        )
        XCTAssertNotNil(bottomRightHighlightMask.path)
        XCTAssertEqual(bottomRightHighlight.colors?.count, 4)
        XCTAssertEqual(bottomRightHighlight.locations?.count, 4)
        XCTAssertFalse(
            initialRootLayer.sublayers?.contains {
                $0.shadowOpacity > 0
            } ?? false
        )
        XCTAssertFalse(liquidSurface.layerUsesCoreImageFilters)
        let initialFilters = try XCTUnwrap(initialBackdropLayer.filters)
        XCTAssertEqual(initialFilters.count, 1)
        let initialFilterNames = initialFilters.compactMap {
            ($0 as? NSObject)?.value(forKey: "name") as? String
        }
        XCTAssertEqual(
            initialFilterNames,
            ["echoDockDisplacement"]
        )
        XCTAssertTrue(
            (initialFilters[0] as AnyObject) === initialDisplacementFilter
        )

        let requiredMapInputs: Set<String> = [
            "inputMaskImage",
            "inputOffset",
            "inputAmount",
            "inputSourceSublayerName"
        ]
        let displacementInputs = Set(
            initialDisplacementFilter.value(forKey: "inputKeys")
                as? [String] ?? []
        )
        XCTAssertTrue(requiredMapInputs.isSubset(of: displacementInputs))
        XCTAssertEqual(
            initialDisplacementFilter.value(
                forKey: "inputSourceSublayerName"
            ) as? String,
            DockLiquidGlassMapRenderer.displacementSourceLayerName
        )
        let expectedInputOffset = NSPoint(x: 0.5, y: 0.5)
        let displacementInputOffset = try XCTUnwrap(
            initialDisplacementFilter.value(forKey: "inputOffset")
                as? NSValue
        )
        XCTAssertEqual(displacementInputOffset.pointValue, expectedInputOffset)
        let displacementAmount = try XCTUnwrap(
            initialDisplacementFilter.value(forKey: "inputAmount")
                as? NSNumber
        )
        XCTAssertEqual(
            displacementAmount.doubleValue,
            Double(DockLiquidGlassOptics.dock.maximumRefractionOffset * 2),
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            initialMapLayer.name,
            DockLiquidGlassMapRenderer.displacementSourceLayerName
        )
        let initialLocalBodyBounds = NSRect(
            origin: .zero,
            size: bodyFrame.size
        )
        XCTAssertEqual(initialBackdropLayer.frame, bodyFrame)
        XCTAssertEqual(initialMapLayer.frame, initialLocalBodyBounds)
        XCTAssertEqual(initialMapLayer.contentsCenter, initialMap.contentsCenter)
        XCTAssertTrue(
            (initialMapLayer.contents as AnyObject?) === initialMap.image
        )
        XCTAssertFalse(initialMapLayer.isHidden)
        let expectedOpacity = NSWorkspace.shared
            .accessibilityDisplayShouldIncreaseContrast ? 0.68 : 0.1
        XCTAssertEqual(
            liquidSurface.materialOpacity,
            expectedOpacity,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            liquidSurface.alphaValue,
            expectedOpacity,
            accuracy: 0.000_1
        )
        XCTAssertEqual(contentHost.alphaValue, 1)
        XCTAssertNil(liquidSurface.layer?.mask)
        XCTAssertTrue(liquidSurface.layer?.masksToBounds == false)
        XCTAssertEqual(liquidSurface.frame, view.bounds)
        XCTAssertEqual(liquidSurface.renderedBodyRect, bodyFrame)
        XCTAssertEqual(scrollView.convert(scrollView.bounds, to: view), hostedFrame)
        XCTAssertEqual(
            liquidSurface.renderedCornerRadius,
            DockBackgroundGeometry.cornerRadius(forBodyHeight: bodyFrame.height)
        )
        XCTAssertTrue(rimLayer.isHidden)
        XCTAssertNil(rimLayer.borderColor)

        view.configure(
            transparency: 0.9,
            blurStrength: 0.5,
            bodyHeight: 72,
            style: .ice
        )
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(liquidSurface.layer === initialRootLayer)
        XCTAssertTrue(liquidSurface.backdropLayer === initialBackdropLayer)
        XCTAssertTrue(liquidSurface.displacementMapLayer === initialMapLayer)
        XCTAssertTrue(liquidSurface.displacementMap?.image === initialMap.image)
        XCTAssertTrue(liquidSurface.displacementFilter === initialDisplacementFilter)
        XCTAssertEqual(liquidSurface.mapGenerationCount, initialMapGenerationCount)
        XCTAssertEqual(
            liquidSurface.geometryApplicationCount,
            initialGeometryApplicationCount
        )
        XCTAssertEqual(initialBackdropLayer.filters?.count, 1)

        let expandedBodyFrame = NSRect(x: 20, y: 0, width: 460, height: 72)
        view.setVisibleBodyFrame(expandedBodyFrame)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(liquidSurface.layer === initialRootLayer)
        XCTAssertTrue(liquidSurface.backdropLayer === initialBackdropLayer)
        XCTAssertTrue(liquidSurface.displacementMapLayer === initialMapLayer)
        XCTAssertTrue(
            liquidSurface.displacementFilter === initialDisplacementFilter
        )
        XCTAssertTrue(liquidSurface.displacementMap?.image === initialMap.image)
        XCTAssertEqual(initialBackdropLayer.filters?.count, 1)
        XCTAssertEqual(
            liquidSurface.mapGenerationCount,
            initialMapGenerationCount
        )
        XCTAssertEqual(
            liquidSurface.geometryApplicationCount,
            initialGeometryApplicationCount + 1
        )
        XCTAssertEqual(liquidSurface.frame, view.bounds)
        XCTAssertEqual(liquidSurface.renderedBodyRect, expandedBodyFrame)
        XCTAssertEqual(initialBackdropLayer.frame, expandedBodyFrame)
        XCTAssertEqual(
            initialMapLayer.frame,
            NSRect(origin: .zero, size: expandedBodyFrame.size)
        )
        XCTAssertEqual(scrollView.convert(scrollView.bounds, to: view), hostedFrame)
        XCTAssertNil(liquidSurface.layer?.mask)
        XCTAssertTrue(rimLayer.isHidden)
        XCTAssertNil(rimLayer.borderColor)

        liquidSurface.needsLayout = true
        liquidSurface.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            liquidSurface.geometryApplicationCount,
            initialGeometryApplicationCount + 1
        )

        let tallerBodyFrame = NSRect(x: 20, y: 0, width: 460, height: 84)
        view.setVisibleBodyFrame(tallerBodyFrame)
        view.layoutSubtreeIfNeeded()
        let tallerMap = try XCTUnwrap(liquidSurface.displacementMap)
        let tallerDisplacementFilter = try XCTUnwrap(
            liquidSurface.displacementFilter
        )
        XCTAssertTrue(liquidSurface.layer === initialRootLayer)
        XCTAssertTrue(liquidSurface.backdropLayer === initialBackdropLayer)
        XCTAssertTrue(liquidSurface.displacementMapLayer === initialMapLayer)
        XCTAssertFalse(tallerMap.image === initialMap.image)
        XCTAssertFalse(tallerDisplacementFilter === initialDisplacementFilter)
        XCTAssertEqual(initialBackdropLayer.filters?.count, 1)
        XCTAssertEqual(
            liquidSurface.mapGenerationCount,
            initialMapGenerationCount + 1
        )
        XCTAssertEqual(
            liquidSurface.geometryApplicationCount,
            initialGeometryApplicationCount + 2
        )
        XCTAssertEqual(initialBackdropLayer.frame, tallerBodyFrame)
        XCTAssertEqual(
            initialMapLayer.frame,
            NSRect(origin: .zero, size: tallerBodyFrame.size)
        )
        XCTAssertEqual(
            tallerMap.descriptor.bodyHeight,
            tallerBodyFrame.height,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            liquidSurface.optics,
            DockLiquidGlassOptics.dock(bodyHeight: tallerBodyFrame.height)
        )
    }

    @MainActor
    func testIceForwardsHitsIntoContentAboveItsBody() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Liquid Glass requires macOS 26")
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
        view.configure(
            transparency: 0.17,
            blurStrength: 0.5,
            bodyHeight: 72,
            style: .ice
        )
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
            throw XCTSkip("Liquid Glass requires macOS 26")
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
        XCTAssertTrue(
            backgroundView.subviews.compactMap {
                $0 as? DockLiquidGlassSurfaceView
            }.isEmpty
        )
        XCTAssertEqual(descendants(of: NSScrollView.self, in: backgroundView).count, 1)

        apply(style: .ice)
        let iceSurface = try XCTUnwrap(
            backgroundView.subviews.compactMap {
                $0 as? DockLiquidGlassSurfaceView
            }.first
        )
        XCTAssertFalse(isDescendant(scrollView, of: iceSurface))
        XCTAssertTrue(
            backgroundView.subviews.compactMap { $0 as? NSGlassEffectView }.isEmpty
        )
        XCTAssertTrue(firstDescendant(
            of: NSScrollView.self,
            in: backgroundView
        ) === scrollView)
        XCTAssertEqual(descendants(of: NSScrollView.self, in: backgroundView).count, 1)

        apply(style: .classic)
        XCTAssertEqual(dock.subviews.count, 1)
        XCTAssertTrue(isDescendant(scrollView, of: backgroundView))
        XCTAssertTrue(
            backgroundView.subviews.compactMap {
                $0 as? DockLiquidGlassSurfaceView
            }.isEmpty
        )
        XCTAssertTrue(
            backgroundView.subviews.compactMap { $0 as? NSGlassEffectView }.isEmpty
        )
        XCTAssertTrue(firstDescendant(
            of: NSScrollView.self,
            in: backgroundView
        ) === scrollView)
        XCTAssertEqual(descendants(of: NSScrollView.self, in: backgroundView).count, 1)

        apply(style: .liquidGlass)
        let secondGlass = try XCTUnwrap(
            backgroundView.subviews.compactMap { $0 as? NSGlassEffectView }.first
        )
        let secondGlassContentProxy = try XCTUnwrap(secondGlass.contentView)
        XCTAssertFalse(isDescendant(scrollView, of: secondGlass))
        XCTAssertFalse(firstGlass === secondGlass)
        XCTAssertNil(firstDescendant(
            of: NSScrollView.self,
            in: secondGlassContentProxy
        ))
        XCTAssertTrue(
            backgroundView.subviews.compactMap {
                $0 as? DockLiquidGlassSurfaceView
            }.isEmpty
        )
        XCTAssertTrue(firstDescendant(
            of: NSScrollView.self,
            in: backgroundView
        ) === scrollView)
        XCTAssertEqual(descendants(of: NSScrollView.self, in: backgroundView).count, 1)
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

    private func descendants<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> [View] {
        var matches = root is View ? [root as! View] : []
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: subview))
        }
        return matches
    }
}
