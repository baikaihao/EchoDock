import AppKit
import QuartzCore

struct DockBackgroundAccessibilityOptions: Equatable {
    let reduceTransparency: Bool
    let increaseContrast: Bool
    let reduceMotion: Bool
}

enum DockBackgroundMaterial: Equatable {
    case solid
    case visualEffect
    case liquidGlass
}

struct DockBackgroundSurfaceConfiguration: Equatable {
    let material: DockBackgroundMaterial
    let increasesContrast: Bool

    static func resolve(
        supportsLiquidGlass: Bool,
        selectedStyle: DockBackgroundStyle,
        accessibility: DockBackgroundAccessibilityOptions
    ) -> DockBackgroundSurfaceConfiguration {
        let usesLiquidGlass = supportsLiquidGlass && selectedStyle == .liquidGlass
        if usesLiquidGlass {
            return DockBackgroundSurfaceConfiguration(
                material: .liquidGlass,
                increasesContrast: accessibility.increaseContrast
            )
        }

        if accessibility.reduceTransparency {
            return DockBackgroundSurfaceConfiguration(
                material: .solid,
                increasesContrast: accessibility.increaseContrast
            )
        }

        return DockBackgroundSurfaceConfiguration(
            material: .visualEffect,
            increasesContrast: accessibility.increaseContrast
        )
    }
}

enum DockBackgroundSurfaceLayout {
    static func rootFrame(
        material: DockBackgroundMaterial,
        bounds: NSRect,
        bodyRect: NSRect
    ) -> NSRect {
        material == .liquidGlass ? bodyRect : bounds
    }

    static func usesVisibilityMask(material: DockBackgroundMaterial) -> Bool {
        material != .liquidGlass
    }
}

enum DockBackgroundGaussianBlur {
    static let maximumRadius: CGFloat = 40
    static let bodyHeightRadiusScale: CGFloat = 0.6

    static func radius(
        strength: CGFloat,
        bodyHeight: CGFloat
    ) -> CGFloat {
        let effectiveMaximum = min(
            maximumRadius,
            max(0, bodyHeight) * bodyHeightRadiusScale
        )
        let normalizedStrength = DockBackgroundBlur.clamped(strength)
        return effectiveMaximum * normalizedStrength * normalizedStrength
    }
}

enum DockBackgroundRim {
    static let fullVisibilityMaterialOpacity: CGFloat = 0.15

    static func visibility(forMaterialOpacity opacity: CGFloat) -> CGFloat {
        guard fullVisibilityMaterialOpacity > 0 else { return 0 }
        return min(1, max(0, opacity) / fullVisibilityMaterialOpacity)
    }
}

struct DockBackgroundInteractionState: Equatable {
    let visualContentFrame: NSRect

    static let idle = DockBackgroundInteractionState(
        visualContentFrame: .zero
    )
}

final class DockBackgroundSurfaceView: NSView {
    private static let gaussianBlurFilterName = "echoDockGaussianBlur"
    private static let gaussianBlurRadiusKeyPath =
        "filters.\(gaussianBlurFilterName).inputRadius"

    private let contentHost = NSView()
    private let rimLayer = CALayer()
    private let surfaceVisibilityMaskLayer = CALayer()
    private weak var hostedContentView: NSView?
    private weak var interactionRoot: NSView?
    private var hostedHitTest: ((NSPoint) -> NSView?)?
    private var surfaceRoot: NSView?
    private var baseSurface: NSView?
    private var gaussianBackdropSurface: DockGaussianBackdropView?
    private var gaussianBackdropFilter: NSObject?
    private var appliedGaussianRadius: CGFloat?
    private var configuration: DockBackgroundSurfaceConfiguration?
    private var transparency: CGFloat = 0.17
    private var blurStrength: CGFloat = DockBackgroundBlur.defaultValue
    private var bodyHeight: CGFloat = 72
    private var selectedStyle: DockBackgroundStyle = .liquidGlass
    private var visibleBodyFrame: NSRect?
    private var hostedContentFrame: NSRect?
    private var currentBodyRect: NSRect = .zero
    private var previousBounds: NSRect = .null
    private var previousBodyRect: NSRect = .null

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        layer?.shadowColor = nil
        layer?.shadowOpacity = 0
        layer?.shadowRadius = 0
        layer?.shadowOffset = .zero
        layer?.shadowPath = nil

