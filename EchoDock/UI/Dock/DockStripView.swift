import AppKit
import QuartzCore

final class DockStripView: NSView {
    var animationClock: DockAnimationClock?
    private var isRenderingMagnification = false
    var position: DockPosition = .bottom {
        didSet {
            guard position != oldValue else { return }
            cancelPointerInteraction()
            needsLayout = true
        }
    }
    override var isFlipped: Bool { position.isVertical }
    private var layoutSize: NSSize { position.layoutSize(for: bounds.size) }
    private func layoutPoint(_ point: NSPoint) -> NSPoint {
        position.contentPosition.layoutPoint(point, in: layoutSize, flippedVertical: position.isVertical)
    }
    private func layoutRect(_ rect: NSRect) -> NSRect {
        position.contentPosition.layoutRect(rect, in: layoutSize, flippedVertical: position.isVertical)
    }
    private func viewRect(_ rect: NSRect) -> NSRect {
        position.contentPosition.viewRect(rect, in: layoutSize, flippedVertical: position.isVertical)
    }
    var onBackgroundInteractionChange: ((DockBackgroundInteractionState) -> Void)?
    var onMagnificationHeadroomChange: ((Bool) -> Void)?
    var onPointerInteractionChange: ((Bool) -> Void)?
    var onRequiredWidthChange: (() -> Void)?
    var onLaunchBounceActivityChange: ((Bool) -> Void)?
    var onBackgroundContextMenu: ((NSEvent) -> Void)?
    var screenLocationNormalizer: ((NSPoint) -> NSPoint)?

    private var itemButtons: [ApplicationIdentity: DockItemButton] = [:]
    private var orderedButtons: [DockItemButton] = []
    private var separatorViews: [NSView] = []
    private var pinnedItemCount = 0
    private(set) var iconSize: CGFloat = 48
    private var preferredIconSize: CGFloat = 48
    private var preferredIconSpacing: CGFloat = 5.2
    private var maximumLayoutLength: CGFloat?
    private(set) var requiredWidth: CGFloat = 0
    private(set) var visualContentFrame: NSRect = .zero
    private(set) var restingVisualContentFrame: NSRect = .zero
    private var trackingArea: NSTrackingArea?
    private var pointerX: CGFloat?
    private var pointerPoint: NSPoint?
    private var isPointerInside = false
    private var hoveredButton: DockItemButton?
    private weak var contextMenuButton: DockItemButton?
    private var isContextMenuPresented = false
    private var isTrashDropTargeted = false
    private var onHover: ((DockItemButton, DockItem?) -> Void)?
    private var magnificationTransition = DockMagnificationTransition()
    private var displayLinkDriver: AnyObject?
    private var fallbackFrameTimer: Timer?
    private var previousAnimationTime: CFTimeInterval?
    private var isFrameClockRunning = false
    private var hasPendingPointerRender = false
    private var lastPointerRenderRequestTime: CFTimeInterval?
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
    private var isFileDragActive = false
    private var magnificationEnabled = true
    private var maximumMagnification: CGFloat = 1.18
    private(set) var iconSpacing: CGFloat = 5.2
    /// Radius in slot-widths over which the pointer influences neighboring
    /// icons. Keeping this separate from the scale makes the interaction
    /// tunable without changing the document layout.
    private var magnificationRange: CGFloat = 3.0
    private var previousBackgroundInteraction = DockBackgroundInteractionState.idle

    private(set) var visibleIconFrames: [NSRect] = []
    private var visualButtonHitTargets: [DockVisualButtonHitTarget] = []
    private var tooltipHoverFrames: [NSRect] = []
    private var tooltipHoverBounds: NSRect = .zero
    var dockBodyFrame: NSRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = false
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

    override func rightMouseDown(with event: NSEvent) {
        onBackgroundContextMenu?(event)
    }

    func visuallyHitButton(at point: NSPoint) -> DockItemButton? {
        if let index = DockVisualButtonHitResolver.buttonIndex(
            at: point,
            targets: visualButtonHitTargets
        ),
           orderedButtons.indices.contains(index) {
            let button = orderedButtons[index]
            if button.isEnabled,
               !button.isHidden,
               button.alphaValue > 0.000_1,
               button.superview === self {
                return button
            }
        }
        return nil
    }

