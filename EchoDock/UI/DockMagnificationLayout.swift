import AppKit

/// A small, interruptible critically-damped transition used only while the
/// pointer enters or leaves the Dock. Pointer movement itself remains direct.
struct DockMagnificationTransition {
    private(set) var value: CGFloat
    private(set) var velocity: CGFloat = 0
    private(set) var target: CGFloat

    /// Time by which a transition has covered roughly 94% of its distance.
    private let response: TimeInterval

    init(value: CGFloat = 0, response: TimeInterval = 0.14) {
        let clamped = min(1, max(0, value))
        self.value = clamped
        target = clamped
        self.response = max(0.01, response)
    }

    var isSettled: Bool {
        abs(value - target) < 0.001 && abs(velocity) < 0.01
    }

    mutating func setTarget(_ newTarget: CGFloat) {
        let clamped = min(1, max(0, newTarget))
        guard clamped != target else { return }
        target = clamped

        // A direction reversal should react on the very next frame. Keeping
        // velocity that points away from the new target creates a perceptible
        // extra swell after the pointer has already left.
        if (target - value) * velocity < 0 {
            velocity = 0
        }
    }

    mutating func snap(to newValue: CGFloat) {
        let clamped = min(1, max(0, newValue))
        value = clamped
        target = clamped
        velocity = 0
    }

    /// Advances the exact solution of a critically-damped spring. Unlike a
    /// chain of view animations, this can be retargeted without a visual jump.
    mutating func advance(by deltaTime: TimeInterval) {
        guard deltaTime > 0, !isSettled else {
            if isSettled { snap(to: target) }
            return
        }

        let omega = 4.6 / response
        let elapsed = min(deltaTime, 0.1)
        let displacement = Double(value - target)
        let initialVelocity = Double(velocity)
        let coefficient = initialVelocity + omega * displacement
        let decay = exp(-omega * elapsed)
        let nextDisplacement = (displacement + coefficient * elapsed) * decay
        let nextVelocity = (initialVelocity - omega * coefficient * elapsed) * decay

        value = min(1, max(0, target + CGFloat(nextDisplacement)))
        velocity = CGFloat(nextVelocity)

        if isSettled {
            snap(to: target)
        } else if value == 0 || value == 1 {
            velocity = 0
        }
    }
}

struct DockItemPresenceTransition: Equatable {
    // A zero-to-one appearance needs more time than a conventional view
    // fade: the icon has to read as spreading from its own center. The
    // previous 0.20s cubic ease-out was already at 87.5% halfway through.
    static let insertionDuration: TimeInterval = 0.32
    static let removalDuration = insertionDuration

    let startValue: CGFloat
    let targetValue: CGFloat
    let startTime: CFTimeInterval
    let duration: TimeInterval

    static func insertion(startTime: CFTimeInterval) -> Self {
        transition(from: 0, to: 1, startTime: startTime)
    }

    static func transition(
        from startValue: CGFloat,
        to targetValue: CGFloat,
        startTime: CFTimeInterval
    ) -> Self {
        let clampedStart = min(1, max(0, startValue))
        let clampedTarget = min(1, max(0, targetValue))
        let distance = abs(clampedTarget - clampedStart)
        let isAppearing = clampedTarget >= clampedStart
        let fullDuration = isAppearing ? insertionDuration : removalDuration
        return Self(
            startValue: clampedStart,
            targetValue: clampedTarget,
            startTime: startTime,
            duration: fullDuration * Double(distance)
        )
    }

    func value(at time: CFTimeInterval) -> CGFloat {
        guard duration > 0 else { return targetValue }
        let linear = min(1, max(0, (time - startTime) / duration))
        // Appearance and removal deliberately share this curve so reversing
        // direction preserves the same perceived speed in both directions.
        let eased = 0.5 - 0.5 * cos(.pi * linear)
        return startValue + (targetValue - startValue) * CGFloat(eased)
    }

    func isComplete(at time: CFTimeInterval) -> Bool {
        duration == 0 || time - startTime >= duration
    }
}

