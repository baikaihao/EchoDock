import AppKit
import QuartzCore

enum DockPanelVisibilityState {
    case hidden
    case showing
    case visible
    case hiding
    case alwaysVisible

    var allowsTooltipPresentation: Bool {
        switch self {
        case .showing, .visible, .alwaysVisible:
            return true
        case .hidden, .hiding:
            return false
        }
    }

    var allowsItemInsertionAnimation: Bool {
        switch self {
        case .visible, .alwaysVisible:
            return true
        case .hidden, .showing, .hiding:
            return false
        }
    }
}

enum DockPanelPresentationMode: Equatable {
    case suppressed
    case autoHidden
    case alwaysVisible
}

enum DockPanelPresentationPolicy {
    static func mode(
        autoHide: Bool,
        autoHideInFullScreen: Bool,
        isFullScreenActive: Bool
    ) -> DockPanelPresentationMode {
        if autoHideInFullScreen, isFullScreenActive {
            return .suppressed
        }
        return autoHide ? .autoHidden : .alwaysVisible
    }
}

enum DockRunningItemInsertionPolicy {
    static func insertedIdentities(
        previous: DockSnapshot,
        next: DockSnapshot,
        animationsEnabled: Bool
    ) -> Set<ApplicationIdentity> {
        guard animationsEnabled, previous.revision > 0 else { return [] }
        let previousIdentities = Set(previous.items.map(\.identity))
        return Set(next.items.compactMap { item in
            guard item.section == .running,
                  !previousIdentities.contains(item.identity) else {
                return nil
            }
            return item.identity
        })
    }
}

enum DockRunningItemRemovalPolicy {
    static func removedIdentities(
        previous: DockSnapshot,
        next: DockSnapshot,
        animationsEnabled: Bool
    ) -> Set<ApplicationIdentity> {
        guard animationsEnabled, previous.revision > 0 else { return [] }
        let nextIdentities = Set(next.items.map(\.identity))
        return Set(previous.items.compactMap { item in
            guard item.section == .running,
                  !nextIdentities.contains(item.identity) else {
                return nil
            }
            return item.identity
        })
    }
}

enum DockFileShortcutRemovalPolicy {
    static func removedIdentities(
        previous: DockSnapshot,
        next: DockSnapshot,
        animationsEnabled: Bool
    ) -> Set<ApplicationIdentity> {
        guard animationsEnabled, previous.revision > 0 else { return [] }
        let nextIdentities = Set(next.items.map(\.identity))
        return Set(previous.items.compactMap { item in
            guard item.kind.shortcutID != nil,
                  !nextIdentities.contains(item.identity) else {
                return nil
            }
            return item.identity
        })
    }
}

enum DockLaunchBouncePresentationPolicy {
    static func hasLaunchEdge(
        previous: DockSnapshot,
        next: DockSnapshot,
        animationsEnabled: Bool
    ) -> Bool {
        guard animationsEnabled, previous.revision > 0 else { return false }
        let previousStates = Dictionary(uniqueKeysWithValues: previous.items.map {
            ($0.identity, $0.transientState)
        })
        return next.items.contains { item in
            item.section == .pinned
                && item.transientState == .launching
                && previousStates[item.identity] != nil
                && previousStates[item.identity] != .launching
        }
    }

    static func shouldRevealAutoHiddenPanel(
        previous: DockSnapshot,
        next: DockSnapshot,
        state: DockPanelVisibilityState,
        autoHide: Bool,
        animationsEnabled: Bool
    ) -> Bool {
        guard autoHide,
              hasLaunchEdge(
                previous: previous,
                next: next,
                animationsEnabled: animationsEnabled
              ) else {
            return false
        }
        switch state {
        case .hidden, .hiding:
            return true
        case .showing, .visible, .alwaysVisible:
            return false
        }
    }
}

enum DockSampledPointerEntryPolicy {
    static func allowsEntry(
        isInteractivePoint: Bool,
        pressedButtons: Int
    ) -> Bool {
        isInteractivePoint && pressedButtons == 0
    }
}

enum DockBottomInteractionGeometry {
    static let defaultEdgeDepth: CGFloat = 3

