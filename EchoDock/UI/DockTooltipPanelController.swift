import AppKit
import QuartzCore

struct DockTooltipPresentation {
    let text: String
    let anchorScreenRect: NSRect
    let gap: CGFloat
    let screenFrame: NSRect
    let backingScaleFactor: CGFloat
}

enum DockTooltipStyle {
    static let labelFontSize: CGFloat = 14
    static let labelFontVariationWeight: CGFloat = 350
    static let visualHeight: CGFloat = 34
    static let tailHeight: CGFloat = 5
    static let labelHeight: CGFloat = 17
    static let horizontalTextPadding: CGFloat = 13
    // Keep optical correction on the text layer so the bubble and its tail
    // remain anchored to the icon's true center.
    static let labelOpticalHorizontalOffset: CGFloat = -0.5
    static let labelOpticalVerticalOffset: CGFloat = 0
    static let tailHalfWidth: CGFloat = 6
    static let tailTipInset: CGFloat = 0.5
    static let shadowBlurRadius: CGFloat = 7
    static let shadowOpacity: Float = 0.08
    static let shadowOffset = NSSize(width: 0, height: -0.5)
    static let shadowInsets = NSEdgeInsets(top: 14, left: 14, bottom: 15, right: 14)
    static let highlightTopLightOpacity: CGFloat = 0.22
    static let highlightMiddleLightOpacity: CGFloat = 0.06
    static let highlightTopDarkOpacity: CGFloat = 0.12
    static let highlightMiddleDarkOpacity: CGFloat = 0.03
    static let highlightStartPoint = CGPoint(x: 0.5, y: 1)
    static let highlightEndPoint = CGPoint(x: 0.5, y: 0.46)
    static let horizontalScreenMargin: CGFloat = 4

    static func edgeInset(backingScaleFactor: CGFloat) -> CGFloat {
        backingScaleFactor >= 2 ? 0.5 : 0
    }

    static func alignedLabelFittingWidth(
        for label: NSTextField,
        backingScaleFactor: CGFloat
    ) -> CGFloat {
        let scale = max(1, backingScaleFactor)
        return ceil(label.fittingSize.width * scale) / scale
    }

    static var labelFont: NSFont {
        let baseFont = NSFont.systemFont(ofSize: labelFontSize, weight: .regular)
        let weightAxis = NSNumber(value: UInt32(0x7767_6874)) // OpenType "wght"
        let descriptor = baseFont.fontDescriptor.addingAttributes([
            .variation: [weightAxis: NSNumber(value: Double(labelFontVariationWeight))]
        ])
        return NSFont(descriptor: descriptor, size: labelFontSize) ?? baseFont
    }

    static var totalHeight: CGFloat {
        visualHeight + shadowInsets.top + shadowInsets.bottom
    }

    static func visualContentRect(in bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.minX + shadowInsets.left,
            y: bounds.minY + shadowInsets.bottom,
            width: max(0, bounds.width - shadowInsets.left - shadowInsets.right),
            height: max(0, bounds.height - shadowInsets.top - shadowInsets.bottom)
        )
    }

    static func bubbleRect(
        in bounds: NSRect,
        backingScaleFactor: CGFloat = 2
    ) -> NSRect {
        let content = visualContentRect(in: bounds)
        let inset = edgeInset(backingScaleFactor: backingScaleFactor)
        return NSRect(
            x: content.minX + inset,
            y: content.minY + tailHeight,
            width: max(0, content.width - inset * 2),
            height: max(0, content.height - tailHeight - inset)
        )
    }

    static func tailTipY(
        in bounds: NSRect,
        backingScaleFactor: CGFloat = 2
    ) -> CGFloat {
        visualContentRect(in: bounds).minY
            + edgeInset(backingScaleFactor: backingScaleFactor)
    }

    static func labelFrame(
        in bounds: NSRect,
        backingScaleFactor: CGFloat = 2
    ) -> NSRect {
        let body = bubbleRect(
            in: bounds,
            backingScaleFactor: backingScaleFactor
        )
        let scale = max(1, backingScaleFactor)
        let rawX = body.minX
            + horizontalTextPadding
            + labelOpticalHorizontalOffset
        let rawY = body.midY
            - labelHeight / 2
            + labelOpticalVerticalOffset
        return NSRect(
            x: (rawX * scale).rounded() / scale,
            y: (rawY * scale).rounded() / scale,
            width: max(0, body.width - horizontalTextPadding * 2),
            height: labelHeight
        )
    }

    static func panelOrigin(
        anchorScreenRect: NSRect,
        gap: CGFloat,
        screenFrame: NSRect,
        panelSize: NSSize,
        backingScaleFactor: CGFloat
    ) -> NSPoint {
        let visualWidth = max(
            0,
            panelSize.width - shadowInsets.left - shadowInsets.right
        )
        let idealX = anchorScreenRect.midX - shadowInsets.left - visualWidth / 2
        let minimumX = screenFrame.minX + horizontalScreenMargin
        let maximumX = screenFrame.maxX - panelSize.width - horizontalScreenMargin
        let clampedX = min(max(minimumX, idealX), max(minimumX, maximumX))
        let scale = max(1, backingScaleFactor)
        let alignedX = (clampedX * scale).rounded() / scale
        let alignedY = (
            (anchorScreenRect.maxY + gap - shadowInsets.bottom) * scale
        ).rounded() / scale
        return NSPoint(
            x: min(max(minimumX, alignedX), max(minimumX, maximumX)),
            y: alignedY
        )
    }

    static func arrowX(
        anchorScreenRect: NSRect,
        panelOriginX: CGFloat,
        backingScaleFactor: CGFloat
    ) -> CGFloat {
        let scale = max(1, backingScaleFactor)
        return ((anchorScreenRect.midX - panelOriginX) * scale).rounded() / scale
    }
}