struct DockLaunchBounceTransition: Equatable {
    // The native Dock's launch hop is a measured, readable gesture rather
    // than a notification-style jiggle. Keep the descending amplitudes, but
    // give each ballistic arc enough time to be perceived at 120 Hz.
    static let hopDurations: [TimeInterval] = [0.60, 0.40, 0.20]
    static let hopAmplitudeScales: [CGFloat] = [0.46, 0.27, 0.13]
    static let duration = hopDurations.reduce(0, +)
    static let maximumAmplitudeScale = hopAmplitudeScales.max() ?? 0

    let startTime: CFTimeInterval

    func offset(at time: CFTimeInterval, iconSize: CGFloat) -> CGFloat {
        var elapsed = max(0, time - startTime)
        guard elapsed < Self.duration else { return 0 }

        for (duration, amplitudeScale) in zip(
            Self.hopDurations,
            Self.hopAmplitudeScales
        ) {
            if elapsed <= duration {
                let progress = min(1, max(0, elapsed / duration))
                let ballisticArc = 4 * progress * (1 - progress)
                return iconSize * amplitudeScale * CGFloat(ballisticArc)
            }
            elapsed -= duration
        }
        return 0
    }

    func isComplete(at time: CFTimeInterval) -> Bool {
        time - startTime >= Self.duration
    }
}

enum DockInsertionHorizontalAlignment {
    static let minimumViewportWidth: CGFloat = 140

    static func offset(
        presentedRequiredWidth: CGFloat,
        finalDocumentWidth: CGFloat,
        finalViewportWidth: CGFloat
    ) -> CGFloat {
        let presentedViewportWidth = min(
            finalViewportWidth,
            max(minimumViewportWidth, presentedRequiredWidth)
        )
        let presentedDocumentWidth = max(
            presentedRequiredWidth,
            presentedViewportWidth
        )
        return ((finalViewportWidth - presentedViewportWidth)
            - (finalDocumentWidth - presentedDocumentWidth)) / 2
    }
}

struct DockMagnificationLayout {
    static let separatorSpace: CGFloat = 13
    static let separatorLineWidth: CGFloat = 0.5
    static let separatorHeightResponse: CGFloat = 0.12
    static let separatorMaximumHeightScale: CGFloat = 1.10

    static func pixelAlignedSeparatorFrame(
        _ frame: NSRect,
        backingScaleFactor: CGFloat
    ) -> NSRect {
        let scale = max(1, backingScaleFactor)
        let physicalWidth = max(1, (frame.width * scale).rounded())
        let width = physicalWidth / scale
        let idealX = frame.midX - width / 2
        let x = (idealX * scale).rounded() / scale
        let y = (frame.minY * scale).rounded() / scale
        let maxY = (frame.maxY * scale).rounded() / scale
        return NSRect(
            x: x,
            y: y,
            width: width,
            height: max(1 / scale, maxY - y)
        )
    }

    private enum Element {
        case item(Int)
        case separator
    }

    struct Result {
        let baseButtonFrames: [NSRect]
        let buttonFrames: [NSRect]
        let scales: [CGFloat]
        let separatorFrame: NSRect?
        let separatorScale: CGFloat?
        let visualContentFrame: NSRect

        var peakScale: CGFloat {
            // The divider stays inside the resting strip height. Only actual
            // icons should ask the Dock window for magnification headroom.
            scales.max() ?? 1
        }
    }

    static func baseContentWidth(
        itemCount: Int,
        pinnedItemCount: Int,
        iconSize: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let validItemCount = max(0, itemCount)
        let validPinnedItemCount = min(max(0, pinnedItemCount), validItemCount)
        let hasSeparator = validPinnedItemCount > 0
            && validPinnedItemCount < validItemCount
        return CGFloat(validItemCount) * (iconSize + spacing)
            + (hasSeparator ? separatorSpace : 0)
    }

    static func maximumRequiredWidth(
        itemCount: Int,
        pinnedItemCount: Int,
        iconSize: CGFloat,
        spacing: CGFloat,
        maximumScale: CGFloat,
        influenceRange: CGFloat
    ) -> CGFloat {
        let validItemCount = max(0, itemCount)
        let validPinnedItemCount = min(max(0, pinnedItemCount), validItemCount)
        let hasSeparator = validPinnedItemCount > 0
            && validPinnedItemCount < validItemCount
        let baseWidth = baseContentWidth(
            itemCount: itemCount,
            pinnedItemCount: pinnedItemCount,
            iconSize: iconSize,
            spacing: spacing
        )
        let scaleDelta = max(0, maximumScale - 1)
        let maximumExpansion = iconSize * scaleDelta * max(1, influenceRange)
            + (hasSeparator ? separatorSpace * scaleDelta : 0)
        return baseWidth + (maximumExpansion > 0 ? maximumExpansion + 8 : 0)
    }

