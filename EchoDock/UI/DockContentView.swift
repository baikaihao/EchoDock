import AppKit
import QuartzCore

struct DockBackgroundGeometry {
    static func cornerRadius(forBodyHeight bodyHeight: CGFloat) -> CGFloat {
        let proportionalRadius = bodyHeight * 0.28
        return min(bodyHeight / 2, min(24, max(16, proportionalRadius)))
    }
}

struct DockInteractiveRegion {
    static let backgroundHorizontalPadding: CGFloat = 10

    static func contains(
        _ point: NSPoint,
        bodyFrame: NSRect,
        iconFrames: [NSRect]
    ) -> Bool {
        bodyFrame.contains(point) || iconFrames.contains { $0.contains(point) }
    }
}

final class DockContentView: NSView {
    var onItemAction: ((DockItem) -> Void)?
    var onItemContextAction: ((DockItem, DockItemContextAction) -> Void)?
    var onItemContextMenuStateRequest: ((DockItem) -> DockItemContextMenuState)?
    var onContextMenuPresentationChange: ((Bool) -> Void)?
    var onTooltipPresentation: ((DockTooltipPresentation?) -> Void)?
    var onPreferredSizeChange: ((NSSize) -> Void)?
    var onPointerInteractionChange: ((Bool) -> Void)?
    var onLaunchBounceActivityChange: ((Bool) -> Void)?

    private let backgroundView = DockBackgroundSurfaceView()
    private let scrollView = HorizontalDockScrollView()
    private let stripView = DockStripView()
    private let iconProvider: ApplicationIconProvider

    private(set) var dockBodyHeight: CGFloat = 72
    private(set) var preferredWidth: CGFloat = 160
    private(set) var preferredHeight: CGFloat = 72
    private var iconSize: CGFloat = 48
    private var maxWidth: CGFloat = 800
    private var backgroundTransparency: CGFloat = 0.17
    private var backgroundStyle: DockBackgroundStyle = .liquidGlass
    private var magnificationEnabled = true
    private var magnificationScale: CGFloat = 1.18
    private var magnificationRange: CGFloat = 3.0
    private var iconSpacing: CGFloat = 5.2
    private var tooltipGap: CGFloat = 4
    private var maximumMagnificationHeadroom: CGFloat = 0
    private var maximumLaunchBounceHeadroom: CGFloat = 0
    private var isMagnificationHeadroomActive = false
    private var isLaunchBounceActive = false
    private var backgroundInteraction = DockBackgroundInteractionState.idle

    init(iconProvider: ApplicationIconProvider = .shared) {
        self.iconProvider = iconProvider

        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false

        backgroundView.configure(
            transparency: backgroundTransparency,
            bodyHeight: dockBodyHeight,
            style: backgroundStyle
        )
        addSubview(backgroundView)

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        // Magnified icons intentionally rise above their base slot. Let the
        // document view draw into the headroom above the blurred surface.
        scrollView.clipsToBounds = false
        scrollView.contentView.clipsToBounds = false
        scrollView.documentView = stripView
        scrollView.onScroll = { [weak stripView] event in
            stripView?.refreshPointer(with: event)
        }
        stripView.onBackgroundInteractionChange = { [weak self] state in
            self?.backgroundInteraction = state
            self?.updateBackgroundFrame()
        }
        stripView.onMagnificationHeadroomChange = { [weak self] isActive in
            self?.updatePreferredHeight(forMagnification: isActive)
        }
        stripView.onRequiredWidthChange = { [weak self] in
            self?.updatePreferredWidthFromStrip()
        }
        stripView.onLaunchBounceActivityChange = { [weak self] isActive in
            guard let self else { return }
            self.isLaunchBounceActive = isActive
            self.updatePreferredHeight()
            self.onLaunchBounceActivityChange?(isActive)
        }
        stripView.onPointerInteractionChange = { [weak self] isActive in
            self?.onPointerInteractionChange?(isActive)
        }
        // The documentView setter may recreate the clip view on older AppKit
        // versions, so assert the overflow policy once more afterward.
        scrollView.clipsToBounds = false
        scrollView.contentView.clipsToBounds = false
        // Keep icons outside the material view. This lets background
        // transparency change without fading the app icons with it.
        addSubview(scrollView, positioned: .above, relativeTo: backgroundView)

        updateBackgroundAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(
        snapshot: DockSnapshot,
        iconSize: CGFloat,
        maxWidth: CGFloat,
        backgroundTransparency: CGFloat,
        backgroundStyle: DockBackgroundStyle = .liquidGlass,
        magnificationEnabled: Bool = true,
        magnificationScale: CGFloat = 1.18,
        magnificationRange: CGFloat = 3.0,
        iconSpacing: CGFloat = 5.2,
        tooltipGap: CGFloat = 4,
        animatedInsertionIdentities: Set<ApplicationIdentity> = [],
        animatedRemovalIdentities: Set<ApplicationIdentity> = [],
        launchBounceAnimationsEnabled: Bool = false,
        runningIndicatorsEnabled: Bool = true
    ) {
        let wasLaunchBounceActive = isLaunchBounceActive
        self.iconSize = iconSize
        self.maxWidth = max(160, maxWidth)
        self.backgroundTransparency = DockBackgroundTransparency.clamped(backgroundTransparency)
        self.backgroundStyle = backgroundStyle
        self.magnificationEnabled = magnificationEnabled
        self.magnificationScale = magnificationEnabled
            ? min(1.80, max(1.0, magnificationScale))
            : 1.0
        self.magnificationRange = min(3.50, max(1.25, magnificationRange))
        self.iconSpacing = min(28, max(4, iconSpacing))
        self.tooltipGap = min(24, max(0, tooltipGap))
        updateBackgroundAppearance()
        // Leave enough headroom for the magnified icon while preserving a
        // compact native-Dock-like baseline.
        dockBodyHeight = iconSize + 24
        updateBackgroundCornerRadius()
        let baseStripHeight = max(0, dockBodyHeight - 8)
        let baselineInset: CGFloat = 8
        let requiredStripHeight = baselineInset + iconSize * self.magnificationScale + 4
        maximumMagnificationHeadroom = max(0, requiredStripHeight - baseStripHeight)
        maximumLaunchBounceHeadroom = iconSize
            * DockLaunchBounceTransition.maximumAmplitudeScale
        if !self.magnificationEnabled {
            isMagnificationHeadroomActive = false
        }

        stripView.apply(
            items: snapshot.items,
            pinnedItemCount: snapshot.pinnedItemCount,
            iconSize: iconSize,
            iconProvider: iconProvider,
            onAction: { [weak self] item in self?.onItemAction?(item) },
            onContextAction: { [weak self] item, action in
                self?.onItemContextAction?(item, action)
            },
            contextMenuStateProvider: { [weak self] item in
                self?.onItemContextMenuStateRequest?(item) ?? .unavailable
            },
            onContextMenuPresentationChange: { [weak self] presented in
                if presented {
                    self?.onTooltipPresentation?(nil)
                }
                self?.onContextMenuPresentationChange?(presented)
            },
            onHover: { [weak self] button, item in self?.updateTooltip(button: button, item: item) },
            magnificationEnabled: self.magnificationEnabled,
            magnificationScale: self.magnificationScale,
            magnificationRange: self.magnificationRange,
            iconSpacing: self.iconSpacing,
            animatedInsertionIdentities: animatedInsertionIdentities,
            animatedRemovalIdentities: animatedRemovalIdentities,
            launchBounceAnimationsEnabled: launchBounceAnimationsEnabled,
            runningIndicatorsEnabled: runningIndicatorsEnabled
        )

        isLaunchBounceActive = stripView.isLaunchBounceAnimationActive
        preferredWidth = targetPreferredWidth
        preferredHeight = targetPreferredHeight
        frame.size = NSSize(
            width: preferredWidth,
            height: preferredHeight
        )
        needsLayout = true
        layoutSubtreeIfNeeded()
        if isLaunchBounceActive != wasLaunchBounceActive {
            onLaunchBounceActivityChange?(isLaunchBounceActive)
        }
    }

    override func layout() {
        super.layout()
        let activeHeadroom = min(
            maximumActiveHeadroom,
            max(0, bounds.height - dockBodyHeight)
        )
        let stripHeight = max(0, dockBodyHeight - 8 + activeHeadroom)
        scrollView.frame = NSRect(x: 10, y: 4, width: bounds.width - 20, height: stripHeight)
        stripView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(stripView.requiredWidth, scrollView.contentSize.width),
            height: stripHeight
        )
        stripView.needsLayout = true
        stripView.layoutSubtreeIfNeeded()
        updateBackgroundFrame()
    }

