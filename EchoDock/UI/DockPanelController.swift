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
        wasIgnoringMouseEvents: Bool,
        isInteractivePoint: Bool,
        pressedButtons: Int
    ) -> Bool {
        wasIgnoringMouseEvents && isInteractivePoint && pressedButtons == 0
    }
}

@MainActor
final class DockPanelController {
    let displayIdentity: DisplayIdentity

    var needsImmediatePointerSample: Bool {
        panel.isVisible
            && panel.ignoresMouseEvents
            && state.allowsTooltipPresentation
            && !isContextMenuPresented
    }

    private let panel = DockPanel()
    private let tooltipPanelController = DockTooltipPanelController()
    private let contentView = DockContentView()
    private let preferences: PreferencesStore
    private var descriptor: DisplayDescriptor
    private var state: DockPanelVisibilityState = .hidden
    private var snapshot: DockSnapshot = .empty
    private var hotZoneEnteredAt: Date?
    private var mouseLeftAt: Date?
    private var isContextMenuPresented = false
    private var animationGeneration: UInt64 = 0
    private var allDisplays: [DisplayDescriptor] = []
    private var hasAppliedExternalSnapshot = false
    private var isLaunchBounceActive = false

    init(
        descriptor: DisplayDescriptor,
        preferences: PreferencesStore,
        onItemAction: @escaping (DockItem) -> Void,
        onItemContextAction: @escaping (DockItem, DockItemContextAction) -> Void,
        contextMenuStateProvider: @escaping (DockItem) -> DockItemContextMenuState
    ) {
        self.displayIdentity = descriptor.identity
        self.descriptor = descriptor
        self.preferences = preferences
        contentView.onItemAction = onItemAction
        contentView.onItemContextAction = onItemContextAction
        contentView.onItemContextMenuStateRequest = contextMenuStateProvider
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
            self?.resizePanel(to: size)
        }
        contentView.onLaunchBounceActivityChange = { [weak self] isActive in
            guard let self else { return }
            self.isLaunchBounceActive = isActive
            // A launch hop is a fixed sequence. Restart the normal hide-delay
            // countdown only after the content view reports that it finished.
            self.mouseLeftAt = nil
        }
        contentView.onPointerInteractionChange = { [weak self] isActive in
            guard let self,
                  self.panel.isVisible,
                  !self.isContextMenuPresented else { return }
            let shouldIgnoreMouseEvents = !isActive
            if self.panel.ignoresMouseEvents != shouldIgnoreMouseEvents {
                self.panel.ignoresMouseEvents = shouldIgnoreMouseEvents
            }
        }
        panel.onPointerEvent = { [weak self] event in
            guard let self, self.panel.isVisible else { return }
            let screenLocation = self.panel.convertPoint(
                toScreen: event.locationInWindow
            )
            self.contentView.reconcilePointer(
                screenLocation: screenLocation,
                timestamp: event.timestamp
            )
        }
        panel.contentView = contentView
        applyLayout()
    }

    func updateDescriptor(_ descriptor: DisplayDescriptor, allDisplays: [DisplayDescriptor]) {
        guard self.descriptor != descriptor || self.allDisplays != allDisplays else { return }
        self.descriptor = descriptor
        self.allDisplays = allDisplays
        applyLayout()
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
            autoHide: preferences.autoHide,
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
        self.snapshot = snapshot
        hasAppliedExternalSnapshot = true
        applyLayout(
            animatedInsertionIdentities: insertedRunningIdentities,
            animatedRemovalIdentities: removedRunningIdentities,
            launchBounceAnimationsEnabled: launchBounceAnimationsEnabled
        )
    }

    func applyPreferences() {
        applyLayout()
        if preferences.autoHide {
            if state == .alwaysVisible {
                hide(animated: false)
            }
        } else {
            show(always: true, animated: state != .alwaysVisible)
        }
    }

    func processMouse(location: CGPoint, pressedButtons: Int, now: Date) {
        guard preferences.isEnabled else {
            hide(animated: false)
            return
        }
        if isContextMenuPresented {
            panel.ignoresMouseEvents = false
            mouseLeftAt = nil
            return
        }
        var allowsSyntheticPointerEntry = false
        if panel.isVisible, pressedButtons == 0 {
            let wasIgnoringMouseEvents = panel.ignoresMouseEvents
            let isInteractivePoint = contentView.shouldReceiveMouse(at: location)
            let shouldIgnoreMouseEvents = !isInteractivePoint
            if panel.ignoresMouseEvents != shouldIgnoreMouseEvents {
                panel.ignoresMouseEvents = shouldIgnoreMouseEvents
            }
            allowsSyntheticPointerEntry = DockSampledPointerEntryPolicy.allowsEntry(
                wasIgnoringMouseEvents: wasIgnoringMouseEvents,
                isInteractivePoint: isInteractivePoint,
                pressedButtons: pressedButtons
            )
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
        guard preferences.autoHide else {
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
            guard pressedButtons == 0, isInHotZone(location) else {
                hotZoneEnteredAt = nil
                return
            }
            if hotZoneEnteredAt == nil {
                hotZoneEnteredAt = now
            }
            let requiredDelay = isInternalBottomEdge(atX: location.x) ? preferences.internalEdgeDelay : 0
            if now.timeIntervalSince(hotZoneEnteredAt ?? now) >= requiredDelay {
                show(always: false, animated: true)
                hotZoneEnteredAt = nil
            }

        case .showing, .visible:
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
        contentView.resetInteraction()
        isContextMenuPresented = false
        tooltipPanelController.hide()
        panel.orderOut(nil)
        panel.onPointerEvent = nil
        panel.contentView = nil
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
        let origin = NSPoint(
            x: descriptor.frame.midX - size.width / 2,
            y: descriptor.frame.minY + 6
        )
        let shouldDisplay = panel.isVisible
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        if shouldDisplay, state.allowsTooltipPresentation {
            contentView.reconcilePointer(screenLocation: NSEvent.mouseLocation)
        }
        if shouldDisplay {
            panel.displayIfNeeded()
        }
    }

    private func show(always: Bool, animated: Bool) {
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
        let targetFrame = NSRect(
            x: descriptor.frame.midX - size.width / 2,
            y: descriptor.frame.minY + 6,
            width: size.width,
            height: size.height
        )
        guard !NSEqualRects(panel.frame, targetFrame) else { return }
        let shouldDisplay = panel.isVisible
        panel.setFrame(targetFrame, display: false)
        if shouldDisplay, state.allowsTooltipPresentation {
            contentView.reconcilePointer(screenLocation: NSEvent.mouseLocation)
        }
        if shouldDisplay {
            panel.displayIfNeeded()
        }
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
