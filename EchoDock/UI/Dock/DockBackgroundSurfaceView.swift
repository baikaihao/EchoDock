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
    case ice
}

struct DockBackgroundSurfaceConfiguration: Equatable {
    let material: DockBackgroundMaterial
    let increasesContrast: Bool

    static func resolve(
        supportsLiquidGlass: Bool,
        selectedStyle: DockBackgroundStyle,
        accessibility: DockBackgroundAccessibilityOptions
    ) -> DockBackgroundSurfaceConfiguration {
        if supportsLiquidGlass && selectedStyle == .liquidGlass {
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

        if supportsLiquidGlass && selectedStyle == .ice {
            return DockBackgroundSurfaceConfiguration(
                material: .ice,
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
        material != .liquidGlass && material != .ice
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

    static func pixelAligned(_ rect: NSRect, scale: CGFloat) -> NSRect {
        let scale = max(1, scale)
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return NSRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    static func visibility(forMaterialOpacity opacity: CGFloat) -> CGFloat {
        guard fullVisibilityMaterialOpacity > 0 else { return 0 }
        return min(1, max(0, opacity) / fullVisibilityMaterialOpacity)
    }
}

struct DockLiquidGlassOptics: Equatable {
    static let dock = dock(bodyHeight: 72)

    static func dock(bodyHeight: CGFloat) -> DockLiquidGlassOptics {
        let height = max(0, bodyHeight)
        let refractionAmount = -0.42 * height
        let maximumRefractionOffset = 0.24 * height
        let sampleMargin = min(
            64,
            max(
                32,
                maximumRefractionOffset + 2
            )
        )
        return DockLiquidGlassOptics(
            captureScale: 1,
            sampleMargin: sampleMargin,
            innerRefractionAmount: refractionAmount,
            innerRefractionHeight: 0.127 * height,
            indexOfRefraction: 1.45,
            maximumRefractionOffset: maximumRefractionOffset,
            faceFillAlpha: 0.1,
            keyLightAmount: 0.72,
            fillLightAmount: 0.22
        )
    }

    let captureScale: CGFloat
    let sampleMargin: CGFloat
    let innerRefractionAmount: CGFloat
    let innerRefractionHeight: CGFloat
    let indexOfRefraction: CGFloat
    let maximumRefractionOffset: CGFloat
    let faceFillAlpha: CGFloat
    let keyLightAmount: CGFloat
    let fillLightAmount: CGFloat
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
    private let glassContentProxy = NSView()
    private let rimLayer = CALayer()
    private let liquidOuterRimLayer = CAShapeLayer()
    private let liquidSpecularRimLayer = CAGradientLayer()
    private let liquidSpecularRimMaskLayer = CAShapeLayer()
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

        contentHost.wantsLayer = true
        contentHost.clipsToBounds = false
        contentHost.layer?.masksToBounds = false
        // Keep the icon/interaction host above the classic background rim.
        // The rim is intentionally above the material surface, but must not
        // draw over icon artwork or magnification layers.
        contentHost.layer?.zPosition = 20

        glassContentProxy.wantsLayer = true
        glassContentProxy.clipsToBounds = false
        glassContentProxy.layer?.masksToBounds = false

        rimLayer.backgroundColor = nil
        rimLayer.borderWidth = 0.7
        rimLayer.cornerCurve = .continuous
        rimLayer.zPosition = 10
        layer?.addSublayer(rimLayer)

        liquidOuterRimLayer.fillColor = nil
        liquidOuterRimLayer.name = "echoDockLiquidOuterRim"
        liquidOuterRimLayer.strokeColor = NSColor.white
            .withAlphaComponent(0.16).cgColor
        liquidOuterRimLayer.zPosition = -2
        liquidOuterRimLayer.isHidden = true
        liquidOuterRimLayer.shouldRasterize = false
        contentHost.layer?.addSublayer(liquidOuterRimLayer)

        liquidSpecularRimLayer.colors = [
            NSColor.white.withAlphaComponent(0.48).cgColor,
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.white.withAlphaComponent(0.08).cgColor,
            NSColor.white.withAlphaComponent(0.05).cgColor
        ]
        liquidSpecularRimLayer.name = "echoDockLiquidSpecularRim"
        liquidSpecularRimLayer.locations = [0, 0.32, 0.70, 1]
        liquidSpecularRimLayer.startPoint = CGPoint(x: 0.5, y: 1)
        liquidSpecularRimLayer.endPoint = CGPoint(x: 0.5, y: 0)
        liquidSpecularRimLayer.zPosition = -1
        liquidSpecularRimLayer.isHidden = true
        liquidSpecularRimLayer.shouldRasterize = false
        liquidSpecularRimMaskLayer.fillColor = nil
        liquidSpecularRimMaskLayer.name = "echoDockLiquidSpecularRimMask"
        liquidSpecularRimMaskLayer.strokeColor = NSColor.black.cgColor
        liquidSpecularRimMaskLayer.shouldRasterize = false
        liquidSpecularRimLayer.mask = liquidSpecularRimMaskLayer
        contentHost.layer?.addSublayer(liquidSpecularRimLayer)

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
        if let hostedHitTest {
            if let hostedHit = hostedHitTest(pointInInteractionRoot) {
                return hostedHit
            }
            return interactionRoot.bounds.contains(pointInInteractionRoot)
                ? interactionRoot
                : nil
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

    /// The frame is expressed in this view's coordinates. The hosted content
    /// stays in the full-height overlay while the glass body changes width.
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
            forBodyHeight: min(bodyRect.width, bodyRect.height)
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
        if boundsChanged || rootFrameChanged {
            surfaceRoot?.frame = targetRootFrame
            let surfaceBounds = surfaceRoot?.bounds
                ?? NSRect(origin: .zero, size: targetRootFrame.size)
            if let baseSurface, baseSurface !== surfaceRoot {
                baseSurface.frame = surfaceBounds
            }
            gaussianBackdropSurface?.frame = surfaceBounds
        }

        let radiusChanged = previousBodyRect.isNull
            || abs(previousBodyRect.width - bodyRect.width) > 0.000_1
            || abs(previousBodyRect.height - bodyRect.height) > 0.000_1
        if let iceSurface = baseSurface as? DockLiquidGlassSurfaceView {
            if bodyChanged || radiusChanged || boundsChanged {
                let localBodyRect = convert(bodyRect, to: iceSurface)
                iceSurface.updateGeometry(
                    bodyRect: localBodyRect,
                    cornerRadius: cornerRadius,
                    backingScale: window?.backingScaleFactor
                        ?? NSScreen.main?.backingScaleFactor
                        ?? 2
                )
            }
        } else if #available(macOS 26.0, *),
                  let glass = baseSurface as? NSGlassEffectView {
            if radiusChanged || boundsChanged {
                glass.cornerRadius = cornerRadius
            }
        } else if radiusChanged || boundsChanged {
            baseSurface?.layer?.cornerRadius = cornerRadius
            baseSurface?.layer?.cornerCurve = .continuous
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

        detachContentHost()
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

        case .ice:
            if #available(macOS 26.0, *) {
                installIceSurface()
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
        let glass = NSGlassEffectView()
        glass.style = .clear
        glass.tintColor = nil
        glass.clipsToBounds = false
        glass.layer?.masksToBounds = false
        surfaceRoot = glass
        baseSurface = glass
        addSubview(glass)
    }

    @available(macOS 26.0, *)
    private func installIceSurface() {
        let liquidSurface = DockLiquidGlassSurfaceView()
        surfaceRoot = liquidSurface
        baseSurface = liquidSurface
        addSubview(liquidSurface)
    }

    private func detachContentHost() {
        if #available(macOS 26.0, *),
           let glass = baseSurface as? NSGlassEffectView,
           glass.contentView === glassContentProxy {
            glass.contentView = nil
        }
        glassContentProxy.removeFromSuperview()
        contentHost.removeFromSuperview()
    }

    private func attachContentHost() {
        guard let configuration, let surfaceRoot else { return }
        switch configuration.material {
        case .liquidGlass:
            if #available(macOS 26.0, *),
               let glass = baseSurface as? NSGlassEffectView {
                if glass.contentView !== glassContentProxy {
                    glassContentProxy.removeFromSuperview()
                    glass.contentView = glassContentProxy
                }
                glass.clipsToBounds = false
                glass.layer?.masksToBounds = false
            }
            attachContentHostAboveSurface(surfaceRoot)
        case .ice:
            attachContentHostAboveSurface(surfaceRoot)
        case .solid, .visualEffect:
            attachContentHostAboveSurface(surfaceRoot)
        }
        applyHostedContentFrame(bodyRect: currentBodyRect)
    }

    private func attachContentHostAboveSurface(_ surfaceRoot: NSView) {
        if contentHost.superview !== self {
            contentHost.removeFromSuperview()
            addSubview(contentHost, positioned: .above, relativeTo: surfaceRoot)
        }
        contentHost.clipsToBounds = false
        contentHost.layer?.masksToBounds = false
        if !NSEqualRects(contentHost.frame, bounds) {
            contentHost.frame = bounds
        }
    }

    private func applyHostedContentFrame(bodyRect _: NSRect) {
        if contentHost.superview === self,
           !NSEqualRects(contentHost.frame, bounds) {
            contentHost.frame = bounds
        }
        guard let hostedContentView, let hostedContentFrame else { return }
        if !NSEqualRects(hostedContentView.frame, hostedContentFrame) {
            hostedContentView.frame = hostedContentFrame
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
            if #available(macOS 26.0, *),
               let glass = baseSurface as? NSGlassEffectView {
                glass.style = .clear
                glass.tintColor = nil
                glass.alphaValue = 1
                glass.isHidden = false
            }
            contentHost.alphaValue = 1

        case .ice:
            if let iceSurface = baseSurface as? DockLiquidGlassSurfaceView {
                iceSurface.configure(
                    materialOpacity: materialOpacity,
                    increasesContrast: configuration.increasesContrast
                )
                iceSurface.isHidden = false
            }
            contentHost.alphaValue = 1
        }

        let rimVisibility: CGFloat
        switch configuration.material {
        case .liquidGlass, .ice:
            // Native glass and Ice each provide their own geometry-aware edge.
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

        let showsLiquidRim = configuration.material == .liquidGlass
        liquidOuterRimLayer.isHidden = !showsLiquidRim
        liquidSpecularRimLayer.isHidden = !showsLiquidRim
        if showsLiquidRim {
            let contrastBoost: CGFloat = configuration.increasesContrast ? 1.35 : 1
            liquidOuterRimLayer.strokeColor = NSColor.white
                .withAlphaComponent(min(1, 0.16 * contrastBoost)).cgColor
            liquidSpecularRimLayer.colors = [0.48, 0.22, 0.08, 0.05].map {
                NSColor.white.withAlphaComponent(
                    min(1, $0 * contrastBoost)
                ).cgColor
            }
        }

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
        let pixel = 1 / max(1, scale)
        let alignedBodyRect = DockBackgroundRim.pixelAligned(
            bodyRect,
            scale: scale
        )
        let liquidRimFrame = contentHost.convert(
            alignedBodyRect,
            from: self
        )

        rimLayer.frame = bodyRect
        rimLayer.cornerRadius = cornerRadius
        rimLayer.contentsScale = scale

        liquidOuterRimLayer.frame = liquidRimFrame
        liquidOuterRimLayer.contentsScale = scale
        liquidOuterRimLayer.lineWidth = pixel
        let outerBounds = liquidOuterRimLayer.bounds.insetBy(
            dx: pixel / 2,
            dy: pixel / 2
        )
        let outerRadius = max(0, cornerRadius - pixel / 2)
        if outerBounds.width > 0, outerBounds.height > 0 {
            liquidOuterRimLayer.path = CGPath(
                roundedRect: outerBounds,
                cornerWidth: outerRadius,
                cornerHeight: outerRadius,
                transform: nil
            )
        } else {
            liquidOuterRimLayer.path = nil
        }

        liquidSpecularRimLayer.frame = liquidRimFrame
        liquidSpecularRimLayer.contentsScale = scale
        liquidSpecularRimMaskLayer.frame = liquidSpecularRimLayer.bounds
        liquidSpecularRimMaskLayer.contentsScale = scale
        liquidSpecularRimMaskLayer.lineWidth = pixel
        let innerInset = pixel * 1.5
        let innerBounds = liquidSpecularRimLayer.bounds.insetBy(
            dx: innerInset,
            dy: innerInset
        )
        let innerRadius = max(0, cornerRadius - innerInset)
        if innerBounds.width > 0, innerBounds.height > 0 {
            liquidSpecularRimMaskLayer.path = CGPath(
                roundedRect: innerBounds,
                cornerWidth: innerRadius,
                cornerHeight: innerRadius,
                transform: nil
            )
        } else {
            liquidSpecularRimMaskLayer.path = nil
        }
    }

}