        contentHost.clipsToBounds = false

        rimLayer.backgroundColor = nil
        rimLayer.borderWidth = 0.7
        rimLayer.cornerCurve = .continuous
        rimLayer.zPosition = 10
        layer?.addSublayer(rimLayer)

        surfaceVisibilityMaskLayer.backgroundColor = NSColor.black.cgColor
        surfaceVisibilityMaskLayer.cornerCurve = .continuous

        rebuildSurfaceIfNeeded()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden,
              alphaValue > 0,
              let interactionRoot else {
            return nil
        }
        let pointInInteractionRoot = interactionRoot.convert(point, from: self)
        if let hostedHit = hostedHitTest?(pointInInteractionRoot) {
            return hostedHit
        }
        return interactionRoot.hitTest(pointInInteractionRoot)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func configure(
        transparency: CGFloat,
        blurStrength: CGFloat,
        bodyHeight: CGFloat,
        style: DockBackgroundStyle
    ) {
        self.transparency = DockBackgroundTransparency.clamped(transparency)
        self.blurStrength = DockBackgroundBlur.clamped(blurStrength)
        self.bodyHeight = max(0, bodyHeight)
        selectedStyle = style
        rebuildSurfaceIfNeeded()
        applyVisualProperties()
        needsLayout = true
    }

    func setVisibleBodyFrame(_ frame: NSRect) {
        guard visibleBodyFrame.map({ NSEqualRects($0, frame) }) != true else { return }
        visibleBodyFrame = frame
        needsLayout = true
    }

    func hostContent(
        _ view: NSView,
        interactionRoot: NSView? = nil,
        hostedHitTest: ((NSPoint) -> NSView?)? = nil
    ) {
        if hostedContentView !== view {
            hostedContentView?.removeFromSuperview()
            view.removeFromSuperview()
            contentHost.addSubview(view)
            hostedContentView = view
        }
        self.interactionRoot = interactionRoot ?? view
        self.hostedHitTest = hostedHitTest
        attachContentHost()
        applyHostedContentFrame(bodyRect: currentBodyRect)
        needsLayout = true
    }

    /// The frame is expressed in this view's coordinates. Liquid Glass keeps
    /// its content root body-sized, so the hosted view receives the inverse
    /// body offset and stays fixed while the glass changes width and origin.
    func setHostedContentFrame(_ frame: NSRect) {
        guard hostedContentFrame.map({ NSEqualRects($0, frame) }) != true else { return }
        hostedContentFrame = frame
        applyHostedContentFrame(bodyRect: currentBodyRect)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }

