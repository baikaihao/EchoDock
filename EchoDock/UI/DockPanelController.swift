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

    private var presentationMode: DockPanelPresentationMode {
        DockPanelPresentationPolicy.mode(
            autoHide: preferences.autoHide,
            autoHideInFullScreen: preferences.autoHideInFullScreen,
            isFullScreenActive: isFullScreenActive
        )
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
            self.mouseLeftAt = nil
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
            self.mouseLeftAt = nil
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
        dragReceiverPanel.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 1
        )
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
        applyLayout()
    }

    func setFullScreenActive(_ isActive: Bool) {
        guard isFullScreenActive != isActive else { return }
        isFullScreenActive = isActive
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
        guard presentationMode != .suppressed else { return }
        updateFileDragCaptureRequest(
            preferences.isEnabled && isFileDrag && pressedButtons != 0
        )
        guard preferences.isEnabled else {
            hide(animated: false)
            return
        }
        if isContextMenuPresented {
            panel.ignoresMouseEvents = false
            mouseLeftAt = nil
            return
        }
        let hasActiveFileDrag = isFileDrag
            || isFileDragDestinationActive
            || isFileDragCaptureActive
        let hasPotentialPointerDrag = pressedButtons != 0
        let shouldHoldForDrag = hasActiveFileDrag || hasPotentialPointerDrag
        var allowsSyntheticPointerEntry = false
        if panel.isVisible, hasPotentialPointerDrag {
            // A cross-process drag is not guaranteed to expose its payload on
            // the global drag pasteboard. Let the registered destination
            // inspect NSDraggingInfo instead of leaving the panel click-through.
            panel.ignoresMouseEvents = false
            mouseLeftAt = nil
        }
        if panel.isVisible, pressedButtons == 0, !hasActiveFileDrag {
            let isInteractivePoint = contentView.shouldReceiveMouse(at: location)
            panel.ignoresMouseEvents = false
            allowsSyntheticPointerEntry = DockSampledPointerEntryPolicy.allowsEntry(
                isInteractivePoint: isInteractivePoint,
                pressedButtons: pressedButtons
            )
        }
        if hasActiveFileDrag, panel.isVisible {
            panel.ignoresMouseEvents = false
            mouseLeftAt = nil
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
                    screenLocation: location,
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
            mouseLeftAt = nil
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
                hotZoneEnteredAt = nil
                return
            }
            if hotZoneEnteredAt == nil {
                hotZoneEnteredAt = now
            }
            let requiredDelay = isInternalBottomEdge(atX: location.x) ? preferences.internalEdgeDelay : 0
            if shouldHoldForDrag
                || now.timeIntervalSince(hotZoneEnteredAt ?? now) >= requiredDelay {
                show(always: false, animated: true)
                hotZoneEnteredAt = nil
            }

        case .showing, .visible:
            if shouldHoldForDrag {
                mouseLeftAt = nil
                return
            }
            if panel.frame.insetBy(dx: -8, dy: -8).contains(location) {
                mouseLeftAt = nil
            } else {
                if mouseLeftAt == nil { mouseLeftAt = now }
                if now.timeIntervalSince(mouseLeftAt ?? now) >= preferences.hideDelay {
                    hide(animated: true)
                    mouseLeftAt = nil
                }
            }

        case .alwaysVisible:
            break
        }
    }

    func destroy() {
        animationGeneration &+= 1
        fileDragCaptureRevision &+= 1
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
            contentView.reconcilePointer(screenLocation: NSEvent.mouseLocation)
        }
        if shouldDisplay {
            panel.displayIfNeeded()
        }
    }

    private func show(always: Bool, animated: Bool) {
        guard presentationMode != .suppressed else { return }
        animationGeneration &+= 1
        let generation = animationGeneration
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
            }
        }
    }

    private func hide(animated: Bool) {
        guard state != .hidden else { return }
        animationGeneration &+= 1
        let generation = animationGeneration
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
        hotZoneEnteredAt = nil
        mouseLeftAt = nil

        switch presentationMode {
        case .suppressed:
            forceHideForFullScreen()
        case .autoHidden:
            if state == .alwaysVisible {
                hide(animated: false)
            }
        case .alwaysVisible:
            show(always: true, animated: animated)
        }
    }

    private func forceHideForFullScreen() {
        animationGeneration &+= 1
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

    private func isInHotZone(_ location: CGPoint) -> Bool {
        let width = min(descriptor.frame.width - 24, max(240, panel.frame.width))
        let minimumX = descriptor.frame.midX - width / 2
        let maximumX = descriptor.frame.midX + width / 2
        return location.x >= minimumX
            && location.x <= maximumX
            && location.y >= descriptor.frame.minY
            && location.y <= descriptor.frame.minY + 3
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
            contentView.reconcilePointer(screenLocation: NSEvent.mouseLocation)
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