    static func presentedRequiredWidth(
        itemPresenceProgresses: [CGFloat],
        hasSeparator: Bool,
        separatorPresenceProgress: CGFloat,
        iconSize: CGFloat,
        spacing: CGFloat,
        maximumScale: CGFloat,
        influenceRange: CGFloat
    ) -> CGFloat {
        let itemPresence = itemPresenceProgresses.reduce(CGFloat.zero) { result, progress in
            result + min(1, max(0, progress))
        }
        let separatorPresence = hasSeparator
            ? min(1, max(0, separatorPresenceProgress))
            : 0
        let baseWidth = itemPresence * (iconSize + spacing)
            + separatorSpace * separatorPresence
        let scaleDelta = max(0, maximumScale - 1)
        let iconExpansionPresence = min(1, itemPresence)
        let maximumExpansion = iconSize
            * scaleDelta
            * max(1, influenceRange)
            * iconExpansionPresence
            + separatorSpace * scaleDelta * separatorPresence
        let overflowPadding = maximumExpansion > 0 ? 8 * iconExpansionPresence : 0
        return baseWidth + maximumExpansion + overflowPadding
    }

    static func make(
        itemCount: Int,
        pinnedItemCount: Int,
        iconSize: CGFloat,
        spacing: CGFloat,
        maximumScale: CGFloat,
        influenceRange: CGFloat,
        containerWidth: CGFloat,
        height: CGFloat,
        pointerX: CGFloat?,
        magnificationProgress: CGFloat = 1,
        itemPresenceProgresses: [CGFloat]? = nil,
        separatorPresenceProgress: CGFloat = 1
    ) -> Result {
        guard itemCount > 0 else {
            return Result(
                baseButtonFrames: [],
                buttonFrames: [],
                scales: [],
                separatorFrame: nil,
                separatorScale: nil,
                visualContentFrame: .zero
            )
        }

        let baseSlotWidth = iconSize + spacing
        let pinnedItemCount = min(max(0, pinnedItemCount), itemCount)
        let elements = makeElements(
            itemCount: itemCount,
            pinnedItemCount: pinnedItemCount
        )
        let itemPresence = (0..<itemCount).map { index in
            min(1, max(0, itemPresenceProgresses?[safe: index] ?? 1))
        }
        let separatorPresence = min(1, max(0, separatorPresenceProgress))
        let baseElementWidths = elements.map { element -> CGFloat in
            switch element {
            case let .item(index):
                return baseSlotWidth * itemPresence[index]
            case .separator:
                return separatorSpace * separatorPresence
            }
        }
        let baseWidth = baseElementWidths.reduce(0, +)
        let contentStart = max(0, (containerWidth - baseWidth) / 2)

        var baseFrames = Array(repeating: NSRect.zero, count: itemCount)
        var baseElementFrames: [NSRect] = []
        var baseCursor = contentStart
        for (element, width) in zip(elements, baseElementWidths) {
            let frame = NSRect(
                x: baseCursor,
                y: 0,
                width: width,
                height: height
            )
            baseElementFrames.append(frame)
            if case let .item(index) = element {
                baseFrames[index] = frame
            }
            baseCursor += width
        }

        let progress = min(1, max(0, magnificationProgress))
        let radius = max(baseSlotWidth, baseSlotWidth * influenceRange)
        let elementScales = baseElementFrames.map { frame -> CGFloat in
            guard let pointerX, maximumScale > 1, progress > 0 else { return 1 }
            return magnificationScale(
                pointerX: pointerX,
                elementCenterX: frame.midX,
                radius: radius,
                maximumScale: maximumScale,
                progress: progress
            )
        }
        let dynamicElementWidths = zip(elements, elementScales).map { element, scale -> CGFloat in
            switch element {
            case let .item(index):
                return (iconSize * scale + spacing) * itemPresence[index]
            case .separator:
                // The divider uses the same scale factor as an icon while
                // retaining its much narrower native resting footprint.
                return separatorSpace * scale * separatorPresence
            }
        }
        let dynamicWidth = dynamicElementWidths.reduce(0, +)

        let dynamicStart: CGFloat
        if let pointerX, maximumScale > 1, progress > 0 {
            let baseRelativePointer = min(max(0, pointerX - contentStart), baseWidth)
            let dynamicRelativePointer = mappedPointerPosition(
                baseRelativePointer,
                baseWidths: baseElementWidths,
                dynamicWidths: dynamicElementWidths
            )
            let unclampedStart = contentStart + baseRelativePointer - dynamicRelativePointer
            let maximumStart = max(0, containerWidth - dynamicWidth)
            dynamicStart = min(max(0, unclampedStart), maximumStart)
        } else {
            dynamicStart = contentStart
        }

        var frames = Array(repeating: NSRect.zero, count: itemCount)
        var scales = Array(repeating: CGFloat(1), count: itemCount)
        var separatorSlotFrame: NSRect?
        var separatorScale: CGFloat?
        var cursor = dynamicStart
        for index in elements.indices {
            let element = elements[index]
            let scale = elementScales[index]
            let frame = NSRect(
                x: cursor,
                y: 0,
                width: dynamicElementWidths[index],
                height: height
            )
            switch element {
            case let .item(itemIndex):
                frames[itemIndex] = frame
                scales[itemIndex] = scale
            case .separator:
                separatorSlotFrame = frame
                separatorScale = scale
            }
            cursor += dynamicElementWidths[index]
        }

        return Result(
            baseButtonFrames: baseFrames,
            buttonFrames: frames,
            scales: scales,
            separatorFrame: separatorFrame(
                slotFrame: separatorSlotFrame,
                scale: separatorScale,
                iconSize: iconSize
            ),
            separatorScale: separatorScale,
            visualContentFrame: NSRect(
                x: dynamicStart,
                y: 0,
                width: dynamicWidth,
                height: height
            )
        )
    }