        let defaultBodyRect = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: min(bodyHeight, bounds.height)
        )
        let requestedBodyRect = visibleBodyFrame ?? defaultBodyRect
        let intersection = requestedBodyRect.intersection(bounds)
        let bodyRect = intersection.isNull ? .zero : intersection
        currentBodyRect = bodyRect
        let cornerRadius = DockBackgroundGeometry.cornerRadius(
            forBodyHeight: bodyRect.height
        )
        let boundsChanged = !NSEqualRects(previousBounds, bounds)
        let bodyChanged = !NSEqualRects(previousBodyRect, bodyRect)
        let material = configuration?.material ?? .visualEffect
        guard bodyChanged || boundsChanged else {
            applyHostedContentFrame(bodyRect: bodyRect)
            return
        }
        let targetRootFrame = DockBackgroundSurfaceLayout.rootFrame(
            material: material,
            bounds: bounds,
            bodyRect: bodyRect
        )
        let rootFrameChanged = surfaceRoot.map {
            !NSEqualRects($0.frame, targetRootFrame)
        } ?? false
        if boundsChanged || bodyChanged || rootFrameChanged {
            surfaceRoot?.frame = targetRootFrame
            let surfaceBounds = surfaceRoot?.bounds
                ?? NSRect(origin: .zero, size: targetRootFrame.size)
            if let baseSurface, baseSurface !== surfaceRoot {
                baseSurface.frame = surfaceBounds
            }
            gaussianBackdropSurface?.frame = surfaceBounds
        }

        let radiusChanged = previousBodyRect.isNull
            || abs(previousBodyRect.height - bodyRect.height) > 0.000_1
        if radiusChanged || boundsChanged {
            if #available(macOS 26.0, *),
               let baseGlass = baseSurface as? NSGlassEffectView {
                baseGlass.cornerRadius = cornerRadius
            } else {
                baseSurface?.layer?.cornerRadius = cornerRadius
                baseSurface?.layer?.cornerCurve = .continuous
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if DockBackgroundSurfaceLayout.usesVisibilityMask(material: material) {
            updateSurfaceVisibilityMask(
                bodyRect: bodyRect,
                cornerRadius: cornerRadius
            )
        } else {
            surfaceRoot?.layer?.mask = nil
        }
        updateRim(bodyRect: bodyRect, cornerRadius: cornerRadius)
        CATransaction.commit()
        applyHostedContentFrame(bodyRect: bodyRect)
        previousBounds = bounds
        previousBodyRect = bodyRect
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyVisualProperties()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        previousBounds = .null
        previousBodyRect = .null
        applyVisualProperties()
        needsLayout = true
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        rebuildSurfaceIfNeeded()
        applyVisualProperties()
        needsLayout = true
    }

    private var currentAccessibilityOptions: DockBackgroundAccessibilityOptions {
        let workspace = NSWorkspace.shared
        return DockBackgroundAccessibilityOptions(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion
        )
    }

    private var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    private func rebuildSurfaceIfNeeded() {
        let resolved = DockBackgroundSurfaceConfiguration.resolve(
            supportsLiquidGlass: supportsLiquidGlass,
            selectedStyle: selectedStyle,
            accessibility: currentAccessibilityOptions
        )
        guard configuration != resolved else { return }
        configuration = resolved

        detachContentHostFromGlass()
        surfaceRoot?.layer?.mask = nil
        surfaceRoot?.removeFromSuperview()
        surfaceRoot = nil
        baseSurface = nil
        gaussianBackdropSurface = nil
        gaussianBackdropFilter = nil
        appliedGaussianRadius = nil
        previousBounds = .null
        previousBodyRect = .null

        switch resolved.material {
        case .solid:
            let solidView = NSView()
            solidView.wantsLayer = true
            solidView.layer?.masksToBounds = true
            surfaceRoot = solidView
            baseSurface = solidView
            addSubview(solidView)

        case .visualEffect:
            if supportsLiquidGlass {
                installClassicSurface()
            } else {
                let effectView = makeClassicEffectView()
                surfaceRoot = effectView
                baseSurface = effectView
                addSubview(effectView)
            }

        case .liquidGlass:
            if #available(macOS 26.0, *) {
                installLiquidGlassSurface()
            }
        }

        attachContentHost()
        applyVisualProperties()
        needsLayout = true
    }

    private func installClassicSurface() {
        let host = NSView()
        host.wantsLayer = true
        host.clipsToBounds = true
        host.layer?.masksToBounds = true

        let gaussianBackdrop = makeGaussianBackdropSurface()
        let effectView = makeClassicEffectView()
        host.addSubview(gaussianBackdrop.view)
        host.addSubview(effectView, positioned: .above, relativeTo: gaussianBackdrop.view)

        surfaceRoot = host
        baseSurface = effectView
        gaussianBackdropSurface = gaussianBackdrop.view
        gaussianBackdropFilter = gaussianBackdrop.filter
        addSubview(host)
    }

    private func makeClassicEffectView() -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.material = .menu
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.masksToBounds = true
        return effectView
    }

    private func makeGaussianBackdropSurface() -> (
        view: DockGaussianBackdropView,
        filter: NSObject?
    ) {
        let view = DockGaussianBackdropView()
        view.wantsLayer = true
        view.clipsToBounds = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.masksToBounds = true
        return (view, DockGaussianBackdropRuntime.makeGaussianBlurFilter())
    }

    @available(macOS 26.0, *)
    private func installLiquidGlassSurface() {
        let baseGlass = NSGlassEffectView()
        baseGlass.style = .clear
        baseGlass.tintColor = nil
        baseGlass.clipsToBounds = false
        baseGlass.layer?.masksToBounds = false
        surfaceRoot = baseGlass
        baseSurface = baseGlass
        addSubview(baseGlass)
    }

    private func detachContentHostFromGlass() {
        if #available(macOS 26.0, *),
           let glass = baseSurface as? NSGlassEffectView,
           glass.contentView === contentHost {
            glass.contentView = nil
        }
        contentHost.removeFromSuperview()
    }

    private func attachContentHost() {
        guard let configuration, let surfaceRoot else { return }
        switch configuration.material {
        case .liquidGlass:
            if #available(macOS 26.0, *),
               let glass = baseSurface as? NSGlassEffectView {
                if glass.contentView !== contentHost {
                    contentHost.removeFromSuperview()
                    glass.contentView = contentHost
                }
                glass.clipsToBounds = false
                glass.layer?.masksToBounds = false
                contentHost.clipsToBounds = false
                contentHost.superview?.clipsToBounds = false
                contentHost.superview?.layer?.masksToBounds = false
            }
        case .solid, .visualEffect:
            if contentHost.superview !== self {
                contentHost.removeFromSuperview()
                addSubview(contentHost, positioned: .above, relativeTo: surfaceRoot)
            }
            if !NSEqualRects(contentHost.frame, bounds) {
                contentHost.frame = bounds
            }
        }
        applyHostedContentFrame(bodyRect: currentBodyRect)
    }

    private func applyHostedContentFrame(bodyRect: NSRect) {
        guard let hostedContentView, let hostedContentFrame else { return }
        let targetFrame: NSRect
        if configuration?.material == .liquidGlass {
            targetFrame = hostedContentFrame.offsetBy(
                dx: -bodyRect.minX,
                dy: -bodyRect.minY
            )
        } else {
            if contentHost.superview === self,
               !NSEqualRects(contentHost.frame, bounds) {
                contentHost.frame = bounds
            }
            targetFrame = hostedContentFrame
        }
        if !NSEqualRects(hostedContentView.frame, targetFrame) {
            hostedContentView.frame = targetFrame
        }
    }

    private func applyGaussianBlur(radius: CGFloat, opacity: CGFloat) {
        guard let surface = gaussianBackdropSurface,
              let layer = surface.backdropLayer,
              let gaussianFilter = gaussianBackdropFilter else {
            gaussianBackdropSurface?.isHidden = true
            return
        }
        let radius = max(0, radius)
        let opacity = min(1, max(0, opacity))
        let isVisible = radius > 0.000_1 && opacity > 0.000_1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !isVisible {
            if layer.filters != nil {
                layer.filters = nil
            }
            layer.opacity = 0
            CATransaction.commit()
            appliedGaussianRadius = nil
            surface.isHidden = true
            return
        }

        if layer.filters == nil {
            gaussianFilter.setValue(radius, forKey: "inputRadius")
            layer.filters = [gaussianFilter]
        } else if appliedGaussianRadius != radius {
            layer.setValue(
                radius,
                forKeyPath: Self.gaussianBlurRadiusKeyPath
            )
        }
        layer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        layer.opacity = Float(opacity)
        CATransaction.commit()
        appliedGaussianRadius = radius
        surface.isHidden = false
    }

    private func applyVisualProperties() {
        guard let configuration else { return }
        let requestedOpacity = DockBackgroundTransparency.materialOpacity(
            for: transparency
        )
        let materialOpacity = configuration.increasesContrast
            ? max(0.68, requestedOpacity)
            : requestedOpacity

        switch configuration.material {
        case .solid:
            surfaceRoot?.alphaValue = 1
            surfaceRoot?.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        case .visualEffect:
            surfaceRoot?.alphaValue = 1
            baseSurface?.alphaValue = materialOpacity
            let radius = DockBackgroundGaussianBlur.radius(
                strength: blurStrength,
                bodyHeight: bodyHeight
            )
            applyGaussianBlur(
                radius: radius,
                opacity: materialOpacity
            )

        case .liquidGlass:
            if #available(macOS 26.0, *) {
                if let glass = baseSurface as? NSGlassEffectView {
                    glass.style = .clear
                    glass.tintColor = nil
                    // alphaValue fades the complete composite, including the
                    // content, refraction, and specular edge. Native glass has
                    // no public material-opacity control, so keep it intact.
                    glass.alphaValue = 1
                    glass.isHidden = false
                }
            }
        }

        let rimVisibility: CGFloat
        switch configuration.material {
        case .liquidGlass:
            // Preserve NSGlassEffectView's dynamic refractive edge instead of
            // covering it with a uniform CALayer border.
            rimVisibility = 0
        case .solid:
            rimVisibility = 1
        case .visualEffect:
            rimVisibility = DockBackgroundRim.visibility(
                forMaterialOpacity: materialOpacity
            )
        }
        let baseRimAlpha = configuration.increasesContrast
            ? 0.62
            : 0.20 + materialOpacity * 0.34
        rimLayer.isHidden = rimVisibility <= 0.000_1
        rimLayer.borderColor = rimLayer.isHidden
            ? nil
            : NSColor.white.withAlphaComponent(
                baseRimAlpha * rimVisibility
            ).cgColor
    }

    private func updateSurfaceVisibilityMask(
        bodyRect: NSRect,
        cornerRadius: CGFloat
    ) {
        guard let surfaceRoot, let rootLayer = surfaceRoot.layer else { return }
        let localBodyRect = convert(bodyRect, to: surfaceRoot)
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2

        surfaceVisibilityMaskLayer.frame = localBodyRect
        surfaceVisibilityMaskLayer.cornerRadius = cornerRadius
        surfaceVisibilityMaskLayer.contentsScale = scale
        if rootLayer.mask !== surfaceVisibilityMaskLayer {
            rootLayer.mask = surfaceVisibilityMaskLayer
        }
    }

    private func updateRim(bodyRect: NSRect, cornerRadius: CGFloat) {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2

        rimLayer.frame = bodyRect
        rimLayer.cornerRadius = cornerRadius
        rimLayer.contentsScale = scale
    }
}

