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
            bodyHeight: renderedBodyRect.height
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
            bodyHeight: renderedBodyRect.height,
            cornerRadius: renderedCornerRadius,
            backingScale: renderedBackingScale,
            optics: optics
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

private enum DockLiquidGlassRuntime {
    static func makeBackdropLayer() -> CALayer? {
        DockGaussianBackdropRuntime.makeBehindWindowLayer()
    }

    static func isBackdropLayer(_ layer: CALayer) -> Bool {
        DockGaussianBackdropRuntime.isBackdropLayer(layer)
    }

    static func makeFilter(type: String, name: String) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let unmanagedFilter = filterClass.perform(
                  NSSelectorFromString("filterWithType:"),
                  with: type
              ),
              let filter = unmanagedFilter.takeUnretainedValue()
                as? NSObject else {
            return nil
        }
        filter.setValue(name, forKey: "name")
        return filter
    }

    static func filter(
        _ filter: NSObject,
        supports requiredInputs: Set<String>
    ) -> Bool {
        let availableInputs = Set(
            filter.value(forKey: "inputKeys") as? [String] ?? []
        )
        return requiredInputs.isSubset(of: availableInputs)
    }

    static func setProperty(_ value: Any, key: String, on object: NSObject) {
        let setterName = "set"
            + key.prefix(1).uppercased()
            + String(key.dropFirst())
            + ":"
        guard object.responds(to: NSSelectorFromString(setterName)) else { return }
        object.setValue(value, forKey: key)
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