struct DockTooltipFadeState {
    static let duration: TimeInterval = 0.18

    private(set) var activeGeneration: UInt64?
    private var generation: UInt64 = 0

    var isActive: Bool { activeGeneration != nil }

    mutating func begin() -> UInt64 {
        generation &+= 1
        activeGeneration = generation
        return generation
    }

    mutating func cancel() {
        generation &+= 1
        activeGeneration = nil
    }

    mutating func complete(_ candidate: UInt64) -> Bool {
        guard activeGeneration == candidate else { return false }
        activeGeneration = nil
        return true
    }
}

struct DockTooltipPanelUpdatePlan: Equatable {
    let cancelsFade: Bool
    let updatesFrame: Bool
    let ordersFront: Bool

    static func make(
        currentFrame: NSRect,
        targetFrame: NSRect,
        isVisible: Bool,
        isFadeActive: Bool
    ) -> DockTooltipPanelUpdatePlan {
        DockTooltipPanelUpdatePlan(
            cancelsFade: isFadeActive,
            updatesFrame: !NSEqualRects(currentFrame, targetFrame),
            ordersFront: !isVisible
        )
    }
}

enum DockTooltipOpacity {
    static let fadeAnimationKey = "EchoDock.tooltip.fadeOut"

    static func restoreFullOpacity(layer: CALayer, panel: NSWindow) {
        panel.alphaValue = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: fadeAnimationKey)
        layer.opacity = 1
        CATransaction.commit()
    }
}

/// Hosts app-name labels outside the interactive Dock window. A transparent
/// NSPanel still consumes clicks anywhere in its frame, so keeping this panel
/// mouse-transparent lets the label float above other apps without blocking
/// their controls.
@MainActor
final class DockTooltipPanelController {
    private let panel = DockTooltipPanel()
    private let bubbleView = DockTooltipBubbleView()
    private var fadeState = DockTooltipFadeState()
    private var cachedFittingSize: NSSize?

    init() {
        panel.contentView = bubbleView
    }

    func present(_ presentation: DockTooltipPresentation?) {
        guard let presentation else {
            fadeOut()
            return
        }

        let contentChanged = abs(
            bubbleView.renderScale - presentation.backingScaleFactor
        ) > 0.001 || bubbleView.text != presentation.text
        if contentChanged {
            bubbleView.renderScale = presentation.backingScaleFactor
            bubbleView.text = presentation.text
            cachedFittingSize = bubbleView.fittingSize
        }
        let size = cachedFittingSize ?? bubbleView.fittingSize
        cachedFittingSize = size
        let origin = DockTooltipStyle.panelOrigin(
            anchorScreenRect: presentation.anchorScreenRect,
            gap: presentation.gap,
            screenFrame: presentation.screenFrame,
            panelSize: size,
            backingScaleFactor: presentation.backingScaleFactor
        )
        bubbleView.arrowX = DockTooltipStyle.arrowX(
            anchorScreenRect: presentation.anchorScreenRect,
            panelOriginX: origin.x,
            backingScaleFactor: presentation.backingScaleFactor
        )
        let targetFrame = NSRect(origin: origin, size: size)
        let updatePlan = DockTooltipPanelUpdatePlan.make(
            currentFrame: panel.frame,
            targetFrame: targetFrame,
            isVisible: panel.isVisible,
            isFadeActive: fadeState.isActive
        )
        if updatePlan.cancelsFade {
            cancelFadeOut()
        }
        if updatePlan.updatesFrame {
            panel.setFrame(targetFrame, display: false)
        }
        if updatePlan.ordersFront {
            panel.orderFrontRegardless()
        }
    }