private enum DockGaussianBackdropRuntime {
    private static let backdropLayerClassName = "CABackdropLayer"
    private static let filterClassName = "CAFilter"

    static func makeBehindWindowLayer() -> CALayer? {
        guard let layerClass = NSClassFromString(backdropLayerClassName)
            as? NSObject.Type,
              let unmanagedLayer = layerClass.perform(
                NSSelectorFromString("behindWindowLayer")
              ),
              let layer = unmanagedLayer.takeUnretainedValue() as? CALayer else {
            return nil
        }

        let scaleSetter = NSSelectorFromString("setScale:")
        if layer.responds(to: scaleSetter) {
            layer.setValue(CGFloat(1), forKey: "scale")
        }
        return layer
    }

    static func isBackdropLayer(_ layer: CALayer) -> Bool {
        guard let layerClass = NSClassFromString(backdropLayerClassName) else {
            return false
        }
        return layer.isKind(of: layerClass)
    }

    static func makeGaussianBlurFilter() -> NSObject? {
        guard let filterClass = NSClassFromString(filterClassName) as? NSObject.Type,
              let unmanagedFilter = filterClass.perform(
                NSSelectorFromString("filterWithType:"),
                with: "gaussianBlur"
              ),
              let filter = unmanagedFilter.takeUnretainedValue() as? NSObject else {
            return nil
        }
        filter.setValue("echoDockGaussianBlur", forKey: "name")
        filter.setValue(0, forKey: "inputRadius")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        filter.setValue(true, forKey: "inputDither")
        return filter
    }
}

private final class DockGaussianBackdropView: NSView {
    override func makeBackingLayer() -> CALayer {
        DockGaussianBackdropRuntime.makeBehindWindowLayer()
            ?? super.makeBackingLayer()
    }

    var backdropLayer: CALayer? {
        guard let layer, DockGaussianBackdropRuntime.isBackdropLayer(layer) else {
            return nil
        }
        return layer
    }
}
