import CoreGraphics

/// A display expressed in Accessibility's top-left-origin global coordinate space.
struct WindowReservationDisplayGeometry: Equatable {
    let identity: DisplayIdentity
    let frame: CGRect
    let visibleFrame: CGRect
    let reservedHeight: CGFloat

    var availableFrame: CGRect {
        let bottomLimit = min(visibleFrame.maxY, frame.maxY - max(0, reservedHeight))
        guard bottomLimit > visibleFrame.minY else { return .null }
        return CGRect(
            x: visibleFrame.minX,
            y: visibleFrame.minY,
            width: visibleFrame.width,
            height: bottomLimit - visibleFrame.minY
        )
    }
}

struct WindowReservationAdjustment: Equatable {
    let displayIdentity: DisplayIdentity
    let targetFrame: CGRect
}

enum WindowReservationMetrics {
    /// EchoDock's body is `iconSize + 24` points and is positioned 6 points
    /// above the display edge. Magnification is intentionally allowed to float
    /// over windows, matching the native Dock's behavior.
    static func reservedHeight(iconSize: CGFloat) -> CGFloat {
        max(0, iconSize) + 30
    }
}

/// Side-effect-free policy used by the AX service and by geometry unit tests.
enum WindowReservationGeometryPolicy {
    static let defaultEdgeTolerance: CGFloat = 12
    static let defaultFrameTolerance: CGFloat = 2

    static func adjustment(
        for windowFrame: CGRect,
        displays: [WindowReservationDisplayGeometry],
        edgeTolerance: CGFloat = defaultEdgeTolerance
    ) -> WindowReservationAdjustment? {
        guard let display = bestDisplay(for: windowFrame, displays: displays),
              !isLikelyFullScreen(
                windowFrame,
                in: display,
                edgeTolerance: defaultEdgeTolerance
              ),
              isMaximizedOrBottomTiled(
                windowFrame,
                in: display,
                edgeTolerance: edgeTolerance
              ) else {
            return nil
        }

        let availableFrame = display.availableFrame
        guard !availableFrame.isNull else { return nil }
        let targetBottom = availableFrame.maxY
        let targetFrame = CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: windowFrame.width,
            height: targetBottom - windowFrame.minY
        )
        guard targetFrame.height > 0,
              windowFrame.maxY > targetBottom + defaultFrameTolerance,
              !framesApproximatelyEqual(windowFrame, targetFrame) else {
            return nil
        }
        return WindowReservationAdjustment(
            displayIdentity: display.identity,
            targetFrame: targetFrame
        )
    }

    static func bestDisplay(
        for windowFrame: CGRect,
        displays: [WindowReservationDisplayGeometry]
    ) -> WindowReservationDisplayGeometry? {
        displays
            .compactMap { display -> (WindowReservationDisplayGeometry, CGFloat)? in
                let intersection = windowFrame.intersection(display.frame)
                guard !intersection.isNull, !intersection.isEmpty else { return nil }
                return (display, intersection.width * intersection.height)
            }
            .max { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                let lhsContainsCenter = lhs.0.frame.contains(windowFrame.center)
                let rhsContainsCenter = rhs.0.frame.contains(windowFrame.center)
                if lhsContainsCenter != rhsContainsCenter {
                    return !lhsContainsCenter
                }
                return lhs.0.identity.rawValue > rhs.0.identity.rawValue
            }?
            .0
    }

    static func isMaximizedOrBottomTiled(
        _ windowFrame: CGRect,
        in display: WindowReservationDisplayGeometry,
        edgeTolerance: CGFloat = defaultEdgeTolerance
    ) -> Bool {
        let visible = display.visibleFrame
        guard windowFrame.width > 0,
              windowFrame.height > 0,
              visible.width > 0,
              visible.height > 0 else {
            return false
        }

        let isHorizontallyContained = windowFrame.minX >= visible.minX - edgeTolerance
            && windowFrame.maxX <= visible.maxX + edgeTolerance
        let isVerticallyContained = windowFrame.minY >= visible.minY - edgeTolerance
            && windowFrame.maxY <= visible.maxY + edgeTolerance
        let touchesBottom = abs(windowFrame.maxY - visible.maxY) <= edgeTolerance
        let startsAtTop = abs(windowFrame.minY - visible.minY) <= edgeTolerance
        let startsAtMiddle = abs(windowFrame.minY - visible.midY) <= edgeTolerance
        let usesHorizontalTileGrid = horizontalEdgesUseTileGrid(
            windowFrame,
            visibleFrame: visible,
            edgeTolerance: edgeTolerance
        )

        return isHorizontallyContained
            && isVerticallyContained
            && touchesBottom
            && usesHorizontalTileGrid
            && (startsAtTop || startsAtMiddle)
    }

    private static func horizontalEdgesUseTileGrid(
        _ windowFrame: CGRect,
        visibleFrame: CGRect,
        edgeTolerance: CGFloat
    ) -> Bool {
        let fractions: [CGFloat] = [0, 0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 1]
        let gridEdges = fractions.map { visibleFrame.minX + visibleFrame.width * $0 }
        let leadingMatches = gridEdges.contains {
            abs(windowFrame.minX - $0) <= edgeTolerance
        }
        let trailingMatches = gridEdges.contains {
            abs(windowFrame.maxX - $0) <= edgeTolerance
        }
        return leadingMatches && trailingMatches
    }

    /// Accessibility does not publish a documented full-screen state
    /// attribute. A window matching the physical display bounds is therefore
    /// treated conservatively as full-screen and is never resized.
    static func isLikelyFullScreen(
        _ windowFrame: CGRect,
        in display: WindowReservationDisplayGeometry,
        edgeTolerance: CGFloat = defaultFrameTolerance
    ) -> Bool {
        framesApproximatelyEqual(
            windowFrame,
            display.frame,
            tolerance: edgeTolerance
        )
    }

    static func framesApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = defaultFrameTolerance
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