    /// Immediately removes the tooltip for Dock teardown or an explicit hide.
    func hide() {
        if fadeState.isActive {
            cancelFadeOut()
        }
        panel.orderOut(nil)
    }

    private func fadeOut() {
        guard panel.isVisible, !fadeState.isActive else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = bubbleView.layer else {
            hide()
            return
        }

        let generation = fadeState.begin()
        let startOpacity = layer.presentation()?.opacity ?? layer.opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = startOpacity
        animation.toValue = 0
        animation.duration = DockTooltipFadeState.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishFadeOut(generation: generation)
            }
        }
        layer.opacity = 0
        layer.add(animation, forKey: DockTooltipOpacity.fadeAnimationKey)
        CATransaction.commit()
    }

    private func cancelFadeOut() {
        guard fadeState.isActive else { return }
        fadeState.cancel()
        restoreFullOpacity()
    }

    private func finishFadeOut(generation: UInt64) {
        guard fadeState.complete(generation) else { return }
        panel.orderOut(nil)
        restoreFullOpacity()
    }

    private func restoreFullOpacity() {
        guard let layer = bubbleView.layer else {
            panel.alphaValue = 1
            return
        }
        DockTooltipOpacity.restoreFullOpacity(layer: layer, panel: panel)
    }
}

final class DockTooltipPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // The WindowServer shadow has a hard contact edge around small shaped
        // windows. The bubble view draws a tunable soft shadow instead.
        hasShadow = false
        acceptsMouseMovedEvents = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DockTooltipBubbleView: NSView {
    private let bubbleLayer = CAShapeLayer()
    private let highlightLayer = CAGradientLayer()
    private let highlightMaskLayer = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private var storedRenderScale: CGFloat = 2

    var renderScale: CGFloat {
        get { storedRenderScale }
        set {
            let normalizedScale = max(1, newValue)
            guard abs(normalizedScale - storedRenderScale) > 0.001 else { return }
            storedRenderScale = normalizedScale
            frame.size = fittingSize
            needsLayout = true
        }
    }

    var arrowX: CGFloat = 0 {
        didSet {
            guard abs(arrowX - oldValue) > 0.01 else { return }
            needsLayout = true
        }
    }

    var text: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
            frame.size = fittingSize
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        bubbleLayer.fillColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.95)
            .cgColor
        bubbleLayer.strokeColor = nil
        bubbleLayer.shadowColor = NSColor.black.cgColor
        bubbleLayer.shadowOpacity = DockTooltipStyle.shadowOpacity
        bubbleLayer.shadowRadius = DockTooltipStyle.shadowBlurRadius
        bubbleLayer.shadowOffset = DockTooltipStyle.shadowOffset
        bubbleLayer.masksToBounds = false
        layer?.addSublayer(bubbleLayer)

        highlightLayer.startPoint = DockTooltipStyle.highlightStartPoint
        highlightLayer.endPoint = DockTooltipStyle.highlightEndPoint
        highlightLayer.locations = [0, 0.46, 1]
        highlightLayer.masksToBounds = false
        highlightMaskLayer.fillColor = NSColor.black.cgColor
        highlightLayer.mask = highlightMaskLayer
        layer?.insertSublayer(highlightLayer, above: bubbleLayer)

        label.font = DockTooltipStyle.labelFont
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.usesSingleLineMode = true
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var fittingSize: NSSize {
        let alignedLabelWidth = DockTooltipStyle.alignedLabelFittingWidth(
            for: label,
            backingScaleFactor: renderScale
        )
        let edgeInset = DockTooltipStyle.edgeInset(
            backingScaleFactor: renderScale
        )
        let visualWidth = max(
            54,
            alignedLabelWidth
                + DockTooltipStyle.horizontalTextPadding * 2
                + edgeInset * 2
        )
        return NSSize(
            width: visualWidth
                + DockTooltipStyle.shadowInsets.left
                + DockTooltipStyle.shadowInsets.right,
            height: DockTooltipStyle.totalHeight
        )
    }

    override func layout() {
        super.layout()
        label.frame = DockTooltipStyle.labelFrame(
            in: bounds,
            backingScaleFactor: renderScale
        )
        label.layer?.contentsScale = renderScale
        updateBubbleLayer()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBubbleLayer()
    }

    private func updateBubbleLayer() {
        guard bounds.width > 0, bounds.height > DockTooltipStyle.tailHeight else {
            bubbleLayer.path = nil
            highlightMaskLayer.path = nil
            return
        }

        let bubbleRect = DockTooltipStyle.bubbleRect(
            in: bounds,
            backingScaleFactor: renderScale
        )
        let cornerRadius = bubbleRect.height / 2
        let tailCenter = min(
            max(
                arrowX,
                bubbleRect.minX + cornerRadius + DockTooltipStyle.tailHalfWidth
            ),
            bubbleRect.maxX - cornerRadius - DockTooltipStyle.tailHalfWidth
        )
        let path = continuousBubblePath(
            in: bubbleRect,
            cornerRadius: cornerRadius,
            tailCenter: tailCenter,
            tailHalfWidth: DockTooltipStyle.tailHalfWidth,
            tailTipY: DockTooltipStyle.tailTipY(
                in: bounds,
                backingScaleFactor: renderScale
            )
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubbleLayer.frame = bounds
        bubbleLayer.contentsScale = renderScale
        bubbleLayer.fillColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.95)
            .cgColor
        bubbleLayer.path = path
        bubbleLayer.shadowPath = path
        highlightLayer.frame = bounds
        highlightLayer.contentsScale = renderScale
        highlightLayer.colors = highlightColors.map(\.cgColor)
        highlightMaskLayer.frame = bounds
        highlightMaskLayer.contentsScale = renderScale
        highlightMaskLayer.path = path
        CATransaction.commit()
    }

    private var highlightColors: [NSColor] {
        let isDark = effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        let topOpacity = isDark
            ? DockTooltipStyle.highlightTopDarkOpacity
            : DockTooltipStyle.highlightTopLightOpacity
        let middleOpacity = isDark
            ? DockTooltipStyle.highlightMiddleDarkOpacity
            : DockTooltipStyle.highlightMiddleLightOpacity
        return [
            NSColor.white.withAlphaComponent(topOpacity),
            NSColor.white.withAlphaComponent(middleOpacity),
            .clear
        ]
    }

    private func continuousBubblePath(
        in rect: NSRect,
        cornerRadius radius: CGFloat,
        tailCenter: CGFloat,
        tailHalfWidth: CGFloat,
        tailTipY: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()

        path.move(to: NSPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: NSPoint(x: tailCenter - tailHalfWidth, y: rect.minY))
        path.addCurve(
            to: NSPoint(x: tailCenter, y: tailTipY),
            control1: NSPoint(x: tailCenter - 4.5, y: rect.minY),
            control2: NSPoint(x: tailCenter - 1.5, y: tailTipY + 1.1)
        )
        path.addCurve(
            to: NSPoint(x: tailCenter + tailHalfWidth, y: rect.minY),
            control1: NSPoint(x: tailCenter + 1.5, y: tailTipY + 1.1),
            control2: NSPoint(x: tailCenter + 4.5, y: rect.minY)
        )
        path.addLine(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.addCurve(
            to: NSPoint(x: rect.maxX, y: rect.minY + radius),
            control1: NSPoint(x: rect.maxX - radius * 0.45, y: rect.minY),
            control2: NSPoint(x: rect.maxX, y: rect.minY + radius * 0.45)
        )
        path.addLine(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addCurve(
            to: NSPoint(x: rect.maxX - radius, y: rect.maxY),
            control1: NSPoint(x: rect.maxX, y: rect.maxY - radius * 0.45),
            control2: NSPoint(x: rect.maxX - radius * 0.45, y: rect.maxY)
        )
        path.addLine(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.addCurve(
            to: NSPoint(x: rect.minX, y: rect.maxY - radius),
            control1: NSPoint(x: rect.minX + radius * 0.45, y: rect.maxY),
            control2: NSPoint(x: rect.minX, y: rect.maxY - radius * 0.45)
        )
        path.addLine(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.addCurve(
            to: NSPoint(x: rect.minX + radius, y: rect.minY),
            control1: NSPoint(x: rect.minX, y: rect.minY + radius * 0.45),
            control2: NSPoint(x: rect.minX + radius * 0.45, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