    private static func mappedPointerPosition(
        _ basePosition: CGFloat,
        baseWidths: [CGFloat],
        dynamicWidths: [CGFloat]
    ) -> CGFloat {
        var baseCursor: CGFloat = 0
        var dynamicCursor: CGFloat = 0

        for index in baseWidths.indices {
            let baseWidth = baseWidths[index]
            if baseWidth <= 0 {
                dynamicCursor += dynamicWidths[index]
                continue
            }
            if basePosition <= baseCursor + baseWidth {
                let fraction = min(max(0, (basePosition - baseCursor) / baseWidth), 1)
                return dynamicCursor + fraction * dynamicWidths[index]
            }
            baseCursor += baseWidth
            dynamicCursor += dynamicWidths[index]
        }

        return dynamicCursor
    }

    private static func separatorFrame(
        slotFrame: NSRect?,
        scale: CGFloat?,
        iconSize: CGFloat
    ) -> NSRect? {
        guard let slotFrame, let scale else { return nil }
        let baseHeight = max(20, iconSize - 4)
        let heightScale = min(
            separatorMaximumHeightScale,
            1 + max(0, scale - 1) * separatorHeightResponse
        )
        return NSRect(
            x: slotFrame.midX - separatorLineWidth / 2,
            y: 10,
            width: separatorLineWidth,
            height: baseHeight * heightScale
        )
    }

    private static func makeElements(
        itemCount: Int,
        pinnedItemCount: Int
    ) -> [Element] {
        let hasSeparator = pinnedItemCount > 0 && pinnedItemCount < itemCount
        var elements: [Element] = []
        elements.reserveCapacity(itemCount + (hasSeparator ? 1 : 0))
        for index in 0..<itemCount {
            if hasSeparator, index == pinnedItemCount {
                elements.append(.separator)
            }
            elements.append(.item(index))
        }
        return elements
    }

    private static func magnificationScale(
        pointerX: CGFloat,
        elementCenterX: CGFloat,
        radius: CGFloat,
        maximumScale: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        let normalizedDistance = min(1, abs(pointerX - elementCenterX) / radius)
        let cosine = cos(.pi * 0.5 * normalizedDistance)
        let influence = cosine * cosine
        return 1 + (maximumScale - 1) * influence * progress
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