    static func normalizedLocation(
        _ location: CGPoint,
        displayFrame: CGRect,
        panelFrame: CGRect
    ) -> CGPoint {
        // The system Dock owns the whole physical edge, not only the span of
        // its icons. Project the gap below EchoDock into the panel's bottom
        // interaction row for every x coordinate on this display.
        guard location.x >= displayFrame.minX,
              location.x <= displayFrame.maxX,
              location.y >= displayFrame.minY,
              location.y < panelFrame.minY else {
            return location
        }
        return CGPoint(x: location.x, y: panelFrame.minY)
    }

    static func bottomEdgeHotZone(
        for displayFrame: CGRect,
        depth: CGFloat = defaultEdgeDepth
    ) -> CGRect {
        let clampedDepth = min(
            max(0, depth),
            max(0, displayFrame.height)
        )
        return CGRect(
            x: displayFrame.minX,
            y: displayFrame.minY,
            width: displayFrame.width,
            height: clampedDepth
        )
    }

    static func containsBottomEdgeHotZone(
        _ location: CGPoint,
        displayFrame: CGRect,
        depth: CGFloat = defaultEdgeDepth
    ) -> Bool {
        let zone = bottomEdgeHotZone(for: displayFrame, depth: depth)
        return location.x >= zone.minX
            && location.x <= zone.maxX
            && location.y >= zone.minY
            && location.y <= zone.maxY
    }

    static func visibleHoldRegion(
        panelFrame: CGRect,
        displayFrame: CGRect,
        margin: CGFloat = 8
    ) -> CGRect {
        // Once revealed, keep the panel alive while the pointer tracks along
        // the same physical bottom edge. This mirrors the system Dock's edge
        // hysteresis and prevents a horizontal sweep from hiding/revealing it
        // between icon slots.
        let bottom = displayFrame.minY
        let top = min(
            displayFrame.maxY,
            max(bottom, panelFrame.maxY + margin)
        )
        return CGRect(
            x: displayFrame.minX,
            y: bottom,
            width: displayFrame.width,
            height: top - bottom
        )
    }
}

@MainActor
final class DockPanelController {
    let displayIdentity: DisplayIdentity

    private let panel = DockPanel()
    private let dragReceiverPanel = DockPanel()
    private let tooltipPanelController = DockTooltipPanelController()
    private let contentView: DockContentView
    private let preferences: PreferencesStore
    private var descriptor: DisplayDescriptor
    private var state: DockPanelVisibilityState = .hidden
    private var snapshot: DockSnapshot = .empty
    private var hotZoneEnteredAt: Date?
    private var mouseLeftAt: Date?
    private var hotZoneRevealTimer: Timer?
    private var hideTimer: Timer?
    private var isContextMenuPresented = false
    private var isFileDragDestinationActive = false
    private var isFileDragCaptureActive = false
    private var isFileDragCaptureRequested = false
    private var fileDragCaptureRevision: UInt = 0
    private var animationGeneration: UInt64 = 0
    private var allDisplays: [DisplayDescriptor] = []
    private var hasAppliedExternalSnapshot = false
    private var isLaunchBounceActive = false
    private var isFullScreenActive = false
    private var isInputCandidateOccluding = false
    private var cachedInputCandidateAvoidanceFrameInScreen: NSRect?
    // The session event tap can consume the event before AppKit updates
    // NSEvent.mouseLocation. Keep the last delivered sample for delayed edge
    // decisions so a stationary pointer remains at the edge it entered.
    private var latestPointerSample: (location: CGPoint, pressedButtons: Int)?

    private var presentationMode: DockPanelPresentationMode {
        DockPanelPresentationPolicy.mode(
            autoHide: preferences.autoHide,
            autoHideInFullScreen: preferences.autoHideInFullScreen,
            isFullScreenActive: isFullScreenActive
        )
    }

    var restingDockBodyFrameInScreen: NSRect? {
        guard panel.isVisible,
              presentationMode != .suppressed else {
            return nil
        }
        return resolvedRestingDockBodyFrameInScreen
    }

    var inputCandidateAvoidanceFrameInScreen: NSRect? {
        if isInputCandidateOccluding {
            return cachedInputCandidateAvoidanceFrameInScreen
                ?? resolvedRestingDockBodyFrameInScreen
        }

        let dockFrame = panel.isVisible
            ? resolvedCurrentDockVisualFrameInScreen
            : resolvedRestingDockBodyFrameInScreen
        guard var avoidanceFrame = dockFrame else { return nil }
        if let tooltipFrame = tooltipPanelController.visibleBubbleFrameInScreen {
            avoidanceFrame = avoidanceFrame.union(tooltipFrame)
        }
        cachedInputCandidateAvoidanceFrameInScreen = avoidanceFrame
        return avoidanceFrame
    }