    func hideTooltip() {
        // Ordering a panel out does not guarantee a final mouseExited event.
        // Clear the strip-owned hover state as part of every explicit hide so
        // an in-flight magnification frame cannot reveal the tooltip again.
        stripView.cancelPointerInteraction()
        onTooltipPresentation?(nil)
    }

    func resetInteraction() {
        stripView.resetPointerInteraction()
        onTooltipPresentation?(nil)
    }

    /// Reconciles AppKit tracking with the monitor's current global pointer.
    /// Window moves and tracking-area replacement do not always deliver a
    /// final mouseExited event, so this keeps a stale label from surviving.
    func reconcilePointer(
        screenLocation: NSPoint,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        allowsSyntheticEntry: Bool = false
    ) {
        guard let window, window.isVisible else {
            stripView.cancelPointerInteraction()
            onTooltipPresentation?(nil)
            return
        }

        let pointInWindow = window.convertPoint(fromScreen: screenLocation)
        let pointInStrip = stripView.convert(pointInWindow, from: nil)
        if !stripView.reconcilePointer(
            at: pointInStrip,
            timestamp: timestamp,
            allowsSyntheticEntry: allowsSyntheticEntry
        ) {
            onTooltipPresentation?(nil)
        }
    }

    func shouldReceiveMouse(at screenLocation: NSPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        let pointInWindow = window.convertPoint(fromScreen: screenLocation)
        let pointInContent = convert(pointInWindow, from: nil)
        let bodyFrame = NSRect(
            x: backgroundView.frame.minX,
            y: backgroundView.frame.minY,
            width: backgroundView.frame.width,
            height: min(dockBodyHeight, backgroundView.frame.height)
        )
        let iconFrames = stripView.visibleIconFrames.map {
            stripView.convert($0, to: self)
        }
        return DockInteractiveRegion.contains(
            pointInContent,
            bodyFrame: bodyFrame,
            iconFrames: iconFrames
        )
    }

    private func updateTooltip(button: DockItemButton, item: DockItem?) {
        guard let item else {
            onTooltipPresentation?(nil)
            return
        }

        let text: String
        if case let .failed(message) = item.transientState {
            text = message
        } else {
            text = item.displayName
        }
        guard let window else {
            onTooltipPresentation?(nil)
            return
        }
        let iconRectInWindow = convert(button.iconFrame(in: self), to: nil)
        let anchorScreenRect = window.convertToScreen(iconRectInWindow)
        let screen = window.screen
        onTooltipPresentation?(
            DockTooltipPresentation(
                text: text,
                anchorScreenRect: anchorScreenRect,
                gap: tooltipGap,
                screenFrame: screen?.frame ?? anchorScreenRect,
                backingScaleFactor: screen?.backingScaleFactor ?? window.backingScaleFactor
            )
        )
    }

    private func updatePreferredHeight(forMagnification isActive: Bool) {
        isMagnificationHeadroomActive = isActive
        updatePreferredHeight()
    }

    private func updatePreferredHeight() {
        let targetHeight = targetPreferredHeight
        guard abs(targetHeight - preferredHeight) > 0.01 else { return }

        preferredHeight = targetHeight
        frame.size.height = targetHeight
        needsLayout = true
        onPreferredSizeChange?(NSSize(width: preferredWidth, height: targetHeight))
    }

    private func updatePreferredWidthFromStrip() {
        let targetWidth = targetPreferredWidth
        guard abs(targetWidth - preferredWidth) > 0.01 else { return }

        preferredWidth = targetWidth
        frame.size.width = targetWidth
        needsLayout = true
        layoutSubtreeIfNeeded()
        onPreferredSizeChange?(NSSize(width: targetWidth, height: preferredHeight))
    }

    private var targetPreferredWidth: CGFloat {
        min(maxWidth, max(160, stripView.requiredWidth + 20))
    }

