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
    private let rimLayer = CAShapeLayer()
    private var surfaceRoot: NSView?
    private var baseSurface: NSView?
    private var opaqueBackingSurface: NSView?
    private var configuration: DockBackgroundSurfaceConfiguration?
    private var transparency: CGFloat = 0.17
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
        bodyHeight: CGFloat,
        style: DockBackgroundStyle
    ) {
        self.transparency = DockBackgroundTransparency.clamped(transparency)
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
                baseSurface?.frame = bodyRect
                opaqueBackingSurface?.frame = bodyRect
                opaqueBackingSurface?.layer?.cornerRadius = cornerRadius
                opaqueBackingSurface?.layer?.cornerCurve = .continuous
                if #available(macOS 26.0, *),
                   let baseGlass = baseSurface as? NSGlassEffectView {
                    baseGlass.cornerRadius = cornerRadius
                }
            }

        case .solid, .visualEffect:
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
        opaqueBackingSurface = nil
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
            let effectView = NSVisualEffectView()
            effectView.material = .menu
            effectView.blendingMode = .behindWindow
            effectView.state = .active
            effectView.wantsLayer = true
            effectView.layer?.masksToBounds = true
            surfaceRoot = effectView
            baseSurface = effectView
            addSubview(effectView)

        case .liquidGlass:
            if #available(macOS 26.0, *) {
                installLiquidGlassSurface()
            }
        }

        applyVisualProperties()
        needsLayout = true
    }

    @available(macOS 26.0, *)
    private func installLiquidGlassSurface() {
        let host = NSView()
        host.wantsLayer = true
        host.clipsToBounds = false
        host.layer?.masksToBounds = false

        let baseGlass = NSGlassEffectView()
        let opaqueBacking = NSView()
        opaqueBacking.wantsLayer = true
        opaqueBacking.layer?.masksToBounds = true
        host.addSubview(baseGlass)
        host.addSubview(opaqueBacking, positioned: .above, relativeTo: baseGlass)

        surfaceRoot = host
        baseSurface = baseGlass
        opaqueBackingSurface = opaqueBacking
        addSubview(host)
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
            surfaceRoot?.alphaValue = materialOpacity

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
                opaqueBackingSurface?.alphaValue = DockLiquidGlassTransparency
                    .opaqueBackingAlpha(for: transparency)
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
