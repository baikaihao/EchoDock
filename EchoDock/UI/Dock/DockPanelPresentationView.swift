import AppKit
import QuartzCore

/// Keeps window sizing separate from the content's reveal/hide transition.
@MainActor
final class DockPanelPresentationView: NSView {
    private static let animationKey = "echoDockVisibility"
    private static let transitionDuration: TimeInterval = 0.18
    var position: DockPosition = .bottom { didSet { if position != oldValue { reset() } } }
    private let presentedView: NSView
    private var animationGeneration: UInt64 = 0
    private var isAnimating = false

    init(presentedView: NSView) {
        self.presentedView = presentedView
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        autoresizesSubviews = false
        presentedView.autoresizingMask = []
        addSubview(presentedView)
    }

    required init?(coder: NSCoder) { nil }

    func prepareForReveal(animated: Bool, reduceMotion: Bool) {
        cancelAnimation()
        setPresentation(
            offset: animated && !reduceMotion ? position.hiddenOffset(for: presentedView.frame.size) : .zero,
            alpha: animated ? 0 : 1
        )
    }

    func setVisible(
        _ visible: Bool,
        animated: Bool,
        reduceMotion: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        cancelAnimation()
        let generation = animationGeneration
        if reduceMotion {
            setPresentation(offset: .zero, alpha: layer?.opacity ?? 1)
        }
        let targetOffset: NSPoint = visible || reduceMotion ? .zero : position.hiddenOffset(for: presentedView.frame.size)
        let targetAlpha: Float = visible ? 1 : 0
        guard animated, let layer else {
            setPresentation(offset: targetOffset, alpha: targetAlpha)
            completion()
            return
        }

        // Commit the initial, hidden pose before changing the animation target.
        // This also gives native glass a chance to build its backing layers.
        window?.displayIfNeeded()
        CATransaction.flush()
        let duration = Self.transitionDuration
        var animations: [CABasicAnimation] = []
        if layer.sublayerTransform.m41 != targetOffset.x || layer.sublayerTransform.m42 != targetOffset.y {
            let slide = CABasicAnimation(keyPath: "sublayerTransform")
            slide.fromValue = NSValue(caTransform3D: layer.sublayerTransform)
            slide.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(targetOffset.x, targetOffset.y, 0))
            slide.duration = duration
            animations.append(slide)
        }
        if layer.opacity != targetAlpha {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity
            fade.toValue = targetAlpha
            fade.duration = duration
            animations.append(fade)
        }
        guard !animations.isEmpty else {
            completion()
            return
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.timingFunction = Self.timingFunction(reversed: !visible)

        isAnimating = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == generation else { return }
                self.isAnimating = false
                completion()
            }
        }
        setPresentation(offset: targetOffset, alpha: targetAlpha)
        layer.add(group, forKey: Self.animationKey)
        CATransaction.commit()
    }

    func reset() {
        cancelAnimation()
        setPresentation(offset: .zero, alpha: 1)
    }

    private static func timingFunction(reversed: Bool) -> CAMediaTimingFunction {
        let reveal: (x1: Float, y1: Float, x2: Float, y2: Float) = (0.23, 1, 0.32, 1)
        // Swapping the endpoints alone is not time reversal. Reflect both
        // control points so hiding follows the reveal animation backward.
        if reversed {
            return CAMediaTimingFunction(
                controlPoints: 1 - reveal.x2, 1 - reveal.y2, 1 - reveal.x1, 1 - reveal.y1
            )
        }
        return CAMediaTimingFunction(controlPoints: reveal.x1, reveal.y1, reveal.x2, reveal.y2)
    }

    private func cancelAnimation() {
        animationGeneration &+= 1
        guard isAnimating else { return }
        isAnimating = false
        guard let layer else { return }
        let rendered = layer.presentation() ?? layer
        let offset = NSPoint(x: rendered.sublayerTransform.m41, y: rendered.sublayerTransform.m42)
        let alpha = rendered.opacity
        layer.removeAnimation(forKey: Self.animationKey)
        setPresentation(offset: offset, alpha: alpha)
    }

    private func setPresentation(offset: NSPoint, alpha: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Keep NSView frames inside the window throughout the exit. Moving a
        // view's layout frame out of its parent can cull native glass before
        // its animation finishes. The compositor alone moves the sublayers.
        layer?.sublayerTransform = CATransform3DMakeTranslation(offset.x, offset.y, 0)
        layer?.opacity = alpha
        CATransaction.commit()
    }
}