    private var targetPreferredHeight: CGFloat {
        dockBodyHeight + maximumActiveHeadroom
    }

    private var maximumActiveHeadroom: CGFloat {
        if isLaunchBounceActive {
            return maximumMagnificationHeadroom + maximumLaunchBounceHeadroom
        }
        return isMagnificationHeadroomActive ? maximumMagnificationHeadroom : 0
    }

    private func updateBackgroundFrame() {
        guard bounds.width > 0 else { return }
        let backgroundHeight = min(dockBodyHeight, bounds.height)
        let visualFrame = backgroundInteraction.visualContentFrame
        guard visualFrame.width > 0 else {
            let targetFrame = NSRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: backgroundHeight
            )
            guard !NSEqualRects(backgroundView.frame, targetFrame) else { return }
            backgroundView.frame = targetFrame
            return
        }

        let converted = stripView.convert(visualFrame, to: self)
        var originX = converted.minX - DockInteractiveRegion.backgroundHorizontalPadding
        var width = converted.width + DockInteractiveRegion.backgroundHorizontalPadding * 2
        if originX < 0 {
            width += originX
            originX = 0
        }
        width = min(max(0, width), bounds.width - originX)
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let targetFrame = DockBackgroundFrameAlignment.pixelAligned(
            NSRect(x: originX, y: 0, width: width, height: backgroundHeight),
            backingScaleFactor: scale
        )

        guard !NSEqualRects(backgroundView.frame, targetFrame) else { return }
        backgroundView.frame = targetFrame
    }

    private func updateBackgroundAppearance() {
        // The preference is expressed as transparency, while AppKit exposes
        // opacity. Only the material is faded; icons remain fully opaque.
        backgroundView.configure(
            transparency: backgroundTransparency,
            bodyHeight: dockBodyHeight,
            style: backgroundStyle
        )
    }

    private func updateBackgroundCornerRadius() {
        backgroundView.configure(
            transparency: backgroundTransparency,
            bodyHeight: dockBodyHeight,
            style: backgroundStyle
        )
    }
}

private final class HorizontalDockScrollView: NSScrollView {
    var onScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard let clipView = contentView as NSClipView? else {
            super.scrollWheel(with: event)
            return
        }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        var origin = clipView.bounds.origin
        origin.x += delta
        let maximum = max(0, (documentView?.frame.width ?? 0) - clipView.bounds.width)
        origin.x = min(max(0, origin.x), maximum)
        clipView.scroll(to: origin)
        reflectScrolledClipView(clipView)
        onScroll?(event)
    }
}

