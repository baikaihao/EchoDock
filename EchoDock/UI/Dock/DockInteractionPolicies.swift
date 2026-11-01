import AppKit

struct DockHoverResolver {
    /// Keeps each button's horizontal slot while extending it through the
    /// complete vertical Dock region.
    static func hoverFrames(
        slotFrames: [NSRect?],
        in bounds: NSRect
    ) -> [NSRect] {
        guard bounds.width > 0, bounds.height > 0 else {
            return Array(repeating: .zero, count: slotFrames.count)
        }
        return slotFrames.map { slotFrame in
            guard let slotFrame, slotFrame.width > 0 else { return .zero }
            let minimumX = min(bounds.maxX, max(bounds.minX, slotFrame.minX))
            let maximumX = min(bounds.maxX, max(minimumX, slotFrame.maxX))
            return NSRect(
                x: minimumX,
                y: bounds.minY,
                width: maximumX - minimumX,
                height: bounds.height
            )
        }
    }

    static func hoveredIndex(
        at point: NSPoint,
        in bounds: NSRect,
        hoverFrames: [NSRect]
    ) -> Int? {
        guard bounds.contains(point) else { return nil }
        return hoverFrames.firstIndex(where: { $0.contains(point) })
    }
}

struct DockButtonPresentationGeometry: Equatable {
    let viewFrame: NSRect
    let visualSlotFrame: NSRect
    let visualSlotCenterOffsetX: CGFloat

    static func make(
        baseFrame: NSRect,
        visualFrame: NSRect
    ) -> DockButtonPresentationGeometry {
        DockButtonPresentationGeometry(
            viewFrame: baseFrame,
            visualSlotFrame: visualFrame,
            visualSlotCenterOffsetX: visualFrame.midX - baseFrame.midX
        )
    }
}

struct DockVisualButtonHitTarget: Equatable {
    let buttonIndex: Int
    let frame: NSRect
    let zPosition: CGFloat
}

enum DockVisualButtonHitResolver {
    static func buttonIndex(
        at point: NSPoint,
        targets: [DockVisualButtonHitTarget]
    ) -> Int? {
        var bestTarget: DockVisualButtonHitTarget?
        for target in targets where target.frame.contains(point) {
            guard let currentBest = bestTarget else {
                bestTarget = target
                continue
            }
            if target.zPosition > currentBest.zPosition
                || (target.zPosition == currentBest.zPosition
                    && target.buttonIndex > currentBest.buttonIndex) {
                bestTarget = target
            }
        }
        return bestTarget?.buttonIndex
    }
}

struct DockMagnificationHeadroomPolicy {
    static func isActive(
        magnificationEnabled: Bool,
        pointerInside: Bool,
        transitionValue: CGFloat
    ) -> Bool {
        magnificationEnabled
            && (pointerInside || transitionValue > 0)
    }

    static func preferredHeight(
        bodyHeight: CGFloat,
        maximumHeadroom: CGFloat,
        isActive: Bool
    ) -> CGFloat {
        max(0, bodyHeight) + (isActive ? max(0, maximumHeadroom) : 0)
    }
}

enum DockMagnificationRenderRequest {
    case pointerChanged
    case transitionTargetChanged
}

struct DockMagnificationRenderPlan: Equatable {
    let rendersImmediately: Bool
    let shouldRunFrameClock: Bool

    static func make(
        request: DockMagnificationRenderRequest,
        isTransitionSettled: Bool
    ) -> DockMagnificationRenderPlan {
        switch request {
        case .pointerChanged:
            return DockMagnificationRenderPlan(
                rendersImmediately: false,
                shouldRunFrameClock: true
            )
        case .transitionTargetChanged:
            return DockMagnificationRenderPlan(
                rendersImmediately: false,
                shouldRunFrameClock: !isTransitionSettled
            )
        }
    }
}

enum DockPointerSamplePolicy {
    static func hasChanged(
        from previousPoint: NSPoint?,
        to point: NSPoint,
        tolerance: CGFloat = 0.01
    ) -> Bool {
        guard let previousPoint else { return true }
        return abs(previousPoint.x - point.x) > tolerance
            || abs(previousPoint.y - point.y) > tolerance
    }
}

enum DockTrackingAreaEventPolicy {
    static func carriesTrackingArea(_ eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .mouseEntered, .mouseExited:
            return true
        default:
            return false
        }
    }
}

enum DockPointerExitPolicy {
    static func shouldCancelInteraction(pressedMouseButtons: Int) -> Bool {
        pressedMouseButtons == 0
    }
}

struct DockPointerSampleSequence {
    private(set) var lastAcceptedTimestamp: TimeInterval?

    mutating func accept(_ timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite else { return false }
        if let lastAcceptedTimestamp,
           timestamp <= lastAcceptedTimestamp {
            return false
        }
        lastAcceptedTimestamp = timestamp
        return true
    }

    mutating func discardSamples(before timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        lastAcceptedTimestamp = max(lastAcceptedTimestamp ?? timestamp, timestamp)
    }
}

enum DockMagnificationFrameClockPolicy {
    static let pointerIdleGrace: CFTimeInterval = 0.05

    static func keepsClockWarm(
        isPointerInside: Bool,
        lastPointerRequestTime: CFTimeInterval?,
        now: CFTimeInterval
    ) -> Bool {
        guard isPointerInside,
              let lastPointerRequestTime,
              lastPointerRequestTime.isFinite,
              now.isFinite else {
            return false
        }
        return now - lastPointerRequestTime < pointerIdleGrace
    }
}

enum DockMagnificationFrameRatePolicy {
    static let maximumAnimationFramesPerSecond = 120

    static func animationFramesPerSecond(
        maximumDisplayFramesPerSecond: Int
    ) -> Int {
        min(
            maximumAnimationFramesPerSecond,
            max(30, maximumDisplayFramesPerSecond)
        )
    }
}

enum DockBackgroundFrameAlignment {
    static func pixelAligned(
        _ frame: NSRect,
        backingScaleFactor: CGFloat
    ) -> NSRect {
        let scale = max(1, backingScaleFactor)
        let minimumX = (frame.minX * scale).rounded() / scale
        let maximumX = (frame.maxX * scale).rounded() / scale
        return NSRect(
            x: minimumX,
            y: frame.minY,
            width: max(0, maximumX - minimumX),
            height: frame.height
        )
    }
}

