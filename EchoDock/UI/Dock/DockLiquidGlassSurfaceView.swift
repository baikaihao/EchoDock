import AppKit
import QuartzCore

final class DockLiquidGlassSurfaceView: NSView {
    private static let disabledLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "position": NSNull(),
        "path": NSNull(),
        "contents": NSNull(),
        "contentsCenter": NSNull(),
        "cornerRadius": NSNull(),
        "hidden": NSNull(),
        "opacity": NSNull(),
        "filters": NSNull(),
        "sublayers": NSNull()
    ]

    private(set) var optics = DockLiquidGlassOptics.dock
    private(set) var backdropLayer: CALayer?
    private(set) var displacementMapLayer: CALayer?
    private(set) var displacementMap: DockLiquidGlassDisplacementMap?
    private(set) var displacementFilter: NSObject?
    private(set) var isUsingCustomRenderer = false
    private(set) var renderedCornerRadius: CGFloat = 0
    private(set) var renderedBackingScale: CGFloat = 2
    private(set) var renderedBodyRect: NSRect = .zero
    private(set) var materialOpacity: CGFloat = 1
    private(set) var mapGenerationCount = 0
    private(set) var geometryApplicationCount = 0

    private var increasesContrast = false
    private var appliedBounds: NSRect = .null
    private var appliedBodyRect: NSRect = .null
    private var appliedCornerRadius: CGFloat = -1
    private var appliedBackingScale: CGFloat = 0
    private let faceLayer = CAShapeLayer()
    private let keyHighlightLayer = CAGradientLayer()
    private let keyHighlightMaskLayer = CAShapeLayer()
    private let fillEdgeLayer = CAGradientLayer()
    private let fillEdgeMaskLayer = CAShapeLayer()
    private let bottomRightHighlightLayer = CAGradientLayer()
    private let bottomRightHighlightMaskLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        layer?.actions = Self.disabledLayerActions
        installLayerTree()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry(
            bodyRect: renderedBodyRect,
            cornerRadius: renderedCornerRadius,
            backingScale: window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
        )
    }

    func configure(
        materialOpacity: CGFloat,
        increasesContrast: Bool
    ) {
        let opacity = min(1, max(0, materialOpacity))
        guard abs(self.materialOpacity - opacity) > 0.000_1
                || self.increasesContrast != increasesContrast else {
            return
        }

        self.materialOpacity = opacity
        self.increasesContrast = increasesContrast
        updateLightingAppearance()
        alphaValue = opacity
    }

    func updateGeometry(
        bodyRect: NSRect,
        cornerRadius: CGFloat,
        backingScale: CGFloat
    ) {
        let resolvedBodyRect = bodyRect.intersection(bounds)
        let visibleBodyRect = resolvedBodyRect.isNull ? .zero : resolvedBodyRect
        let radius = max(0, cornerRadius)
        let scale = max(1, backingScale)
        guard !NSEqualRects(renderedBodyRect, visibleBodyRect)
                || abs(renderedCornerRadius - radius) > 0.000_1
                || abs(renderedBackingScale - scale) > 0.000_1 else {
            return
        }
        renderedBodyRect = visibleBodyRect
        renderedCornerRadius = radius
        renderedBackingScale = scale
        applyGeometry()
    }

    private func installLayerTree() {
        guard let rootLayer = layer else { return }

        prepareLightingLayers()

        let backdropLayer = DockLiquidGlassRuntime.makeBackdropLayer() ?? CALayer()
        backdropLayer.actions = Self.disabledLayerActions
        backdropLayer.masksToBounds = false
        backdropLayer.backgroundColor = NSColor.white
            .withAlphaComponent(0.001).cgColor
        DockLiquidGlassRuntime.setProperty(
            optics.captureScale,
            key: "scale",
            on: backdropLayer
        )
        DockLiquidGlassRuntime.setProperty(
            optics.sampleMargin,
            key: "marginWidth",
            on: backdropLayer
        )
        DockLiquidGlassRuntime.setProperty(
            false,
            key: "reducesCaptureBitDepth",
            on: backdropLayer
        )
        DockLiquidGlassRuntime.setProperty(
            true,
            key: "windowServerAware",
            on: backdropLayer
        )
        rootLayer.addSublayer(backdropLayer)
        self.backdropLayer = backdropLayer

        let displacementMapLayer = makeMapLayer(
            name: DockLiquidGlassMapRenderer.displacementSourceLayerName
        )
        backdropLayer.addSublayer(displacementMapLayer)
        self.displacementMapLayer = displacementMapLayer

        rootLayer.addSublayer(faceLayer)
        rootLayer.addSublayer(keyHighlightLayer)
        rootLayer.addSublayer(fillEdgeLayer)
        rootLayer.addSublayer(bottomRightHighlightLayer)
        installCompositorFilters()
        updateLightingAppearance()
    }

    private func makeMapLayer(name: String) -> CALayer {
        let mapLayer = CALayer()
        mapLayer.name = name
        mapLayer.actions = Self.disabledLayerActions
        mapLayer.contentsGravity = .resize
        mapLayer.minificationFilter = .linear
        mapLayer.magnificationFilter = .linear
        return mapLayer
    }

    private func prepareLightingLayers() {
        let lightingLayers: [CALayer] = [
            faceLayer,
            keyHighlightLayer,
            keyHighlightMaskLayer,
            fillEdgeLayer,
            fillEdgeMaskLayer,
            bottomRightHighlightLayer,
            bottomRightHighlightMaskLayer
        ]
        for lightingLayer in lightingLayers {
            lightingLayer.actions = Self.disabledLayerActions
            lightingLayer.contentsScale = renderedBackingScale
        }

        faceLayer.fillColor = NSColor.white.withAlphaComponent(0.025).cgColor

        keyHighlightLayer.startPoint = CGPoint(x: 0.05, y: 0.95)
        keyHighlightLayer.endPoint = CGPoint(x: 0.95, y: 0.05)
        keyHighlightLayer.mask = keyHighlightMaskLayer
        keyHighlightMaskLayer.fillColor = nil
        keyHighlightMaskLayer.strokeColor = NSColor.white.cgColor

        fillEdgeLayer.startPoint = CGPoint(x: 0.05, y: 0.95)
        fillEdgeLayer.endPoint = CGPoint(x: 0.95, y: 0.05)
        fillEdgeLayer.mask = fillEdgeMaskLayer
        fillEdgeMaskLayer.fillColor = nil
        fillEdgeMaskLayer.strokeColor = NSColor.white.cgColor

        bottomRightHighlightLayer.name = "echoDockIceBottomRightHighlight"
        bottomRightHighlightLayer.startPoint = CGPoint(x: 0, y: 1)
        bottomRightHighlightLayer.endPoint = CGPoint(x: 1, y: 0)
        bottomRightHighlightLayer.mask = bottomRightHighlightMaskLayer
        bottomRightHighlightMaskLayer.name = "echoDockIceBottomRightHighlightMask"
        bottomRightHighlightMaskLayer.fillColor = nil
        bottomRightHighlightMaskLayer.strokeColor = NSColor.white.cgColor
    }

    private func applyGeometry() {
        guard let rootLayer = layer,
              let backdropLayer,
              let displacementMapLayer else { return }
        guard !NSEqualRects(appliedBounds, bounds)
                || !NSEqualRects(appliedBodyRect, renderedBodyRect)
                || abs(appliedCornerRadius - renderedCornerRadius) > 0.000_1
                || abs(appliedBackingScale - renderedBackingScale) > 0.000_1 else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let opticsChanged = updateOpticsForCurrentHeight(on: backdropLayer)
        applyCanvasGeometry(
            to: backdropLayer,
            frame: renderedBodyRect,
            contentsScale: renderedBackingScale
        )
        let localBodyBounds = NSRect(
            origin: .zero,
            size: renderedBodyRect.size
        )
        applyCanvasGeometry(
            to: displacementMapLayer,
            frame: localBodyBounds,
            contentsScale: renderedBackingScale
        )
        rebuildDisplacementMapIfNeeded()
        if opticsChanged {
            installCompositorFilters()
            updateLightingAppearance()
        }
        updateLightingGeometry(rootLayer: rootLayer)
        CATransaction.commit()
        appliedBounds = bounds
        appliedBodyRect = renderedBodyRect
        appliedCornerRadius = renderedCornerRadius
        appliedBackingScale = renderedBackingScale
        geometryApplicationCount += 1
    }

    private func applyCanvasGeometry(
        to layer: CALayer?,
        frame: NSRect?,
        contentsScale: CGFloat
    ) {
        guard let layer else { return }
        if let frame, !NSEqualRects(layer.frame, frame) {
            layer.frame = frame
        }
        if layer.contentsScale != contentsScale {
            layer.contentsScale = contentsScale
        }
    }

    @discardableResult
    private func updateOpticsForCurrentHeight(on backdropLayer: CALayer) -> Bool {
        guard renderedBodyRect.height > 0 else { return false }
        let resolved = DockLiquidGlassOptics.dock(
            bodyHeight: min(renderedBodyRect.width, renderedBodyRect.height)
        )
        guard resolved != optics else { return false }
        optics = resolved

        DockLiquidGlassRuntime.setProperty(
            resolved.captureScale,
            key: "scale",
            on: backdropLayer
        )
        DockLiquidGlassRuntime.setProperty(
            resolved.sampleMargin,
            key: "marginWidth",
            on: backdropLayer
        )
        return true
    }

    private func rebuildDisplacementMapIfNeeded() {
        guard renderedBodyRect.height > 0,
              let displacementMapLayer else { return }
        let descriptor = DockLiquidGlassMapDescriptor(
            bodyHeight: min(renderedBodyRect.width, renderedBodyRect.height),
            cornerRadius: renderedCornerRadius,
            backingScale: renderedBackingScale,
            optics: optics,
            isVertical: renderedBodyRect.height > renderedBodyRect.width
        )
        guard displacementMap?.descriptor != descriptor,
              let map = DockLiquidGlassMapRenderer.makeMap(
                  descriptor: descriptor
              ) else {
            return
        }
        displacementMap = map
        mapGenerationCount += 1
        displacementMapLayer.contents = map.image
        displacementMapLayer.contentsCenter = map.contentsCenter
    }

    private func installCompositorFilters() {
        guard let backdropLayer,
              DockLiquidGlassRuntime.isBackdropLayer(backdropLayer),
              let displacement = DockLiquidGlassRuntime.makeFilter(
                  type: "displacementMap",
                  name: "echoDockDisplacement"
              ) else {
            installFallbackRenderer()
            return
        }
        let requiredInputs: Set<String> = [
            "inputAmount",
            "inputOffset",
            "inputSourceSublayerName"
        ]
        guard DockLiquidGlassRuntime.filter(
                  displacement,
                  supports: requiredInputs
              ) else {
            installFallbackRenderer()
            return
        }

        let offset = NSValue(point: NSPoint(x: 0.5, y: 0.5))
        displacement.setValue(
            NSNumber(value: Double(optics.maximumRefractionOffset * 2)),
            forKey: "inputAmount"
        )
        displacement.setValue(offset, forKey: "inputOffset")
        displacement.setValue(
            DockLiquidGlassMapRenderer.displacementSourceLayerName,
            forKey: "inputSourceSublayerName"
        )

        backdropLayer.filters = [displacement]
        guard backdropLayer.filters?.count == 1 else {
            installFallbackRenderer()
            return
        }
        backdropLayer.backgroundColor = NSColor.white
            .withAlphaComponent(0.001).cgColor
        displacementMapLayer?.isHidden = false
        displacementFilter = displacement
        isUsingCustomRenderer = true
    }

    private func installFallbackRenderer() {
        backdropLayer?.filters = nil
        backdropLayer?.backgroundColor = NSColor.white
            .withAlphaComponent(optics.faceFillAlpha).cgColor
        displacementMapLayer?.isHidden = true
        displacementFilter = nil
        isUsingCustomRenderer = false
    }

    private func updateLightingGeometry(rootLayer: CALayer) {
        let scale = max(1, renderedBackingScale)
        let lineInset = 0.5 / scale
        let bodyPath = CGPath(
            roundedRect: renderedBodyRect,
            cornerWidth: renderedCornerRadius,
            cornerHeight: renderedCornerRadius,
            transform: nil
        )
        let highlightRect = renderedBodyRect.insetBy(
            dx: lineInset,
            dy: lineInset
        )
        let highlightRadius = max(0, renderedCornerRadius - lineInset)
        let highlightPath = CGPath(
            roundedRect: highlightRect,
            cornerWidth: highlightRadius,
            cornerHeight: highlightRadius,
            transform: nil
        )

        faceLayer.frame = rootLayer.bounds
        faceLayer.path = bodyPath

        keyHighlightLayer.frame = rootLayer.bounds
        keyHighlightMaskLayer.frame = rootLayer.bounds
        keyHighlightMaskLayer.path = highlightPath
        keyHighlightMaskLayer.lineWidth = max(0.7, 1.15 / scale)

        fillEdgeLayer.frame = rootLayer.bounds
        fillEdgeMaskLayer.frame = rootLayer.bounds
        fillEdgeMaskLayer.path = highlightPath
        fillEdgeMaskLayer.lineWidth = max(0.7, 1.1 / scale)

        let bottomRightPath = CGMutablePath()
        let bottomRightStartX = highlightRect.minX + highlightRect.width * 0.54
        let bottomRightEndY = highlightRect.minY + highlightRect.height * 0.50
        bottomRightPath.move(to: CGPoint(
            x: bottomRightStartX,
            y: highlightRect.minY
        ))
        bottomRightPath.addLine(to: CGPoint(
            x: highlightRect.maxX - highlightRadius,
            y: highlightRect.minY
        ))
        bottomRightPath.addCurve(
            to: CGPoint(
                x: highlightRect.maxX,
                y: highlightRect.minY + highlightRadius
            ),
            control1: CGPoint(
                x: highlightRect.maxX - highlightRadius * 0.45,
                y: highlightRect.minY
            ),
            control2: CGPoint(
                x: highlightRect.maxX,
                y: highlightRect.minY + highlightRadius * 0.45
            )
        )
        bottomRightPath.addLine(to: CGPoint(
            x: highlightRect.maxX,
            y: bottomRightEndY
        ))
        bottomRightHighlightLayer.frame = rootLayer.bounds
        bottomRightHighlightMaskLayer.frame = rootLayer.bounds
        bottomRightHighlightMaskLayer.path = bottomRightPath
        bottomRightHighlightMaskLayer.lineWidth = max(0.7, 1.1 / scale)

        for lightingLayer in [
            faceLayer,
            keyHighlightLayer,
            keyHighlightMaskLayer,
            fillEdgeLayer,
            fillEdgeMaskLayer,
            bottomRightHighlightLayer,
            bottomRightHighlightMaskLayer
        ] {
            lightingLayer.contentsScale = scale
        }
    }

    private func updateLightingAppearance() {
        let contrastScale: CGFloat = increasesContrast ? 1.35 : 1
        let faceAlpha = min(0.12, optics.faceFillAlpha * 0.24 * contrastScale)
        faceLayer.fillColor = NSColor.white
            .withAlphaComponent(faceAlpha).cgColor

        keyHighlightLayer.colors = [
            NSColor.white.withAlphaComponent(
                min(0.78, optics.keyLightAmount * 0.78 * contrastScale)
            ).cgColor,
            NSColor.white.withAlphaComponent(
                min(0.65, optics.keyLightAmount * 0.52 * contrastScale)
            ).cgColor,
            NSColor.white.withAlphaComponent(0.04).cgColor,
            NSColor.white.withAlphaComponent(
                min(0.50, optics.keyLightAmount * 0.32 * contrastScale)
            ).cgColor
        ]
        keyHighlightLayer.locations = [0, 0.28, 0.67, 1]

        fillEdgeLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(
                min(0.30, optics.fillLightAmount * 0.62 * contrastScale)
            ).cgColor
        ]
        fillEdgeLayer.locations = [0, 0.58, 1]

        let bottomRightContrastScale: CGFloat = increasesContrast ? 1.25 : 1
        let bottomRightPeak = min(
            0.42,
            optics.keyLightAmount * 0.42 * bottomRightContrastScale
        )
        bottomRightHighlightLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(bottomRightPeak * 0.42).cgColor,
            NSColor.white.withAlphaComponent(bottomRightPeak).cgColor
        ]
        bottomRightHighlightLayer.locations = [0, 0.58, 0.84, 1]
    }
}