struct DockHoverResolver {
    static func hoveredIndex(
        at point: NSPoint,
        in bounds: NSRect,
        hoverFrames: [NSRect]
    ) -> Int? {
        guard bounds.contains(point) else { return nil }
        return hoverFrames.firstIndex(where: { $0.contains(point) })
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
                rendersImmediately: true,
                shouldRunFrameClock: !isTransitionSettled
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

struct DockPointerSampleSequence {
    private(set) var lastAcceptedTimestamp: TimeInterval?

    mutating func accept(_ timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite else { return false }
        if let lastAcceptedTimestamp,
           timestamp < lastAcceptedTimestamp {
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

@available(macOS 14.0, *)
private final class DockMagnificationDisplayLinkDriver: NSObject {
    weak var owner: DockStripView?
    private var displayLink: CADisplayLink!
    private var configuredFramesPerSecond: Int?

    init(view: NSView, owner: DockStripView) {
        self.owner = owner
        super.init()
        displayLink = view.displayLink(
            target: self,
            selector: #selector(displayLinkFired)
        )
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
    }

    func start(framesPerSecond: Int) {
        let framesPerSecond = max(1, framesPerSecond)
        if configuredFramesPerSecond != framesPerSecond {
            configuredFramesPerSecond = framesPerSecond
            let frameRate = Float(framesPerSecond)
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: frameRate,
                maximum: frameRate,
                preferred: frameRate
            )
        }
        displayLink.isPaused = false
    }

    func pause() {
        displayLink.isPaused = true
    }

    func invalidate() {
        displayLink.invalidate()
    }

    @objc func displayLinkFired(_ displayLink: CADisplayLink) {
        owner?.advanceMagnificationFrame()
    }
}

private final class DockStripView: NSView {
    var onBackgroundInteractionChange: ((DockBackgroundInteractionState) -> Void)?
    var onMagnificationHeadroomChange: ((Bool) -> Void)?
    var onPointerInteractionChange: ((Bool) -> Void)?
    var onRequiredWidthChange: (() -> Void)?
    var onLaunchBounceActivityChange: ((Bool) -> Void)?

    private var itemButtons: [ApplicationIdentity: DockItemButton] = [:]
    private var orderedButtons: [DockItemButton] = []
    private let separatorView = NSView()
    private var pinnedItemCount = 0
    private var iconSize: CGFloat = 48
    private(set) var requiredWidth: CGFloat = 0
    private(set) var visualContentFrame: NSRect = .zero
    private var trackingArea: NSTrackingArea?
    private var pointerX: CGFloat?
    private var pointerPoint: NSPoint?
    private var isPointerInside = false
    private var hoveredButton: DockItemButton?
    private weak var contextMenuButton: DockItemButton?
    private var isContextMenuPresented = false
    private var onHover: ((DockItemButton, DockItem?) -> Void)?
    private var magnificationTransition = DockMagnificationTransition()
    private var displayLinkDriver: AnyObject?
    private var fallbackFrameTimer: Timer?
    private var previousAnimationTime: CFTimeInterval?
    private var isFrameClockRunning = false
    private var pointerSampleSequence = DockPointerSampleSequence()
    private var itemPresenceTransitions: [ApplicationIdentity: DockItemPresenceTransition] = [:]
    private var itemPresenceValues: [ApplicationIdentity: CGFloat] = [:]
    private var removingIdentities = Set<ApplicationIdentity>()
    private var separatorPresenceTransition: DockItemPresenceTransition?
    private var separatorPresence: CGFloat = 1
    private var launchBounceTransitions: [ApplicationIdentity: DockLaunchBounceTransition] = [:]
    private var launchBounceOffsets: [ApplicationIdentity: CGFloat] = [:]
    private var wasLaunchBounceActive = false
    private var isMagnificationHeadroomActive = false
    private var magnificationEnabled = true
    private var maximumMagnification: CGFloat = 1.18
    private var iconSpacing: CGFloat = 5.2
    /// Radius in slot-widths over which the pointer influences neighboring
    /// icons. Keeping this separate from the scale makes the interaction
    /// tunable without changing the document layout.
    private var magnificationRange: CGFloat = 3.0
    private var previousBackgroundInteraction = DockBackgroundInteractionState.idle

    private(set) var visibleIconFrames: [NSRect] = []
    private var tooltipHoverFrames: [NSRect] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = false
        separatorView.wantsLayer = true
        updateSeparatorAppearance()
        separatorView.isHidden = true
        addSubview(separatorView)
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSeparatorAppearance()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        fallbackFrameTimer?.invalidate()
        if #available(macOS 14.0, *),
           let driver = displayLinkDriver as? DockMagnificationDisplayLinkDriver {
            driver.invalidate()
        }
    }

    func apply(
        items: [DockItem],
        pinnedItemCount: Int,
        iconSize: CGFloat,
        iconProvider: ApplicationIconProvider,
        onAction: @escaping (DockItem) -> Void,
        onContextAction: @escaping (DockItem, DockItemContextAction) -> Void,
        contextMenuStateProvider: @escaping (DockItem) -> DockItemContextMenuState,
        onContextMenuPresentationChange: @escaping (Bool) -> Void,
        onHover: @escaping (DockItemButton, DockItem?) -> Void,
        magnificationEnabled: Bool = true,
        magnificationScale: CGFloat = 1.18,
        magnificationRange: CGFloat = 3.0,
        iconSpacing: CGFloat = 5.2,
        animatedInsertionIdentities: Set<ApplicationIdentity> = [],
        animatedRemovalIdentities: Set<ApplicationIdentity> = [],
        launchBounceAnimationsEnabled: Bool = false,
        runningIndicatorsEnabled: Bool = true
    ) {
        let now = CACurrentMediaTime()
        let previousIdentities = Set(itemButtons.keys)
        let previousStateByIdentity = Dictionary(uniqueKeysWithValues: itemButtons.compactMap {
            identity, button in
            button.item.map { (identity, $0.transientState) }
        })
        let previousHadSeparator = self.pinnedItemCount > 0
            && self.pinnedItemCount < orderedButtons.count
        self.onHover = onHover
        self.pinnedItemCount = pinnedItemCount
        self.iconSize = iconSize
        self.magnificationEnabled = magnificationEnabled
        self.maximumMagnification = min(1.80, max(1.0, magnificationScale))
        self.magnificationRange = min(3.50, max(1.25, magnificationRange))
        self.iconSpacing = min(28, max(4, iconSpacing))
        let incomingByIdentity = Dictionary(uniqueKeysWithValues: items.map { ($0.identity, $0) })
        let incomingIdentities = Set(incomingByIdentity.keys)

        var presentationItems = Array(items.prefix(pinnedItemCount))
        var presentedIdentities = Set(presentationItems.map(\.identity))
        for button in orderedButtons {
            guard let previousItem = button.item,
                  previousItem.section == .running,
                  !presentedIdentities.contains(previousItem.identity) else { continue }
            if let incomingItem = incomingByIdentity[previousItem.identity],
               incomingItem.section == .running {
                presentationItems.append(incomingItem)
                presentedIdentities.insert(incomingItem.identity)
            } else if removingIdentities.contains(previousItem.identity)
                        || animatedRemovalIdentities.contains(previousItem.identity) {
                presentationItems.append(previousItem)
                presentedIdentities.insert(previousItem.identity)
            }
        }
        for item in items.dropFirst(pinnedItemCount)
        where !presentedIdentities.contains(item.identity) {
            presentationItems.append(item)
            presentedIdentities.insert(item.identity)
        }

        let identitiesToRemove = itemButtons.keys.filter {
            !presentedIdentities.contains($0)
        }
        for identity in identitiesToRemove {
            removeButtonImmediately(identity)
        }

        orderedButtons = presentationItems.map { item in
            let button: DockItemButton
            if let existing = itemButtons[item.identity] {
                button = existing
            } else {
                button = DockItemButton(frame: .zero)
                itemButtons[item.identity] = button
                addSubview(button)
            }
            button.onPress = onAction
            button.onContextAction = onContextAction
            button.contextMenuStateProvider = contextMenuStateProvider
            button.onContextMenuPresentationChange = { [weak self] button, presented in
                self?.setContextMenuPresented(
                    presented,
                    for: button,
                    notify: onContextMenuPresentationChange
                )
            }
            button.configure(
                item: item,
                iconSize: iconSize,
                iconProvider: iconProvider,
                showsRunningIndicator: runningIndicatorsEnabled
            )
            button.isEnabled = incomingIdentities.contains(item.identity)
            return button
        }

        for identity in incomingIdentities where removingIdentities.remove(identity) != nil {
            setPresenceTarget(1, for: identity, at: now)
        }

        let insertedRunningItems = items.filter { item in
            item.section == .running
                && animatedInsertionIdentities.contains(item.identity)
                && !previousIdentities.contains(item.identity)
        }
        let newlyRemovedIdentities = animatedRemovalIdentities.filter {
            presentedIdentities.contains($0) && !incomingIdentities.contains($0)
        }
        for identity in newlyRemovedIdentities {
            removingIdentities.insert(identity)
            if let button = itemButtons[identity] {
                button.cancelContextMenu()
                button.isEnabled = false
                if hoveredButton === button {
                    clearHoveredButton()
                }
            }
            setPresenceTarget(0, for: identity, at: now)
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishPresenceAnimations()
            finishLaunchBounceAnimations(notify: false)
        } else {
            for item in insertedRunningItems {
                itemPresenceValues[item.identity] = 0
                itemPresenceTransitions[item.identity] = .insertion(startTime: now)
            }
        }

        let presentationHasSeparator = pinnedItemCount > 0
            && pinnedItemCount < orderedButtons.count
        let finalHasSeparator = pinnedItemCount > 0
            && pinnedItemCount < items.count
        updateSeparatorPresence(
            presentationHasSeparator: presentationHasSeparator,
            finalHasSeparator: finalHasSeparator,
            previousHadSeparator: previousHadSeparator,
            hasAnimatedInsertions: !insertedRunningItems.isEmpty,
            hasAnimatedRemovals: !newlyRemovedIdentities.isEmpty,
            at: now
        )

        if launchBounceAnimationsEnabled,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for item in items where item.transientState == .launching {
                guard let previousState = previousStateByIdentity[item.identity],
                      previousState != .launching,
                      launchBounceTransitions[item.identity] == nil else { continue }
                launchBounceTransitions[item.identity] = DockLaunchBounceTransition(
                    startTime: now
                )
                launchBounceOffsets[item.identity] = 0
            }
        }

        itemPresenceTransitions = itemPresenceTransitions.filter {
            presentedIdentities.contains($0.key)
        }
        itemPresenceValues = itemPresenceValues.filter {
            presentedIdentities.contains($0.key)
        }
        removingIdentities.formIntersection(presentedIdentities)
        launchBounceTransitions = launchBounceTransitions.filter {
            presentedIdentities.contains($0.key)
        }
        launchBounceOffsets = launchBounceOffsets.filter {
            presentedIdentities.contains($0.key)
        }

        recalculateRequiredWidth()
        // DockContentView synchronizes this state after it has applied the
        // matching height and laid out the extra bounce headroom. Suppressing
        // the callback here avoids resizing the panel halfway through apply().
        updateLaunchBounceActivity(notify: false)

        if !magnificationEnabled {
            if !hasActivePresentationAnimation {
                stopMagnificationFrameClock()
            }
            magnificationTransition.snap(to: 0)
            updateMagnificationHeadroomActivity()
        } else if isPointerInside {
            setMagnificationTarget(1)
        }
        if hasActivePresentationAnimation {
            startMagnificationFrameClockIfNeeded()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        renderMagnification()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeAlways,
                .enabledDuringMouseDrag,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isCurrentTrackingEvent(event) else { return }
        handlePointerEvent(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard isCurrentTrackingEvent(event) else { return }
        handlePointerEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        guard isCurrentTrackingEvent(event) else { return }
        handlePointerEvent(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isCurrentTrackingEvent(event) else { return }
        guard !isContextMenuPresented else { return }
        guard acceptPointerSample(timestamp: event.timestamp) else { return }
        cancelPointerInteraction()
    }

    private func isCurrentTrackingEvent(_ event: NSEvent) -> Bool {
        guard let eventTrackingArea = event.trackingArea else { return true }
        return eventTrackingArea === trackingArea
    }

    private func handlePointerEvent(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        handlePointer(at: point, timestamp: event.timestamp)
    }

    private func handlePointer(at point: NSPoint, timestamp: TimeInterval) {
        guard acceptPointerSample(timestamp: timestamp) else { return }
        guard !isContextMenuPresented else { return }
        guard containsInteractivePoint(point) else {
            cancelPointerInteraction()
            return
        }
        let justEntered = !isPointerInside
        let pointChanged = DockPointerSamplePolicy.hasChanged(
            from: pointerPoint,
            to: point
        )
        isPointerInside = true
        pointerX = point.x
        pointerPoint = point
        if justEntered {
            onPointerInteractionChange?(true)
            setMagnificationTarget(1)
            if magnificationEnabled {
                requestMagnificationRender(.pointerChanged)
            } else {
                updateHoveredButton(at: point, reemitCurrent: false)
            }
        } else if magnificationEnabled, pointChanged {
            requestMagnificationRender(.pointerChanged)
        } else {
            updateHoveredButton(at: point, reemitCurrent: false)
        }
    }

    func refreshPointer(with event: NSEvent) {
        handlePointerEvent(event)
    }

    /// Sampled pointers normally only validate an AppKit-owned interaction.
    /// The controller may allow one synthetic entry when a panel transitions
    /// from ignoring mouse events back into its real interactive region.
    @discardableResult
    func reconcilePointer(
        at point: NSPoint,
        timestamp: TimeInterval,
        allowsSyntheticEntry: Bool = false
    ) -> Bool {
        if isContextMenuPresented { return true }
        if !isPointerInside, allowsSyntheticEntry {
            handlePointer(at: point, timestamp: timestamp)
            return hoveredButton != nil
        }
        guard acceptPointerSample(timestamp: timestamp) else {
            return hoveredButton != nil
        }
        guard isPointerInside else {
            clearHoveredButton()
            return false
        }
        guard containsInteractivePoint(point) else {
            cancelPointerInteraction()
            return false
        }

        let pointChanged = DockPointerSamplePolicy.hasChanged(
            from: pointerPoint,
            to: point
        )
        pointerX = point.x
        pointerPoint = point
        if pointChanged, magnificationEnabled {
            requestMagnificationRender(.pointerChanged)
        } else {
            updateHoveredButton(at: point, reemitCurrent: false)
        }
        return hoveredButton != nil
    }

    func cancelPointerInteraction() {
        guard !isContextMenuPresented else {
            clearHoveredButton()
            return
        }
        let wasInside = isPointerInside
        isPointerInside = false
        pointerPoint = nil
        clearHoveredButton()
        if wasInside {
            onPointerInteractionChange?(false)
        }
        if wasInside || magnificationTransition.target != 0 {
            setMagnificationTarget(0)
        }
    }

    func resetPointerInteraction() {
        let wasInside = isPointerInside
        orderedButtons.forEach { $0.cancelContextMenu() }
        contextMenuButton = nil
        isContextMenuPresented = false
        isPointerInside = false
        pointerX = nil
        pointerPoint = nil
        clearHoveredButton()
        if wasInside {
            onPointerInteractionChange?(false)
        }
        stopMagnificationFrameClock()
        finishPresenceAnimations(notifyWidthChange: true)
        finishLaunchBounceAnimations()
        pointerSampleSequence.discardSamples(
            before: ProcessInfo.processInfo.systemUptime
        )
        magnificationTransition.snap(to: 0)
        updateMagnificationHeadroomActivity()
        renderMagnification()
    }

    /// Sizes every item from stable, non-magnified centers, then remaps the
    /// pixel under the pointer into the expanded row. Neighbors are pushed
    /// aside and the visual Dock width grows without feeding moved centers
    /// back into the magnification curve.
    private func setMagnificationTarget(_ target: CGFloat) {
        guard magnificationEnabled else {
            magnificationTransition.snap(to: 0)
            if !isPointerInside {
                pointerX = nil
            }
            if !hasActivePresentationAnimation {
                stopMagnificationFrameClock()
            }
            updateMagnificationHeadroomActivity()
            renderMagnification()
            return
        }

        magnificationTransition.setTarget(target)
        updateMagnificationHeadroomActivity()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            magnificationTransition.snap(to: target)
            if target == 0, !isPointerInside {
                pointerX = nil
            }
            if !hasActivePresentationAnimation {
                stopMagnificationFrameClock()
            }
            updateMagnificationHeadroomActivity()
            renderMagnification()
            return
        }

        requestMagnificationRender(.transitionTargetChanged)
    }

    private func requestMagnificationRender(_ request: DockMagnificationRenderRequest) {
        let plan = DockMagnificationRenderPlan.make(
            request: request,
            isTransitionSettled: magnificationTransition.isSettled
        )
        if plan.shouldRunFrameClock {
            startMagnificationFrameClockIfNeeded()
        }
        if plan.rendersImmediately {
            advanceMagnificationTransition(to: CACurrentMediaTime())
            renderMagnification()
            updateMagnificationHeadroomActivity()
        }
    }

    private func startMagnificationFrameClockIfNeeded() {
        guard !isFrameClockRunning else { return }
        isFrameClockRunning = true
        previousAnimationTime = CACurrentMediaTime()

        let maximumFramesPerSecond = window?.screen?.maximumFramesPerSecond ?? 60
        let animationFramesPerSecond = DockMagnificationFrameRatePolicy
            .animationFramesPerSecond(
                maximumDisplayFramesPerSecond: maximumFramesPerSecond
            )
        if #available(macOS 14.0, *) {
            let driver: DockMagnificationDisplayLinkDriver
            if let existing = displayLinkDriver as? DockMagnificationDisplayLinkDriver {
                driver = existing
            } else {
                driver = DockMagnificationDisplayLinkDriver(view: self, owner: self)
                displayLinkDriver = driver
            }
            driver.start(framesPerSecond: animationFramesPerSecond)
            return
        }

        let timer = Timer(
            timeInterval: 1.0 / Double(
                animationFramesPerSecond
            ),
            repeats: true
        ) {
            [weak self] _ in
            self?.advanceMagnificationFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackFrameTimer = timer
    }

    private func stopMagnificationFrameClock() {
        guard isFrameClockRunning else { return }
        isFrameClockRunning = false
        if #available(macOS 14.0, *),
           let driver = displayLinkDriver as? DockMagnificationDisplayLinkDriver {
            driver.pause()
        }
        fallbackFrameTimer?.invalidate()
        fallbackFrameTimer = nil
        previousAnimationTime = nil
    }

    fileprivate func advanceMagnificationFrame() {
        let hasMagnificationAnimation = !magnificationTransition.isSettled
        let hasPresentationAnimation = hasActivePresentationAnimation
        guard hasMagnificationAnimation || hasPresentationAnimation else {
            stopMagnificationFrameClock()
            return
        }

        let now = CACurrentMediaTime()
        // Keep one shared timeline warm even while insertion is the only active
        // animation. A hover that starts mid-insertion must advance by one
        // display frame, not by the whole time since magnification last moved.
        advanceMagnificationTransition(to: now)
        var requiredWidthChanged = false
        if !itemPresenceTransitions.isEmpty || separatorPresenceTransition != nil {
            requiredWidthChanged = advancePresenceAnimations(to: now)
        }
        if !launchBounceTransitions.isEmpty {
            advanceLaunchBounceAnimations(to: now)
        }
        renderMagnification()
        updateMagnificationHeadroomActivity()
        updateLaunchBounceActivity()
        if requiredWidthChanged {
            onRequiredWidthChange?()
        }

        if !isPointerInside, magnificationTransition.value == 0 {
            pointerX = nil
        }
        if magnificationTransition.isSettled,
           !hasActivePresentationAnimation {
            stopMagnificationFrameClock()
        }
    }

    @discardableResult
    private func advancePresenceAnimations(to time: CFTimeInterval) -> Bool {
        var completedIdentities: [ApplicationIdentity] = []
        for (identity, transition) in itemPresenceTransitions {
            itemPresenceValues[identity] = transition.value(at: time)
            if transition.isComplete(at: time) {
                completedIdentities.append(identity)
            }
        }
        var removedPresentationItem = false
        for identity in completedIdentities {
            guard let transition = itemPresenceTransitions.removeValue(forKey: identity) else {
                continue
            }
            itemPresenceValues[identity] = transition.targetValue
            if transition.targetValue == 0, removingIdentities.contains(identity) {
                removeButtonImmediately(identity)
                removedPresentationItem = true
            } else if transition.targetValue == 1 {
                itemPresenceValues.removeValue(forKey: identity)
            }
        }
        if let transition = separatorPresenceTransition {
            separatorPresence = transition.value(at: time)
            if transition.isComplete(at: time) {
                separatorPresenceTransition = nil
                separatorPresence = transition.targetValue
            }
        }
        if removedPresentationItem {
            recalculateRequiredWidth()
        }
        return removedPresentationItem
    }

    private func advanceLaunchBounceAnimations(to time: CFTimeInterval) {
        var completedIdentities: [ApplicationIdentity] = []
        for (identity, transition) in launchBounceTransitions {
            launchBounceOffsets[identity] = transition.offset(
                at: time,
                iconSize: iconSize
            )
            if transition.isComplete(at: time) {
                completedIdentities.append(identity)
            }
        }
        for identity in completedIdentities {
            launchBounceTransitions.removeValue(forKey: identity)
            launchBounceOffsets.removeValue(forKey: identity)
        }
    }

    private func finishPresenceAnimations(notifyWidthChange: Bool = false) {
        let identitiesToRemove = removingIdentities
        itemPresenceTransitions.removeAll()
        itemPresenceValues.removeAll()
        for identity in identitiesToRemove {
            removeButtonImmediately(identity)
        }
        removingIdentities.removeAll()
        if let separatorPresenceTransition {
            separatorPresence = separatorPresenceTransition.targetValue
        }
        separatorPresenceTransition = nil
        let widthChanged = recalculateRequiredWidth()
        if notifyWidthChange, widthChanged {
            onRequiredWidthChange?()
        }
    }

    private func finishLaunchBounceAnimations(notify: Bool = true) {
        launchBounceTransitions.removeAll()
        launchBounceOffsets.removeAll()
        updateLaunchBounceActivity(notify: notify)
    }

    private func setPresenceTarget(
        _ targetValue: CGFloat,
        for identity: ApplicationIdentity,
        at time: CFTimeInterval
    ) {
        let currentValue = itemPresenceTransitions[identity]?.value(at: time)
            ?? itemPresenceValues[identity]
            ?? 1
        itemPresenceValues[identity] = currentValue
        if abs(currentValue - targetValue) < 0.0001, targetValue == 1 {
            itemPresenceTransitions.removeValue(forKey: identity)
            itemPresenceValues.removeValue(forKey: identity)
            return
        }
        itemPresenceTransitions[identity] = .transition(
            from: currentValue,
            to: targetValue,
            startTime: time
        )
    }

    private func updateSeparatorPresence(
        presentationHasSeparator: Bool,
        finalHasSeparator: Bool,
        previousHadSeparator: Bool,
        hasAnimatedInsertions: Bool,
        hasAnimatedRemovals: Bool,
        at time: CFTimeInterval
    ) {
        guard presentationHasSeparator else {
            separatorPresenceTransition = nil
            separatorPresence = 1
            return
        }

        let targetValue: CGFloat = finalHasSeparator ? 1 : 0
        var currentValue = separatorPresenceTransition?.value(at: time)
            ?? separatorPresence
        if targetValue == 1,
           !previousHadSeparator,
           hasAnimatedInsertions,
           separatorPresenceTransition == nil {
            currentValue = 0
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            separatorPresenceTransition = nil
            separatorPresence = targetValue
            return
        }

        if let transition = separatorPresenceTransition,
           transition.targetValue == targetValue {
            separatorPresence = currentValue
            return
        }

        let shouldAnimate = hasAnimatedInsertions
            || hasAnimatedRemovals
            || separatorPresenceTransition != nil
        guard shouldAnimate, abs(currentValue - targetValue) > 0.0001 else {
            separatorPresenceTransition = nil
            separatorPresence = targetValue
            return
        }
        separatorPresence = currentValue
        separatorPresenceTransition = .transition(
            from: currentValue,
            to: targetValue,
            startTime: time
        )
    }

    private func removeButtonImmediately(_ identity: ApplicationIdentity) {
        itemPresenceTransitions.removeValue(forKey: identity)
        itemPresenceValues.removeValue(forKey: identity)
        removingIdentities.remove(identity)
        launchBounceTransitions.removeValue(forKey: identity)
        launchBounceOffsets.removeValue(forKey: identity)
        guard let button = itemButtons.removeValue(forKey: identity) else { return }
        button.cancelContextMenu()
        if hoveredButton === button {
            clearHoveredButton()
        }
        if contextMenuButton === button {
            contextMenuButton = nil
            isContextMenuPresented = false
        }
        orderedButtons.removeAll { $0 === button }
        button.removeFromSuperview()
    }

    @discardableResult
    private func recalculateRequiredWidth() -> Bool {
        let newValue = DockMagnificationLayout.maximumRequiredWidth(
            itemCount: orderedButtons.count,
            pinnedItemCount: pinnedItemCount,
            iconSize: iconSize,
            spacing: iconSpacing,
            maximumScale: magnificationEnabled ? maximumMagnification : 1,
            influenceRange: magnificationRange
        )
        let changed = abs(newValue - requiredWidth) > 0.01
        requiredWidth = newValue
        return changed
    }

    private func updateLaunchBounceActivity(notify: Bool = true) {
        let isActive = isLaunchBounceAnimationActive
        guard isActive != wasLaunchBounceActive else { return }
        wasLaunchBounceActive = isActive
        if notify {
            onLaunchBounceActivityChange?(isActive)
        }
    }

    private func advanceMagnificationTransition(to time: CFTimeInterval) {
        let deltaTime = max(0, time - (previousAnimationTime ?? time))
        previousAnimationTime = time
        guard !magnificationTransition.isSettled else { return }
        magnificationTransition.advance(by: deltaTime)
    }

    private func updateMagnificationHeadroomActivity() {
        let isActive = DockMagnificationHeadroomPolicy.isActive(
            magnificationEnabled: magnificationEnabled,
            pointerInside: isPointerInside,
            transitionValue: magnificationTransition.value
        )
        guard isActive != isMagnificationHeadroomActive else { return }
        isMagnificationHeadroomActive = isActive
        onMagnificationHeadroomChange?(isActive)
    }

    private func containsInteractivePoint(_ point: NSPoint) -> Bool {
        let minimumX = max(
            bounds.minX,
            visualContentFrame.minX - DockInteractiveRegion.backgroundHorizontalPadding
        )
        let maximumX = min(
            bounds.maxX,
            visualContentFrame.maxX + DockInteractiveRegion.backgroundHorizontalPadding
        )
        let bodyFrame = NSRect(
            x: minimumX,
            y: bounds.minY,
            width: max(0, maximumX - minimumX),
            height: min(bounds.height, iconSize + 20)
        )
        return DockInteractiveRegion.contains(
            point,
            bodyFrame: bodyFrame,
            iconFrames: visibleIconFrames
        )
    }

    private func renderMagnification() {
        let presenceValues = orderedButtons.map { button in
            button.item.flatMap { itemPresenceValues[$0.identity] } ?? 1
        }
        let hasSeparator = pinnedItemCount > 0
            && pinnedItemCount < orderedButtons.count
        let presentedRequiredWidth = DockMagnificationLayout.presentedRequiredWidth(
            itemPresenceProgresses: presenceValues,
            hasSeparator: hasSeparator,
            separatorPresenceProgress: separatorPresence,
            iconSize: iconSize,
            spacing: iconSpacing,
            maximumScale: magnificationEnabled ? maximumMagnification : 1,
            influenceRange: magnificationRange
        )
        let horizontalOffset = DockInsertionHorizontalAlignment.offset(
            presentedRequiredWidth: presentedRequiredWidth,
            finalDocumentWidth: bounds.width,
            finalViewportWidth: enclosingScrollView?.contentSize.width ?? bounds.width
        )
        let layout = DockMagnificationLayout.make(
            itemCount: orderedButtons.count,
            pinnedItemCount: pinnedItemCount,
            iconSize: iconSize,
            spacing: iconSpacing,
            maximumScale: magnificationEnabled ? maximumMagnification : 1,
            influenceRange: magnificationRange,
            containerWidth: bounds.width,
            height: bounds.height,
            pointerX: magnificationEnabled
                ? pointerX.map { $0 - horizontalOffset }
                : nil,
            magnificationProgress: magnificationTransition.value,
            itemPresenceProgresses: presenceValues,
            separatorPresenceProgress: separatorPresence
        )

        visibleIconFrames.removeAll(keepingCapacity: true)
        tooltipHoverFrames.removeAll(keepingCapacity: true)
        for index in orderedButtons.indices {
            let button = orderedButtons[index]
            let targetFrame = layout.buttonFrames[index].offsetBy(
                dx: horizontalOffset,
                dy: 0
            )
            if !NSEqualRects(button.frame, targetFrame) {
                button.frame = targetFrame
            }
            let identity = button.item?.identity
            button.setPresentation(
                magnification: layout.scales[index],
                presenceProgress: presenceValues[index],
                launchBounceOffset: identity.flatMap { launchBounceOffsets[$0] } ?? 0
            )
            let iconFrame = button.iconFrame(in: self)
            if let identity, removingIdentities.contains(identity) {
                tooltipHoverFrames.append(.zero)
            } else {
                visibleIconFrames.append(iconFrame)
                tooltipHoverFrames.append(NSRect(
                    x: targetFrame.minX,
                    y: iconFrame.minY,
                    width: targetFrame.width,
                    height: iconFrame.height
                ))
            }
        }
        updateHoveredButton(at: pointerPoint)

        if let separatorFrame = layout.separatorFrame {
            let scale = window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
            let targetFrame = DockMagnificationLayout.pixelAlignedSeparatorFrame(
                separatorFrame.offsetBy(dx: horizontalOffset, dy: 0),
                backingScaleFactor: scale
            )
            if !NSEqualRects(separatorView.frame, targetFrame) {
                separatorView.frame = targetFrame
            }
            if separatorView.layer?.contentsScale != scale {
                separatorView.layer?.contentsScale = scale
            }
            if abs(separatorView.alphaValue - separatorPresence) > 0.0001 {
                separatorView.alphaValue = separatorPresence
            }
            if separatorView.isHidden {
                separatorView.isHidden = false
            }
        } else if !separatorView.isHidden {
            separatorView.isHidden = true
        }

        visualContentFrame = layout.visualContentFrame.offsetBy(
            dx: horizontalOffset,
            dy: 0
        )
        let backgroundInteraction = DockBackgroundInteractionState(
            visualContentFrame: visualContentFrame
        )
        if backgroundInteraction != previousBackgroundInteraction {
            previousBackgroundInteraction = backgroundInteraction
            onBackgroundInteractionChange?(backgroundInteraction)
        }
    }

    var isLaunchBounceAnimationActive: Bool {
        !launchBounceTransitions.isEmpty
    }

    private var hasActivePresentationAnimation: Bool {
        !itemPresenceTransitions.isEmpty
            || separatorPresenceTransition != nil
            || !launchBounceTransitions.isEmpty
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        finishPresenceAnimations(notifyWidthChange: true)
        finishLaunchBounceAnimations()
        magnificationTransition.snap(to: magnificationTransition.target)
        if !isPointerInside, magnificationTransition.value == 0 {
            pointerX = nil
        }
        renderMagnification()
        updateMagnificationHeadroomActivity()
        if magnificationTransition.isSettled, !hasActivePresentationAnimation {
            stopMagnificationFrameClock()
        }
    }

    private func updateHoveredButton(at point: NSPoint?, reemitCurrent: Bool = true) {
        guard !isContextMenuPresented else {
            clearHoveredButton()
            return
        }
        guard isPointerInside,
              let point,
              let index = DockHoverResolver.hoveredIndex(
                at: point,
                in: bounds,
                hoverFrames: tooltipHoverFrames
              ),
              orderedButtons.indices.contains(index),
              let item = orderedButtons[index].item
        else {
            clearHoveredButton()
            return
        }

        let button = orderedButtons[index]
        if !reemitCurrent, hoveredButton === button {
            return
        }
        hoveredButton = button
        // Re-emit for the same button on every magnification frame. The icon
        // continues moving after mouseEntered, so the tooltip must follow its
        // live frame even while the pointer itself is stationary.
        onHover?(button, item)
    }

    private func clearHoveredButton() {
        guard let hoveredButton else { return }
        self.hoveredButton = nil
        onHover?(hoveredButton, nil)
    }

    private func setContextMenuPresented(
        _ presented: Bool,
        for button: DockItemButton,
        notify: (Bool) -> Void
    ) {
        if presented {
            contextMenuButton = button
            isContextMenuPresented = true
            clearHoveredButton()
            notify(true)
            return
        }

        guard contextMenuButton === button else { return }
        contextMenuButton = nil
        isContextMenuPresented = false
        notify(false)
        restorePointerAfterContextMenu()
    }

    private func restorePointerAfterContextMenu() {
        guard let window else {
            cancelPointerInteraction()
            return
        }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(pointInWindow, from: nil)
        if bounds.contains(point) {
            handlePointer(
                at: point,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
        } else {
            cancelPointerInteraction()
        }
    }

    private func acceptPointerSample(timestamp: TimeInterval) -> Bool {
        let normalizedTimestamp = timestamp > 0 && timestamp.isFinite
            ? timestamp
            : ProcessInfo.processInfo.systemUptime
        return pointerSampleSequence.accept(normalizedTimestamp)
    }

    private func updateSeparatorAppearance() {
        separatorView.layer?.backgroundColor = NSColor.separatorColor
            .withAlphaComponent(0.72)
            .cgColor
    }
}