    func setFileDragActive(_ active: Bool) {
        guard isFileDragActive != active else { return }
        isFileDragActive = active
        guard active else {
            isPointerInside = false
            pointerPoint = nil
            clearHoveredButton()
            setMagnificationTarget(0)
            return
        }

        isPointerInside = false
        pointerX = nil
        pointerPoint = nil
        clearHoveredButton()
        magnificationTransition.snap(to: 0)
        hasPendingPointerRender = false
        lastPointerRenderRequestTime = nil
        if !hasActivePresentationAnimation {
            stopMagnificationFrameClock()
        }
        updateMagnificationHeadroomActivity()
        renderMagnification()
    }

    func updateFileDragMagnification(at point: NSPoint) {
        guard isFileDragActive else { return }
        guard containsInteractivePoint(point) else {
            let wasActive = isPointerInside || magnificationTransition.target != 0
            isPointerInside = false
            pointerPoint = nil
            if wasActive {
                setMagnificationTarget(0)
            }
            return
        }

        let justEntered = !isPointerInside
        let pointChanged = DockPointerSamplePolicy.hasChanged(
            from: pointerPoint,
            to: point
        )
        isPointerInside = true
        pointerX = layoutPoint(point).x
        pointerPoint = point
        if justEntered {
            setMagnificationTarget(1)
        }
        if magnificationEnabled, pointChanged {
            requestMagnificationRender(.pointerChanged)
        } else {
            updateHoveredButton(at: point, reemitCurrent: false)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSeparatorAppearance()
    }

    deinit {
        animationClock?.stop()
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
        reconfigureExistingItems: Bool = true,
        launchBounceAnimationsEnabled: Bool = false,
        runningIndicatorsEnabled: Bool = true,
        maximumLayoutLength: CGFloat? = nil
    ) {
        visualButtonHitTargets.removeAll(keepingCapacity: true)
        let now = CACurrentMediaTime()
        let previousIdentities = Set(itemButtons.keys)
        let previousStateByIdentity = Dictionary(uniqueKeysWithValues: itemButtons.compactMap {
            identity, button in
            button.item.map { (identity, $0.transientState) }
        })
        let previousHadSeparator = !sectionSeparatorIndices(
            for: orderedButtons.compactMap(\.item)
        ).isEmpty
        self.onHover = onHover
        self.pinnedItemCount = pinnedItemCount
        self.preferredIconSize = iconSize
        self.maximumLayoutLength = maximumLayoutLength
        self.magnificationEnabled = magnificationEnabled
        self.maximumMagnification = min(1.80, max(1.0, magnificationScale))
        self.magnificationRange = min(3.50, max(1.25, magnificationRange))
        self.preferredIconSpacing = min(28, max(4, iconSpacing))
        let incomingByIdentity = Dictionary(uniqueKeysWithValues: items.map { ($0.identity, $0) })
        let incomingIdentities = Set(incomingByIdentity.keys)

        var presentationItems = items
        var presentedIdentities = Set(presentationItems.map(\.identity))
        let removableIdentities = Set(orderedButtons.compactMap { button -> ApplicationIdentity? in
            guard let previousItem = button.item,
                  !incomingIdentities.contains(previousItem.identity),
                  removingIdentities.contains(previousItem.identity)
                    || animatedRemovalIdentities.contains(previousItem.identity) else {
                return nil
            }
            return previousItem.identity
        })
        for (oldIndex, button) in orderedButtons.enumerated().reversed() {
            guard let previousItem = button.item,
                  removableIdentities.contains(previousItem.identity),
                  !presentedIdentities.contains(previousItem.identity) else { continue }
            presentationItems.insert(
                previousItem,
                at: min(oldIndex, presentationItems.count)
            )
            presentedIdentities.insert(previousItem.identity)
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
            if reconfigureExistingItems || button.item == nil {
                button.configure(
                    item: item,
                    iconSize: iconSize,
                    iconProvider: iconProvider,
                    showsRunningIndicator: runningIndicatorsEnabled
                )
            }
            button.isEnabled = item.kind != .dropPlaceholder
                && incomingIdentities.contains(item.identity)
            return button
        }

        for identity in incomingIdentities where removingIdentities.remove(identity) != nil {
            setPresenceTarget(1, for: identity, at: now)
        }

        let insertedItems = items.filter { item in
                animatedInsertionIdentities.contains(item.identity)
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
            for item in insertedItems {
                itemPresenceValues[item.identity] = 0
                itemPresenceTransitions[item.identity] = .insertion(
                    startTime: now,
                    profile: item.kind == .dropPlaceholder ? .dropPlaceholder : .standard
                )
            }
        }

        let presentationHasSeparator = !sectionSeparatorIndices(
            for: orderedButtons.compactMap(\.item)
        ).isEmpty
        let finalHasSeparator = !sectionSeparatorIndices(for: items).isEmpty
        updateSeparatorPresence(
            presentationHasSeparator: presentationHasSeparator,
            finalHasSeparator: finalHasSeparator,
            previousHadSeparator: previousHadSeparator,
            hasAnimatedInsertions: !insertedItems.isEmpty,
            hasAnimatedRemovals: !newlyRemovedIdentities.isEmpty,
            at: now
        )

        let launchBounceStartIdentities: Set<ApplicationIdentity> = {
            guard launchBounceAnimationsEnabled,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                return []
            }
            return Set(
                items
                    .filter { $0.transientState == .launching && !$0.isRunning }
                    .map(\.identity)
            )
        }()
        for item in items where launchBounceStartIdentities.contains(item.identity) {
            guard let previousState = previousStateByIdentity[item.identity],
                  previousState != .launching,
                  launchBounceTransitions[item.identity] == nil else { continue }
            launchBounceTransitions[item.identity] = DockLaunchBounceTransition(
                startTime: now
            )
            launchBounceOffsets[item.identity] = 0
        }
        if !launchBounceAnimationsEnabled {
            finishLaunchBounceAnimations(notify: false)
        }

        itemPresenceTransitions = itemPresenceTransitions.filter {
            presentedIdentities.contains($0.key)
        }
        itemPresenceValues = itemPresenceValues.filter {
            presentedIdentities.contains($0.key)
        }
        removingIdentities.formIntersection(presentedIdentities)
        // NSWorkspace reports an app as running shortly after launch begins.
        // That blocks a new bounce, but an already-started fixed sequence must
        // finish instead of being truncated by the next snapshot.
        let failedLaunchIdentities = Set(items.compactMap { item -> ApplicationIdentity? in
            guard case .failed = item.transientState else { return nil }
            return item.identity
        })
        launchBounceTransitions = launchBounceTransitions.filter {
            launchBounceAnimationsEnabled
                && presentedIdentities.contains($0.key)
                && !failedLaunchIdentities.contains($0.key)
        }
        let activeLaunchBounceIdentities = Set(launchBounceTransitions.keys)
        launchBounceOffsets = launchBounceOffsets.filter {
            activeLaunchBounceIdentities.contains($0.key)
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

    func moveDropPlaceholder(toShortcutIndex requestedIndex: Int) {
        guard let placeholderIndex = orderedButtons.firstIndex(where: {
            $0.item?.kind == .dropPlaceholder
        }) else { return }

        let currentShortcutIndex = orderedButtons[..<placeholderIndex].reduce(into: 0) {
            count, button in
            if case .fileShortcut? = button.item?.kind {
                count += 1
            }
        }
        let fileButtonCount = orderedButtons.reduce(into: 0) { count, button in
            if case .fileShortcut? = button.item?.kind {
                count += 1
            }
        }
        let targetShortcutIndex = min(max(0, requestedIndex), fileButtonCount)
        guard currentShortcutIndex != targetShortcutIndex else { return }

        let placeholderButton = orderedButtons.remove(at: placeholderIndex)
        let fileButtons = orderedButtons.filter { button in
            if case .fileShortcut? = button.item?.kind { return true }
            return false
        }
        let targetButton = targetShortcutIndex < fileButtons.count
            ? fileButtons[targetShortcutIndex]
            : orderedButtons.first(where: { $0.item?.kind == .trash })
        guard let targetButton,
              let insertionIndex = orderedButtons.firstIndex(where: { $0 === targetButton }) else {
            orderedButtons.insert(placeholderButton, at: min(placeholderIndex, orderedButtons.count))
            return
        }

        orderedButtons.insert(placeholderButton, at: insertionIndex)
        renderMagnification()
    }

    func dropDestination(
        at point: NSPoint,
        preservesTrashTarget: Bool = false,
        preservesShortcutTarget: Bool = false
    ) -> DockDropDestination? {
        let point = layoutPoint(point)
        guard point.x >= -8,
              point.x <= layoutSize.width + 8 else { return nil }
        guard let trashButton = orderedButtons.first(where: { $0.item?.kind == .trash }) else {
            return nil
        }

        // Trash and the shortcut section share a hard horizontal boundary.
        // Hover hysteresis may grow to the right, but never left into the
        // shortcut insertion slot.
        let trashIconFrame = layoutRect(trashButton.iconFrame(in: self))
        let trashSlotFrame = layoutRect(trashButton.visualSlotFrame(in: self))
        let trashRightPadding: CGFloat = preservesTrashTarget ? 8 : 4
        let trashEntryMaxX = max(trashIconFrame.maxX, trashSlotFrame.maxX)
            + trashRightPadding
        let trashEntryMinX = trashSlotFrame.minX
        if point.x >= trashEntryMinX, point.x <= trashEntryMaxX {
            return .trash
        }

        let fileButtons = orderedButtons.filter { button in
            guard let item = button.item else { return false }
            if case .fileShortcut = item.kind { return true }
            return false
        }

        let slotWidth = iconSize + iconSpacing
        let shortcutTargetWidth = preservesShortcutTarget
            ? slotWidth * 1.5 + 4
            : slotWidth
        let bootstrapStart = trashSlotFrame.minX - shortcutTargetWidth
        let fileSectionHysteresis = preservesShortcutTarget ? slotWidth / 2 + 4 : 0
        let existingFileSectionStart = fileButtons
            .map { layoutRect($0.visualSlotFrame(in: self)).minX }
            .min()
            .map {
                $0
                    - DockMagnificationLayout.separatorSpace / 2
                    - fileSectionHysteresis
            }
        let placeholderSectionStart = orderedButtons
            .first(where: { $0.item?.kind == .dropPlaceholder })
            .map { button in
                // During insertion the placeholder grows from zero width. Use
                // its projected full-width edge so a visible slot remains a
                // valid final drop target throughout the animation.
                let visualFrame = layoutRect(button.visualSlotFrame(in: self))
                return visualFrame.minX - max(0, slotWidth - visualFrame.width) / 2
            }
        let fileSectionStart = min(
            bootstrapStart,
            existingFileSectionStart ?? bootstrapStart,
            placeholderSectionStart ?? bootstrapStart
        )
        guard point.x >= fileSectionStart,
              point.x < trashSlotFrame.minX else {
            return nil
        }

        let insertionIndex = fileButtons.firstIndex { button in
            point.x < layoutRect(button.visualSlotFrame(in: self)).midX
        } ?? fileButtons.count
        return .shortcuts(index: insertionIndex)
    }

    func setTrashDropTargeted(_ targeted: Bool) {
        guard let button = orderedButtons.first(where: { $0.item?.kind == .trash }) else {
            isTrashDropTargeted = false
            return
        }
        let wasTargeted = isTrashDropTargeted
        isTrashDropTargeted = targeted
        button.setDropTargeted(targeted)
        if targeted, let item = button.item {
            onHover?(button, item)
        } else if wasTargeted {
            if hoveredButton === button {
                clearHoveredButton()
            } else {
                onHover?(button, nil)
            }
        }
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
        // AppKit may deliver an exit generated by button tracking only after
        // mouseUp. Validate the current global pointer instead of trusting that
        // delayed event; a pointer still over the Dock must remain magnified.
        if let currentPoint = currentGlobalPointerPoint(),
           containsInteractivePoint(currentPoint) {
            handlePointer(
                at: currentPoint,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
            return
        }
        // NSButton's synchronous press tracking can emit a temporary exit even
        // while the pointer remains over the Dock. Dragged events still flow
        // through coordinate reconciliation and handle a real departure.
        guard DockPointerExitPolicy.shouldCancelInteraction(
            pressedMouseButtons: NSEvent.pressedMouseButtons
        ) else { return }
        guard acceptPointerSample(timestamp: event.timestamp) else { return }
        cancelPointerInteraction()
    }

    private func isCurrentTrackingEvent(_ event: NSEvent) -> Bool {
        guard DockTrackingAreaEventPolicy.carriesTrackingArea(event.type) else {
            return true
        }
        guard let eventTrackingArea = event.trackingArea else { return true }
        return eventTrackingArea === trackingArea
    }

    private func currentGlobalPointerPoint() -> NSPoint? {
        guard let window, window.isVisible else { return nil }
        let location = screenLocationNormalizer?(NSEvent.mouseLocation) ?? NSEvent.mouseLocation
        let pointInWindow = window.convertPoint(fromScreen: location)
        return convert(pointInWindow, from: nil)
    }

    private func handlePointerEvent(_ event: NSEvent) {
        guard let window else { return }
        let screenLocation = window.convertPoint(toScreen: event.locationInWindow)
        let location = screenLocationNormalizer?(screenLocation) ?? screenLocation
        let point = convert(window.convertPoint(fromScreen: location), from: nil)
        handlePointer(at: point, timestamp: event.timestamp)
    }

    private func handlePointer(at point: NSPoint, timestamp: TimeInterval) {
        guard !isFileDragActive else { return }
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
        pointerX = layoutPoint(point).x
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
        if isFileDragActive {
            return
        }
        handlePointerEvent(event)
    }

    /// Periodic samples also recover an entry when AppKit omits mouseEntered
    /// or mouseMoved, which can happen during an extremely slow side entry.
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
        pointerX = layoutPoint(point).x
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
        hasPendingPointerRender = false
        lastPointerRenderRequestTime = nil
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
        if case .pointerChanged = request {
            hasPendingPointerRender = true
            lastPointerRenderRequestTime = CACurrentMediaTime()
        }
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
        if let animationClock {
            animationClock.start(framesPerSecond: animationFramesPerSecond) { [weak self] in
                self?.advanceMagnificationFrame()
            }
            return
        }
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
        animationClock?.stop()
        if #available(macOS 14.0, *),
           let driver = displayLinkDriver as? DockMagnificationDisplayLinkDriver {
            driver.pause()
        }
        fallbackFrameTimer?.invalidate()
        fallbackFrameTimer = nil
        previousAnimationTime = nil
    }

    func advanceMagnificationFrame() {
        let hasMagnificationAnimation = !magnificationTransition.isSettled
        let hasPresentationAnimation = hasActivePresentationAnimation
        let now = CACurrentMediaTime()
        let keepsFrameClockWarm = DockMagnificationFrameClockPolicy.keepsClockWarm(
            isPointerInside: isPointerInside,
            lastPointerRequestTime: lastPointerRenderRequestTime,
            now: now
        )
        guard hasMagnificationAnimation
                || hasPresentationAnimation
                || hasPendingPointerRender
                || keepsFrameClockWarm else {
            stopMagnificationFrameClock()
            return
        }

        // Keep one shared timeline warm even while insertion is the only active
        // animation. A hover that starts mid-insertion must advance by one
        // display frame, not by the whole time since magnification last moved.
        advanceMagnificationTransition(to: now)
        guard hasMagnificationAnimation
                || hasPresentationAnimation
                || hasPendingPointerRender else {
            return
        }
        var requiredWidthChanged = false
        if !itemPresenceTransitions.isEmpty || separatorPresenceTransition != nil {
            requiredWidthChanged = advancePresenceAnimations(to: now)
        }
        if !launchBounceTransitions.isEmpty {
            advanceLaunchBounceAnimations(to: now)
        }
        hasPendingPointerRender = false
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
           !hasActivePresentationAnimation,
           !hasPendingPointerRender,
           !DockMagnificationFrameClockPolicy.keepsClockWarm(
                isPointerInside: isPointerInside,
                lastPointerRequestTime: lastPointerRenderRequestTime,
                now: now
           ) {
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
            startTime: time,
            profile: itemButtons[identity]?.item?.kind == .dropPlaceholder
                ? .dropPlaceholder
                : .standard
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
        visualButtonHitTargets.removeAll(keepingCapacity: true)
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
        let separatorIndices = sectionSeparatorIndices(
            for: orderedButtons.compactMap(\.item)
        )
        let metrics = DockMagnificationLayout.fittingIconMetrics(
            itemCount: orderedButtons.count,
            pinnedItemCount: pinnedItemCount,
            separatorIndices: separatorIndices,
            preferredIconSize: preferredIconSize,
            preferredSpacing: preferredIconSpacing,
            maximumLength: maximumLayoutLength,
            maximumScale: magnificationEnabled ? maximumMagnification : 1,
            influenceRange: magnificationRange
        )
        let metricsChanged = abs(iconSize - metrics.iconSize) > 0.0001
            || abs(iconSpacing - metrics.spacing) > 0.0001
        iconSize = metrics.iconSize
        iconSpacing = metrics.spacing
        orderedButtons.forEach { $0.setIconSize(iconSize) }
        let newValue = DockMagnificationLayout.maximumRequiredWidth(
            itemCount: orderedButtons.count,
            pinnedItemCount: pinnedItemCount,
            separatorIndices: separatorIndices,
            iconSize: iconSize,
            spacing: iconSpacing,
            maximumScale: magnificationEnabled ? maximumMagnification : 1,
            influenceRange: magnificationRange
        )
        let changed = abs(newValue - requiredWidth) > 0.01
        requiredWidth = newValue
        return changed || metricsChanged
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
        let point = layoutPoint(point)
        let canonicalBounds = NSRect(origin: .zero, size: layoutSize)
        let visualContentFrame = layoutRect(self.visualContentFrame)
        let minimumX = max(
            canonicalBounds.minX,
            visualContentFrame.minX - DockInteractiveRegion.backgroundHorizontalPadding
        )
        let maximumX = min(
            canonicalBounds.maxX,
            visualContentFrame.maxX + DockInteractiveRegion.backgroundHorizontalPadding
        )
        let verticalBodyFrame = dockBodyFrame.map(layoutRect) ?? NSRect(
            x: canonicalBounds.minX,
            y: canonicalBounds.minY,
            width: canonicalBounds.width,
            height: min(canonicalBounds.height, iconSize + 20)
        )
        let bodyFrame = NSRect(
            x: minimumX,
            y: verticalBodyFrame.minY,
            width: max(0, maximumX - minimumX),
            height: verticalBodyFrame.height
        )
        return DockInteractiveRegion.contains(
            point,
            bodyFrame: bodyFrame,
            iconFrames: visibleIconFrames.map(layoutRect)
        )
    }

    private func renderMagnification() {
        guard !isRenderingMagnification else { return }
        isRenderingMagnification = true
        defer { isRenderingMagnification = false }
        let ownsLayerTransaction = !CATransaction.disableActions()
        if ownsLayerTransaction {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        defer {
            if ownsLayerTransaction {
                CATransaction.commit()
            }
        }

        let presenceValues = orderedButtons.map { button in
            button.item.flatMap { itemPresenceValues[$0.identity] } ?? 1
        }
        let separatorIndices = sectionSeparatorIndices(
            for: orderedButtons.compactMap(\.item)
        )
        let hasSeparator = !separatorIndices.isEmpty
        let presentedRequiredWidth = DockMagnificationLayout.presentedRequiredWidth(
            itemPresenceProgresses: presenceValues,
            hasSeparator: hasSeparator,
            separatorCount: separatorIndices.count,
            separatorPresenceProgress: separatorPresence,
            iconSize: iconSize,
            spacing: iconSpacing,
            maximumScale: magnificationEnabled ? maximumMagnification : 1,
            influenceRange: magnificationRange
        )
        let initialHorizontalOffset = DockInsertionHorizontalAlignment.offset(
            presentedRequiredWidth: presentedRequiredWidth,
            finalDocumentWidth: layoutSize.width,
            finalViewportWidth: enclosingScrollView.map { position.layoutSize(for: $0.contentSize).width } ?? layoutSize.width
        )
        let layout = DockMagnificationLayout.make(
            itemCount: orderedButtons.count,
            pinnedItemCount: pinnedItemCount,
            separatorIndices: separatorIndices,
            iconSize: iconSize,
            spacing: iconSpacing,
            maximumScale: magnificationEnabled ? maximumMagnification : 1,
            influenceRange: magnificationRange,
            containerWidth: layoutSize.width,
            height: layoutSize.height,
            pointerX: magnificationEnabled
                ? pointerX.map { $0 - initialHorizontalOffset }
                : nil,
            magnificationProgress: magnificationTransition.value,
            itemPresenceProgresses: presenceValues,
            separatorPresenceProgress: separatorPresence
        )
        let horizontalOffset = initialHorizontalOffset

        visibleIconFrames.removeAll(keepingCapacity: true)
        visualButtonHitTargets.removeAll(keepingCapacity: true)
        var tooltipSlotFrames = Array<NSRect?>(
            repeating: nil,
            count: orderedButtons.count
        )
        for index in orderedButtons.indices {
            let button = orderedButtons[index]
            let baseFrame = layout.baseButtonFrames[index].offsetBy(
                dx: horizontalOffset,
                dy: 0
            )
            let visualFrame = layout.buttonFrames[index].offsetBy(
                dx: horizontalOffset,
                dy: 0
            )
            let geometry = DockButtonPresentationGeometry.make(
                baseFrame: baseFrame,
                visualFrame: visualFrame
            )
            // AppKit owns a stable, non-magnified control frame. Only the
            // button's private layers follow the live visual slot, avoiding a
            // layout pass for every icon on every display-link callback.
            if !NSEqualRects(button.frame, viewRect(geometry.viewFrame)) {
                button.frame = viewRect(geometry.viewFrame)
            }
            let identity = button.item?.identity
            button.setPresentation(
                magnification: layout.scales[index],
                presenceProgress: presenceValues[index],
                launchBounceOffset: identity.flatMap { launchBounceOffsets[$0] } ?? 0,
                visualSlotCenterOffsetX: geometry.visualSlotCenterOffsetX,
                visualSlotWidth: geometry.visualSlotFrame.width,
                position: position
            )
            let iconFrame = button.iconFrame(in: self)
            let excludesTooltip = identity.map(removingIdentities.contains) ?? false
                || orderedButtons[index].item?.kind == .dropPlaceholder
            if !excludesTooltip {
                visibleIconFrames.append(iconFrame)
                visualButtonHitTargets.append(DockVisualButtonHitTarget(
                    buttonIndex: index,
                    frame: iconFrame,
                    zPosition: layout.scales[index]
                ))
                tooltipSlotFrames[index] = geometry.visualSlotFrame
            }
        }
        tooltipHoverBounds = dockBodyFrame.map { bounds.union($0) } ?? bounds
        tooltipHoverFrames = DockHoverResolver.hoverFrames(
            slotFrames: tooltipSlotFrames,
            in: layoutRect(tooltipHoverBounds)
        ).map(viewRect)
        updateHoveredButton(at: pointerPoint)

        ensureSeparatorViewCount(layout.separatorFrames.count)
        for (index, separatorFrame) in layout.separatorFrames.enumerated() {
            let scale = window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
            let separatorView = separatorViews[index]
            let targetFrame = DockMagnificationLayout.pixelAlignedSeparatorFrame(
                separatorFrame.offsetBy(dx: horizontalOffset, dy: 0),
                backingScaleFactor: scale
            )
            if !NSEqualRects(separatorView.frame, viewRect(targetFrame)) {
                separatorView.frame = viewRect(targetFrame)
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
        }
        for separatorView in separatorViews.dropFirst(layout.separatorFrames.count) {
            separatorView.isHidden = true
        }

        visualContentFrame = viewRect(layout.visualContentFrame.offsetBy(dx: horizontalOffset, dy: 0))
        restingVisualContentFrame = viewRect(layout.restingVisualContentFrame.offsetBy(dx: horizontalOffset, dy: 0))
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
                in: tooltipHoverBounds,
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
        guard let point = currentGlobalPointerPoint() else {
            cancelPointerInteraction()
            return
        }
        if containsInteractivePoint(point) {
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
        for separatorView in separatorViews {
            separatorView.layer?.backgroundColor = NSColor.separatorColor
                .withAlphaComponent(0.72)
                .cgColor
        }
    }

    private func ensureSeparatorViewCount(_ count: Int) {
        while separatorViews.count < count {
            let view = NSView()
            view.wantsLayer = true
            separatorViews.append(view)
            addSubview(view)
            updateSeparatorAppearance()
        }
    }

    private func sectionSeparatorIndices(for items: [DockItem]) -> Set<Int> {
        guard items.count > 1 else { return [] }
        return Set(items.indices.dropFirst().filter { index in
            items[index - 1].section != items[index].section
        })
    }
}
