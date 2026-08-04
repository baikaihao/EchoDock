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
    let usesRegularGlass: Bool

    static func resolve(
        supportsLiquidGlass: Bool,
        selectedStyle: DockBackgroundStyle,
        accessibility: DockBackgroundAccessibilityOptions
    ) -> DockBackgroundSurfaceConfiguration {
        if accessibility.reduceTransparency {
            return DockBackgroundSurfaceConfiguration(
                material: .solid,
                increasesContrast: accessibility.increaseContrast,
                usesRegularGlass: false
            )
        }

        let usesLiquidGlass = supportsLiquidGlass && selectedStyle == .liquidGlass

        return DockBackgroundSurfaceConfiguration(
            material: usesLiquidGlass ? .liquidGlass : .visualEffect,
            increasesContrast: accessibility.increaseContrast,
            usesRegularGlass: usesLiquidGlass && accessibility.increaseContrast
        )
    }
}

enum DockLiquidGlassTransparency {
    static let opaqueEndpointTransition: CGFloat = 0.12

    static func opaqueBackingAlpha(for transparency: CGFloat) -> CGFloat {
        let transparency = DockBackgroundTransparency.clamped(transparency)
        guard opaqueEndpointTransition > 0 else { return 0 }
        let progress = min(1, transparency / opaqueEndpointTransition)
        let easedProgress = progress * progress * (3 - 2 * progress)
        return 1 - easedProgress
    }

    static func hidesGlass(for transparency: CGFloat) -> Bool {
        let transparency = DockBackgroundTransparency.clamped(transparency)
        return transparency <= 0.000_1 || transparency >= 0.999_9
    }
}

enum DockLiquidGlassSupplementalBlur {
    static func opacity(
        materialOpacity: CGFloat,
        opaqueBackingAlpha: CGFloat
    ) -> CGFloat {
        min(1, max(0, materialOpacity))
            * (1 - min(1, max(0, opaqueBackingAlpha)))
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

    private let rimLayer = CAShapeLayer()
    private var surfaceRoot: NSView?
    private var baseSurface: NSView?
    private var gaussianBackdropSurface: DockGaussianBackdropView?
    private var opaqueBackingSurface: NSView?
    private var gaussianBackdropFilter: NSObject?
    private var appliedGaussianRadius: CGFloat?
    private var configuration: DockBackgroundSurfaceConfiguration?
    private var transparency: CGFloat = 0.17
    private var blurStrength: CGFloat = DockBackgroundBlur.defaultValue
    private var bodyHeight: CGFloat = 72
    private var selectedStyle: DockBackgroundStyle = .liquidGlass
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

        rimLayer.fillColor = nil
        rimLayer.lineWidth = 0.7
        rimLayer.zPosition = 10
        layer?.addSublayer(rimLayer)

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
        nil
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

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }

        let bodyRect = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: min(bodyHeight, bounds.height)
        )
        let cornerRadius = DockBackgroundGeometry.cornerRadius(
            forBodyHeight: bodyRect.height
        )
        let boundsChanged = !NSEqualRects(previousBounds, bounds)
        let bodyChanged = !NSEqualRects(previousBodyRect, bodyRect)

        switch configuration?.material {
        case .liquidGlass:
            if boundsChanged {
                surfaceRoot?.frame = bounds
            }
            if bodyChanged {
                gaussianBackdropSurface?.frame = bodyRect
                gaussianBackdropSurface?.layer?.cornerRadius = cornerRadius
                gaussianBackdropSurface?.layer?.cornerCurve = .continuous
                baseSurface?.frame = bodyRect
                opaqueBackingSurface?.frame = bodyRect
                opaqueBackingSurface?.layer?.cornerRadius = cornerRadius
                opaqueBackingSurface?.layer?.cornerCurve = .continuous
                if #available(macOS 26.0, *),
                   let baseGlass = baseSurface as? NSGlassEffectView {
                    baseGlass.cornerRadius = cornerRadius
                }
            }

        case .visualEffect:
            if bodyChanged {
                surfaceRoot?.frame = bodyRect
                surfaceRoot?.layer?.cornerRadius = cornerRadius
                surfaceRoot?.layer?.cornerCurve = .continuous
                let localBodyRect = NSRect(origin: .zero, size: bodyRect.size)
                gaussianBackdropSurface?.frame = localBodyRect
                gaussianBackdropSurface?.layer?.cornerRadius = cornerRadius
                gaussianBackdropSurface?.layer?.cornerCurve = .continuous
                baseSurface?.frame = localBodyRect
                baseSurface?.layer?.cornerRadius = cornerRadius
                baseSurface?.layer?.cornerCurve = .continuous
            }

        case .solid:
            if bodyChanged {
                surfaceRoot?.frame = bodyRect
                surfaceRoot?.layer?.cornerRadius = cornerRadius
                surfaceRoot?.layer?.cornerCurve = .continuous
            }

        case nil:
            break
        }

        if bodyChanged || boundsChanged {
            let rimRect = bodyRect.insetBy(dx: 0.35, dy: 0.35)
            let rimPath = CGPath(
                roundedRect: rimRect,
                cornerWidth: max(0, cornerRadius - 0.35),
                cornerHeight: max(0, cornerRadius - 0.35),
                transform: nil
            )
            rimLayer.frame = bounds
            rimLayer.contentsScale = window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
            rimLayer.path = rimPath
        }
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

        surfaceRoot?.removeFromSuperview()
        surfaceRoot = nil
        baseSurface = nil
        gaussianBackdropSurface = nil
        opaqueBackingSurface = nil
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
        let host = NSView()
        host.wantsLayer = true
        host.clipsToBounds = false
        host.layer?.masksToBounds = false

        let gaussianBackdrop = makeGaussianBackdropSurface()

        let baseGlass = NSGlassEffectView()
        let opaqueBacking = NSView()
        opaqueBacking.wantsLayer = true
        opaqueBacking.layer?.masksToBounds = true
        host.addSubview(gaussianBackdrop.view)
        host.addSubview(baseGlass, positioned: .above, relativeTo: gaussianBackdrop.view)
        host.addSubview(opaqueBacking, positioned: .above, relativeTo: baseGlass)

        surfaceRoot = host
        baseSurface = baseGlass
        gaussianBackdropSurface = gaussianBackdrop.view
        opaqueBackingSurface = opaqueBacking
        gaussianBackdropFilter = gaussianBackdrop.filter
        addSubview(host)
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
                let style: NSGlassEffectView.Style = configuration.usesRegularGlass
                    ? .regular
                    : .clear
                let tintAlpha = configuration.usesRegularGlass
                    ? 0.10
                    : 0.01 + materialOpacity * 0.05
                let tint = NSColor.white.withAlphaComponent(tintAlpha)
                if let glass = baseSurface as? NSGlassEffectView {
                    glass.style = style
                    glass.tintColor = tint
                    glass.alphaValue = materialOpacity
                    glass.isHidden = DockLiquidGlassTransparency.hidesGlass(
                        for: transparency
                    )
                }
                let opaqueBackingAlpha = DockLiquidGlassTransparency
                    .opaqueBackingAlpha(for: transparency)
                let supplementalBlurOpacity = DockLiquidGlassSupplementalBlur.opacity(
                    materialOpacity: materialOpacity,
                    opaqueBackingAlpha: opaqueBackingAlpha
                )
                let radius = DockBackgroundGaussianBlur.radius(
                    strength: blurStrength,
                    bodyHeight: bodyHeight
                )
                applyGaussianBlur(
                    radius: radius,
                    opacity: supplementalBlurOpacity
                )
                opaqueBackingSurface?.alphaValue = opaqueBackingAlpha
                opaqueBackingSurface?.layer?.backgroundColor = NSColor
                    .controlBackgroundColor.cgColor
            }
        }

        let rimVisibility = configuration.material == .solid
            ? 1
            : DockBackgroundRim.visibility(
                forMaterialOpacity: materialOpacity
            )
        let baseRimAlpha = configuration.increasesContrast
            ? 0.62
            : 0.20 + materialOpacity * 0.34
        rimLayer.strokeColor = NSColor.white.withAlphaComponent(
            baseRimAlpha * rimVisibility
        ).cgColor
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