    private var resolvedRestingDockBodyFrameInScreen: NSRect? {
        resolvedContentFrameInScreen(contentView.restingDockBodyFrame)
    }

    private var resolvedCurrentDockVisualFrameInScreen: NSRect? {
        resolvedContentFrameInScreen(contentView.currentDockVisualFrame)
    }

    private func resolvedContentFrameInScreen(_ frame: NSRect) -> NSRect? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let frameInWindow = contentView.convert(frame, to: nil)
        return panel.convertToScreen(frameInWindow)
    }

    init(
        descriptor: DisplayDescriptor,
        preferences: PreferencesStore,
        iconProvider: ApplicationIconProvider = .shared,
        onItemAction: @escaping (DockItem) -> Void,
        onItemContextAction: @escaping (DockItem, DockItemContextAction) -> Void,
        contextMenuStateProvider: @escaping (DockItem) -> DockItemContextMenuState,
        onDropRequest: @escaping (DockDropRequest) -> Bool
    ) {
        self.displayIdentity = descriptor.identity
        self.descriptor = descriptor
        self.preferences = preferences
        self.contentView = DockContentView(iconProvider: iconProvider)
        contentView.onItemAction = onItemAction
        contentView.onItemContextAction = onItemContextAction
        contentView.onItemContextMenuStateRequest = contextMenuStateProvider
        contentView.onDropRequest = onDropRequest
        contentView.onContextMenuPresentationChange = { [weak self] presented in
            guard let self else { return }
            self.isContextMenuPresented = presented
            self.resetHideTracking()
            if presented {
                self.tooltipPanelController.hide()
            }
        }
        contentView.onTooltipPresentation = { [weak self] presentation in
            guard let self else { return }
            guard self.state.allowsTooltipPresentation else {
                self.tooltipPanelController.hide()
                return
            }
            self.tooltipPanelController.present(presentation)
        }
        contentView.onPreferredSizeChange = { [weak self] size in
            guard let self, !self.isFileDragDestinationActive else { return }
            self.resizePanel(to: size)
        }
        contentView.onLaunchBounceActivityChange = { [weak self] isActive in
            guard let self else { return }
            self.isLaunchBounceActive = isActive
            // A launch hop is a fixed sequence. Restart the normal hide-delay
            // countdown only after the content view reports that it finished.
            self.resetHideTracking()
        }
        contentView.onPointerInteractionChange = { [weak self] _ in
            guard let self,
                  self.panel.isVisible,
                  !self.isFileDragDestinationActive,
                  !self.isContextMenuPresented else { return }
            // The visible Dock is also the NSDraggingDestination for the file
            // section. Making the whole window click-through prevents Finder
            // from ever delivering draggingEntered when a drag begins outside
            // EchoDock, so keep the destination in WindowServer's hit-test path.
            self.panel.ignoresMouseEvents = false
        }
        contentView.onFileDragActivityChange = { [weak self] isActive in
            guard let self else { return }
            self.isFileDragDestinationActive = isActive
            if isActive {
                self.activateFileDragCapture()
                self.panel.ignoresMouseEvents = false
                self.mouseLeftAt = nil
            }
            self.resizePanel(to: self.contentView.frame.size)
            if !isActive, !self.isFileDragCaptureRequested {
                self.scheduleFileDragCaptureCollapse()
            }
            if self.panel.isVisible, !self.isContextMenuPresented {
                self.panel.ignoresMouseEvents = false
            }
        }
        panel.onPointerEvent = { [weak self] event in
            guard let self, self.panel.isVisible else { return }
            let screenLocation = self.panel.convertPoint(
                toScreen: event.locationInWindow
            )
            self.contentView.reconcilePointer(
                screenLocation: screenLocation,
                timestamp: event.timestamp,
                allowsSyntheticEntry: NSEvent.pressedMouseButtons == 0
            )
        }
        panel.onDraggingEntered = { [weak self] sender in
            self?.contentView.draggingEntered(sender) ?? []
        }
        panel.onDraggingUpdated = { [weak self] sender in
            self?.contentView.draggingUpdated(sender) ?? []
        }
        panel.onDraggingExited = { [weak self] sender in
            self?.contentView.draggingExited(sender)
        }
        panel.onPrepareForDragOperation = { [weak self] sender in
            self?.contentView.prepareForDragOperation(sender) ?? false
        }
        panel.onPerformDragOperation = { [weak self] sender in
            self?.contentView.performDragOperation(sender) ?? false
        }
        panel.onConcludeDragOperation = { [weak self] sender in
            self?.contentView.concludeDragOperation(sender)
        }
        panel.onDraggingEnded = { [weak self] sender in
            self?.contentView.draggingEnded(sender)
        }
        panel.contentView = contentView
        dragReceiverPanel.level = EchoDockWindowLevel.dragReceiver
        dragReceiverPanel.ignoresMouseEvents = true
        dragReceiverPanel.onDraggingEntered = { [weak self] sender in
            self?.contentView.draggingEntered(sender) ?? []
        }
        dragReceiverPanel.onDraggingUpdated = { [weak self] sender in
            self?.contentView.draggingUpdated(sender) ?? []
        }
        dragReceiverPanel.onDraggingExited = { [weak self] sender in
            self?.contentView.draggingExited(sender)
        }
        dragReceiverPanel.onPrepareForDragOperation = { [weak self] sender in
            self?.contentView.prepareForDragOperation(sender) ?? false
        }
        dragReceiverPanel.onPerformDragOperation = { [weak self] sender in
            self?.contentView.performDragOperation(sender) ?? false
        }
        dragReceiverPanel.onConcludeDragOperation = { [weak self] sender in
            self?.contentView.concludeDragOperation(sender)
        }
        dragReceiverPanel.onDraggingEnded = { [weak self] sender in
            self?.contentView.draggingEnded(sender)
        }
        dragReceiverPanel.contentView = NSView(frame: .zero)
        applyLayout()
    }

    func updateDescriptor(_ descriptor: DisplayDescriptor, allDisplays: [DisplayDescriptor]) {
        guard self.descriptor != descriptor || self.allDisplays != allDisplays else { return }
        self.descriptor = descriptor
        self.allDisplays = allDisplays
        cachedInputCandidateAvoidanceFrameInScreen = nil
        applyLayout()
    }

    func setFullScreenActive(_ isActive: Bool) {
        guard isFullScreenActive != isActive else { return }
        isFullScreenActive = isActive
        reconcilePresentationMode(animated: false)
    }

    func setInputCandidateOccluding(_ isOccluding: Bool) {
        guard isInputCandidateOccluding != isOccluding else { return }
        isInputCandidateOccluding = isOccluding
        reconcilePresentationMode(animated: false)
    }

    func apply(snapshot: DockSnapshot, itemAnimationsEnabled: Bool = true) {
        guard self.snapshot != snapshot else { return }
        let animationPrerequisitesMet = itemAnimationsEnabled
            && hasAppliedExternalSnapshot
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if DockLaunchBouncePresentationPolicy.shouldRevealAutoHiddenPanel(
            previous: self.snapshot,
            next: snapshot,
            state: state,
            autoHide: presentationMode == .autoHidden,
            animationsEnabled: animationPrerequisitesMet
                && preferences.launchBounceEnabled
        ) {
            show(always: false, animated: true)
        }
        let itemTransitionAnimationsEnabled = animationPrerequisitesMet
            && panel.isVisible
            && state.allowsItemInsertionAnimation
        let launchBounceAnimationsEnabled = animationPrerequisitesMet
            && panel.isVisible
            && preferences.launchBounceEnabled
        let insertedRunningIdentities = DockRunningItemInsertionPolicy.insertedIdentities(
            previous: self.snapshot,
            next: snapshot,
            animationsEnabled: itemTransitionAnimationsEnabled
        )
        let removedRunningIdentities = DockRunningItemRemovalPolicy.removedIdentities(
            previous: self.snapshot,
            next: snapshot,
            animationsEnabled: itemTransitionAnimationsEnabled
                && preferences.showRunningApplications
                && !isContextMenuPresented
        )
        let removedFileShortcutIdentities = DockFileShortcutRemovalPolicy.removedIdentities(
            previous: self.snapshot,
            next: snapshot,
            animationsEnabled: itemTransitionAnimationsEnabled
                && !isContextMenuPresented
        )
        self.snapshot = snapshot
        hasAppliedExternalSnapshot = true
        applyLayout(
            animatedInsertionIdentities: insertedRunningIdentities,
            animatedRemovalIdentities: removedRunningIdentities.union(
                removedFileShortcutIdentities
            ),
            launchBounceAnimationsEnabled: launchBounceAnimationsEnabled
        )
    }

    func applyPreferences() {
        applyLayout()
        reconcilePresentationMode(animated: state != .alwaysVisible)
    }

    func processMouse(
        location: CGPoint,
        pressedButtons: Int,
        now: Date,
        isFileDrag: Bool = false
    ) {
        latestPointerSample = (location, pressedButtons)
        guard !isInputCandidateOccluding,
              presentationMode != .suppressed else {
            return
        }
        updateFileDragCaptureRequest(
            preferences.isEnabled && isFileDrag && pressedButtons != 0
        )
        guard preferences.isEnabled else {
            hide(animated: false)
            return
        }
        if isContextMenuPresented {
            panel.ignoresMouseEvents = false
            resetHideTracking()
            return
        }
        let hasActiveFileDrag = isFileDrag
            || isFileDragDestinationActive
            || isFileDragCaptureActive
        let hasPotentialPointerDrag = pressedButtons != 0
        let shouldHoldForDrag = hasActiveFileDrag || hasPotentialPointerDrag
        let interactionLocation = DockBottomInteractionGeometry.normalizedLocation(
            location,
            displayFrame: descriptor.frame,
            panelFrame: panel.frame
        )
        var allowsSyntheticPointerEntry = false
        if panel.isVisible, hasPotentialPointerDrag {
            // A cross-process drag is not guaranteed to expose its payload on
            // the global drag pasteboard. Let the registered destination
            // inspect NSDraggingInfo instead of leaving the panel click-through.
            panel.ignoresMouseEvents = false
            resetHideTracking()
        }
        if panel.isVisible, pressedButtons == 0, !hasActiveFileDrag {
            let isInteractivePoint = contentView.shouldReceiveMouse(at: interactionLocation)
            panel.ignoresMouseEvents = false
            allowsSyntheticPointerEntry = DockSampledPointerEntryPolicy.allowsEntry(
                isInteractivePoint: isInteractivePoint,
                pressedButtons: pressedButtons
            )
        }
        if hasActiveFileDrag, panel.isVisible {
            panel.ignoresMouseEvents = false
            resetHideTracking()
        }
        if isFileDragDestinationActive, hasPotentialPointerDrag {
            let isOutsideDragContinuationFrame = !panel.frame.contains(location)
            if isOutsideDragContinuationFrame {
                contentView.cancelFileDrag()
            }
        }
        if state.allowsTooltipPresentation {
            if panel.isVisible {
                contentView.reconcilePointer(
                    screenLocation: interactionLocation,
                    allowsSyntheticEntry: allowsSyntheticPointerEntry
                )
            } else {
                // The tooltip is a separate panel and must never outlive the
                // Dock if the window server removes the main panel externally.
                // Converge the controller state too, so always-visible mode can
                // restore the Dock instead of remaining logically visible.
                hide(animated: false)
            }
        }
        guard presentationMode == .autoHidden else {
            if state != .alwaysVisible { show(always: true, animated: true) }
            return
        }

        if isLaunchBounceActive {
            resetHideTracking()
            switch state {
            case .showing, .visible, .alwaysVisible:
                return
            case .hidden, .hiding:
                break
            }
        }

        switch state {
        case .hidden, .hiding:
            guard isInHotZone(location) else {
                resetHotZoneTracking()
                return
            }
            if hotZoneEnteredAt == nil {
                hotZoneEnteredAt = now
            }
            let requiredDelay = isInternalBottomEdge(atX: location.x) ? preferences.internalEdgeDelay : 0
            let elapsed = now.timeIntervalSince(hotZoneEnteredAt ?? now)
            if shouldHoldForDrag || elapsed >= requiredDelay {
                show(always: false, animated: true)
                resetHotZoneTracking()
            } else {
                scheduleHotZoneReveal(after: requiredDelay - elapsed)
            }

        case .showing, .visible:
            if shouldHoldForDrag {
                resetHideTracking()
                return
            }
            let holdRegion = DockBottomInteractionGeometry.visibleHoldRegion(
                panelFrame: panel.frame,
                displayFrame: descriptor.frame
            )
            if holdRegion.contains(location) {
                resetHideTracking()
            } else {
                if mouseLeftAt == nil { mouseLeftAt = now }
                let elapsed = now.timeIntervalSince(mouseLeftAt ?? now)
                if elapsed >= preferences.hideDelay {
                    hide(animated: true)
                    resetHideTracking()
                } else {
                    scheduleHide(after: preferences.hideDelay - elapsed)
                }
            }

        case .alwaysVisible:
            break
        }
    }

    func destroy() {
        animationGeneration &+= 1
        fileDragCaptureRevision &+= 1
        resetHotZoneTracking()
        resetHideTracking()
        contentView.cancelFileDrag()
        panel.ignoresMouseEvents = false
        contentView.resetInteraction()
        isContextMenuPresented = false
        tooltipPanelController.hide()
        dragReceiverPanel.orderOut(nil)
        panel.orderOut(nil)
        panel.onPointerEvent = nil
        panel.onDraggingEntered = nil
        panel.onDraggingUpdated = nil
        panel.onDraggingExited = nil
        panel.onPrepareForDragOperation = nil
        panel.onPerformDragOperation = nil
        panel.onConcludeDragOperation = nil
        panel.onDraggingEnded = nil
        panel.contentView = nil
        dragReceiverPanel.onDraggingEntered = nil
        dragReceiverPanel.onDraggingUpdated = nil
        dragReceiverPanel.onDraggingExited = nil
        dragReceiverPanel.onPrepareForDragOperation = nil
        dragReceiverPanel.onPerformDragOperation = nil
        dragReceiverPanel.onConcludeDragOperation = nil
        dragReceiverPanel.onDraggingEnded = nil
        dragReceiverPanel.contentView = nil
        dragReceiverPanel.ignoresMouseEvents = true
    }

    private func applyLayout(
        animatedInsertionIdentities: Set<ApplicationIdentity> = [],
        animatedRemovalIdentities: Set<ApplicationIdentity> = [],
        launchBounceAnimationsEnabled: Bool = false
    ) {
        let maximumWidth = max(160, descriptor.frame.width - 24)
        contentView.apply(
            snapshot: snapshot,
            iconSize: preferences.iconSize,
            maxWidth: maximumWidth,
            backgroundTransparency: preferences.dockTransparency,
            backgroundBlur: preferences.dockBackgroundBlur,
            backgroundStyle: preferences.dockBackgroundStyle,
            magnificationEnabled: preferences.magnificationEnabled,
            magnificationScale: preferences.magnificationScale,
            magnificationRange: preferences.magnificationRange,
            iconSpacing: preferences.iconSpacing,
            tooltipGap: preferences.tooltipGap,
            animatedInsertionIdentities: animatedInsertionIdentities,
            animatedRemovalIdentities: animatedRemovalIdentities,
            launchBounceAnimationsEnabled: launchBounceAnimationsEnabled,
            runningIndicatorsEnabled: preferences.runningIndicatorsEnabled
        )
        let size = contentView.frame.size
        let shouldDisplay = panel.isVisible
        if isFileDragDestinationActive {
            contentView.needsLayout = true
            contentView.layoutSubtreeIfNeeded()
        } else {
            let originX = descriptor.frame.midX - size.width / 2
            let origin = NSPoint(
                x: originX,
                y: descriptor.frame.minY + 6
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        if shouldDisplay, state.allowsTooltipPresentation {
            reconcileCurrentPointer()
        }
        if shouldDisplay {
            panel.displayIfNeeded()
        }
        if isInputCandidateOccluding {
            cachedInputCandidateAvoidanceFrameInScreen =
                resolvedCurrentDockVisualFrameInScreen
                ?? resolvedRestingDockBodyFrameInScreen
        }
    }

    private func show(always: Bool, animated: Bool) {
        guard !isInputCandidateOccluding,
              presentationMode != .suppressed else {
            return
        }
        animationGeneration &+= 1
        let generation = animationGeneration
        resetHotZoneTracking()
        resetHideTracking()
        state = always ? .alwaysVisible : .showing
        applyLayout()
        contentView.resetInteraction()
        tooltipPanelController.hide()
        panel.ignoresMouseEvents = false
        contentView.alphaValue = animated ? 0 : 1
        var startFrame = contentView.bounds
        startFrame.origin.y = animated ? -contentView.frame.height : 0
        contentView.frame = startFrame
        panel.orderFrontRegardless()

        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            contentView.frame.origin = .zero
            contentView.alphaValue = 1
            if !always { state = .visible }
            reconcileCurrentPointer()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setFrameOrigin(.zero)
            contentView.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.animationGeneration == generation else { return }
                if !always { self.state = .visible }
                self.reconcileCurrentPointer()
            }
        }
    }

    private func hide(animated: Bool) {
        guard state != .hidden else { return }
        animationGeneration &+= 1
        let generation = animationGeneration
        resetHotZoneTracking()
        resetHideTracking()
        state = .hiding
        contentView.cancelFileDrag()
        panel.ignoresMouseEvents = false
        contentView.resetInteraction()
        isContextMenuPresented = false
        tooltipPanelController.hide()

        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.tooltipPanelController.hide()
            self.panel.orderOut(nil)
            self.contentView.alphaValue = 1
            self.contentView.frame.origin = .zero
            self.state = .hidden
        }

        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            contentView.animator().setFrameOrigin(NSPoint(x: 0, y: -contentView.frame.height))
            contentView.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in finish() }
        })
    }

    private func reconcilePresentationMode(animated: Bool) {
        resetHotZoneTracking()
        resetHideTracking()

        if isInputCandidateOccluding {
            forceHideImmediately()
            return
        }

        switch presentationMode {
        case .suppressed:
            forceHideImmediately()
        case .autoHidden:
            if state == .alwaysVisible {
                hide(animated: false)
            }
        case .alwaysVisible:
            show(always: true, animated: animated)
        }
    }

    private func forceHideImmediately() {
        animationGeneration &+= 1
        resetHotZoneTracking()
        resetHideTracking()
        state = .hidden
        contentView.cancelFileDrag()
        fileDragCaptureRevision &+= 1
        isFileDragDestinationActive = false
        isFileDragCaptureActive = false
        isFileDragCaptureRequested = false
        panel.ignoresMouseEvents = false
        contentView.resetInteraction()
        isContextMenuPresented = false
        tooltipPanelController.hide()
        dragReceiverPanel.orderOut(nil)
        dragReceiverPanel.ignoresMouseEvents = true
        panel.orderOut(nil)
        contentView.alphaValue = 1
        contentView.frame.origin = .zero
    }

    private func reconcileCurrentPointer() {
        guard panel.isVisible,
              currentPressedMouseButtons == 0,
              !isFileDragDestinationActive,
              !isFileDragCaptureActive else { return }
        let location = DockBottomInteractionGeometry.normalizedLocation(
            currentPointerLocation,
            displayFrame: descriptor.frame,
            panelFrame: panel.frame
        )
        let allowsEntry = contentView.shouldReceiveMouse(at: location)
        contentView.reconcilePointer(
            screenLocation: location,
            allowsSyntheticEntry: allowsEntry
        )
    }

    private func resetHotZoneTracking() {
        hotZoneRevealTimer?.invalidate()
        hotZoneRevealTimer = nil
        hotZoneEnteredAt = nil
    }

    private func scheduleHotZoneReveal(after delay: TimeInterval) {
        guard hotZoneRevealTimer == nil else { return }
        let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hotZoneRevealTimer = nil
                self.evaluateHotZoneReveal()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hotZoneRevealTimer = timer
    }

    private func evaluateHotZoneReveal() {
        guard presentationMode == .autoHidden,
              !isInputCandidateOccluding,
              state == .hidden || state == .hiding else {
            resetHotZoneTracking()
            return
        }
        let location = currentPointerLocation
        guard isInHotZone(location) else {
            resetHotZoneTracking()
            return
        }

        let now = Date()
        if hotZoneEnteredAt == nil {
            hotZoneEnteredAt = now
        }
        let requiredDelay = isInternalBottomEdge(atX: location.x)
            ? preferences.internalEdgeDelay
            : 0
        let elapsed = now.timeIntervalSince(hotZoneEnteredAt ?? now)
        if currentPressedMouseButtons != 0 || elapsed >= requiredDelay {
            show(always: false, animated: true)
        } else {
            scheduleHotZoneReveal(after: requiredDelay - elapsed)
        }
    }

    private func resetHideTracking() {
        hideTimer?.invalidate()
        hideTimer = nil
        mouseLeftAt = nil
    }

    private func scheduleHide(after delay: TimeInterval) {
        guard hideTimer == nil else { return }
        let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideTimer = nil
                self.evaluateScheduledHide()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func evaluateScheduledHide() {
        guard presentationMode == .autoHidden,
              state == .showing || state == .visible,
              !isContextMenuPresented,
              !isLaunchBounceActive,
              !isFileDragDestinationActive,
              !isFileDragCaptureActive,
              currentPressedMouseButtons == 0 else {
            resetHideTracking()
            return
        }

        let location = currentPointerLocation
        let holdRegion = DockBottomInteractionGeometry.visibleHoldRegion(
            panelFrame: panel.frame,
            displayFrame: descriptor.frame
        )
        guard !holdRegion.contains(location) else {
            resetHideTracking()
            return
        }

        let now = Date()
        if mouseLeftAt == nil {
            mouseLeftAt = now
        }
        let elapsed = now.timeIntervalSince(mouseLeftAt ?? now)
        if elapsed >= preferences.hideDelay {
            hide(animated: true)
        } else {
            scheduleHide(after: preferences.hideDelay - elapsed)
        }
    }

    private func isInHotZone(_ location: CGPoint) -> Bool {
        DockBottomInteractionGeometry.containsBottomEdgeHotZone(
            location,
            displayFrame: descriptor.frame
        )
    }

    private var currentPointerLocation: CGPoint {
        latestPointerSample?.location ?? NSEvent.mouseLocation
    }

    private var currentPressedMouseButtons: Int {
        latestPointerSample?.pressedButtons ?? NSEvent.pressedMouseButtons
    }

    private func resizePanel(to size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let originX = descriptor.frame.midX - size.width / 2
        let targetFrame = NSRect(
            x: originX,
            y: descriptor.frame.minY + 6,
            width: size.width,
            height: size.height
        )
        guard !NSEqualRects(panel.frame, targetFrame) else { return }
        let shouldDisplay = panel.isVisible
        panel.setFrame(targetFrame, display: false)
        if isFileDragDestinationActive {
            contentView.needsLayout = true
            contentView.layoutSubtreeIfNeeded()
        }
        if shouldDisplay, state.allowsTooltipPresentation {
            reconcileCurrentPointer()
        }
        if shouldDisplay {
            panel.displayIfNeeded()
        }
    }

    private func updateFileDragCaptureRequest(_ requested: Bool) {
        guard isFileDragCaptureRequested != requested else { return }
        isFileDragCaptureRequested = requested
        if requested {
            activateFileDragCapture()
        } else {
            scheduleFileDragCaptureCollapse()
        }
    }

    private func activateFileDragCapture() {
        fileDragCaptureRevision &+= 1
        guard presentationMode != .suppressed,
              !isFileDragCaptureActive else { return }

        isFileDragCaptureActive = true
        dragReceiverPanel.setFrame(fileDragReceiverFrame, display: false)
        dragReceiverPanel.ignoresMouseEvents = false
        dragReceiverPanel.orderFrontRegardless()
    }

    private func scheduleFileDragCaptureCollapse() {
        fileDragCaptureRevision &+= 1
        let revision = fileDragCaptureRevision
        // Mouse-up can precede AppKit's prepare/perform callbacks. Keep the
        // destination stable briefly so release never collapses it first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  self.fileDragCaptureRevision == revision,
                  !self.isFileDragCaptureRequested,
                  !self.isFileDragDestinationActive else { return }

            self.isFileDragCaptureActive = false
            self.dragReceiverPanel.ignoresMouseEvents = true
            self.dragReceiverPanel.orderOut(nil)
        }
    }

    private var fileDragReceiverFrame: NSRect {
        let maximumWidth = max(160, descriptor.frame.width - 24)
        let iconSpacing = min(28, max(4, preferences.iconSpacing))
        let reservedWidth = min(
            maximumWidth,
            panel.frame.width + preferences.iconSize + iconSpacing
        )
        let bodyTop = panel.frame.minY
            + min(contentView.dockBodyHeight, panel.frame.height)
        return NSRect(
            x: descriptor.frame.midX - reservedWidth / 2,
            y: descriptor.frame.minY,
            width: reservedWidth,
            height: max(1, bodyTop - descriptor.frame.minY)
        )
    }

    private func isInternalBottomEdge(atX x: CGFloat) -> Bool {
        allDisplays.contains { other in
            guard other.identity != descriptor.identity else { return false }
            let verticallyAdjacent = abs(other.frame.maxY - descriptor.frame.minY) <= 1
            let horizontallyOverlapping = x >= other.frame.minX && x <= other.frame.maxX
            return verticallyAdjacent && horizontallyOverlapping
        }
    }
}
