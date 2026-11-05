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
    var onFileDragActivityChange: ((Bool) -> Void)?
    var onDropRequest: ((DockDropRequest) -> Bool)?
    var fileDragRegionProvider: (() -> DockFileDragRegion?)?
    var screenLocationNormalizer: ((NSPoint) -> NSPoint)?
    var fileUndoAction: FileUndoMenuAction = .unavailable

    private let backgroundView = DockBackgroundSurfaceView()
    private let scrollView = HorizontalDockScrollView()
    private let stripView = DockStripView()
    private let iconProvider: ApplicationIconProvider
    private var position: DockPosition = .bottom
    private var layoutPosition: DockPosition { position.contentPosition }
    private var layoutSize: NSSize { position.layoutSize(for: bounds.size) }

    private(set) var dockBodyHeight: CGFloat = 72
    private(set) var preferredWidth: CGFloat = 160
    private(set) var preferredHeight: CGFloat = 72
    private var iconSize: CGFloat = 48
    private var preferredIconSize: CGFloat = 48
    private var preferredIconSpacing: CGFloat = 5.2
    private var maxWidth: CGFloat = 800
    private var backgroundTransparency: CGFloat = 0.17
    private var backgroundBlur: CGFloat = DockBackgroundBlur.defaultValue
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
    private var backgroundBodyFrame: NSRect = .zero
    private var snapshot: DockSnapshot = .empty
    private var dropDestination: DockDropDestination?
    private var dropPlaceholderShortcutIndex: Int?
    private var cachedDraggingPayload: DraggingPayload?
    private var preparedDraggingPayload: DraggingPayload?
    private var preparedDropDestination: DockDropDestination?
    private var activeDraggingSequenceNumber: Int?
    private var dragExitRevision: UInt = 0
    private var draggedShortcutIDs = Set<UUID>()
    private var isDraggedShortcutRemovedFromPresentation = false
    private var pendingShortcutDropHandoff: ShortcutDropHandoff?
    private var pendingShortcutRemovalHandoff: ShortcutRemovalHandoff?
    private var isFileDragActive = false
    private var fileDragLockedSize: NSSize?
    private var launchBounceAnimationsEnabled = false
    private var runningIndicatorsEnabled = true

    init(iconProvider: ApplicationIconProvider = .shared, animationClock: DockAnimationClock? = nil) {
        self.iconProvider = iconProvider

        super.init(frame: .zero)
        stripView.animationClock = animationClock
        wantsLayer = true
        clipsToBounds = false
        stripView.screenLocationNormalizer = { [weak self] point in
            self?.screenLocationNormalizer?(point) ?? point
        }

        backgroundView.configure(
            transparency: backgroundTransparency,
            blurStrength: backgroundBlur,
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
        scrollView.onBackgroundContextMenu = { [weak self] event in
            self?.presentBackgroundContextMenu(for: event)
        }
        stripView.onBackgroundContextMenu = { [weak self] event in
            self?.presentBackgroundContextMenu(for: event)
        }
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
        backgroundView.hostContent(
            scrollView,
            interactionRoot: scrollView
        ) { [weak scrollView, weak stripView] pointInScrollView in
            guard let scrollView, let stripView else { return nil }
            let pointInStrip = stripView.convert(
                pointInScrollView,
                from: scrollView
            )
            return stripView.visuallyHitButton(at: pointInStrip)
        }

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
        backgroundBlur: CGFloat = DockBackgroundBlur.defaultValue,
        backgroundStyle: DockBackgroundStyle = .liquidGlass,
        magnificationEnabled: Bool = true,
        magnificationScale: CGFloat = 1.18,
        magnificationRange: CGFloat = 3.0,
        iconSpacing: CGFloat = 5.2,
        tooltipGap: CGFloat = 4,
        animatedInsertionIdentities: Set<ApplicationIdentity> = [],
        animatedRemovalIdentities: Set<ApplicationIdentity> = [],
        launchBounceAnimationsEnabled: Bool = false,
        runningIndicatorsEnabled: Bool = true,
        position: DockPosition = .bottom
    ) {
        if self.position != position { cancelFileDrag() }
        self.position = position
        stripView.position = position
        scrollView.position = position
        var effectiveAnimatedRemovalIdentities = animatedRemovalIdentities
        let wasLaunchBounceActive = isLaunchBounceActive
        self.preferredIconSize = iconSize
        self.maxWidth = max(160, maxWidth)
        self.backgroundTransparency = DockBackgroundTransparency.clamped(backgroundTransparency)
        self.backgroundBlur = DockBackgroundBlur.clamped(backgroundBlur)
        self.backgroundStyle = backgroundStyle
        self.magnificationEnabled = magnificationEnabled
        self.magnificationScale = magnificationEnabled
            ? min(1.80, max(1.0, magnificationScale))
            : 1.0
        self.magnificationRange = min(3.50, max(1.25, magnificationRange))
        self.preferredIconSpacing = min(28, max(4, iconSpacing))
        self.tooltipGap = min(24, max(0, tooltipGap))
        if let handoff = pendingShortcutDropHandoff {
            let incomingShortcutIDs = snapshot.items.compactMap(\.kind.shortcutID)
            if snapshot.revision > handoff.baselineRevision,
               incomingShortcutIDs != handoff.baselineShortcutIDs {
                pendingShortcutDropHandoff = nil
                dropPlaceholderShortcutIndex = nil
                draggedShortcutIDs.removeAll()
                isDraggedShortcutRemovedFromPresentation = false
            }
        }
        if let handoff = pendingShortcutRemovalHandoff {
            let incomingShortcutIDs = Set(snapshot.items.compactMap(\.kind.shortcutID))
            if snapshot.revision > handoff.baselineRevision,
               incomingShortcutIDs.isDisjoint(with: handoff.shortcutIDs) {
                pendingShortcutRemovalHandoff = nil
                if dropPlaceholderShortcutIndex != nil {
                    effectiveAnimatedRemovalIdentities.insert(
                        Self.dropPlaceholderItem.identity
                    )
                }
                dropPlaceholderShortcutIndex = nil
                draggedShortcutIDs.removeAll()
                isDraggedShortcutRemovedFromPresentation = false
            }
        }
        self.snapshot = snapshot
        self.launchBounceAnimationsEnabled = launchBounceAnimationsEnabled
        self.runningIndicatorsEnabled = runningIndicatorsEnabled
        if !self.magnificationEnabled {
            isMagnificationHeadroomActive = false
        }

        applyStrip(
            animatedInsertionIdentities: animatedInsertionIdentities,
            animatedRemovalIdentities: effectiveAnimatedRemovalIdentities
        )

        isLaunchBounceActive = stripView.isLaunchBounceAnimationActive
        preferredWidth = targetPreferredWidth
        preferredHeight = targetPreferredHeight
        frame.size = fileDragLockedSize
            ?? position.layoutSize(for: NSSize(width: preferredWidth, height: preferredHeight))
        needsLayout = true
        layoutSubtreeIfNeeded()
        if isLaunchBounceActive != wasLaunchBounceActive {
            onLaunchBounceActivityChange?(isLaunchBounceActive)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return beginFileDrag(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateFileDrag(sender)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        false
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        scheduleFileDragExit(for: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragExitRevision &+= 1
        preparedDraggingPayload = nil
        preparedDropDestination = nil
        guard let destination = dropDestination else {
            return false
        }
        let finalPayload = mergedDraggingPayload(
            preferred: draggingPayload(from: sender),
            fallback: cachedDraggingPayload
        )
        cachedDraggingPayload = finalPayload
        guard finalPayload != nil else { return false }
        let acceptsDrop = dragOperation(
            for: destination,
            sourceMask: sender.draggingSourceOperationMask
        ) != []
        guard acceptsDrop else {
            setDropDestination(nil)
            return false
        }
        preparedDraggingPayload = finalPayload
        preparedDropDestination = destination
        setDropDestination(destination)
        return acceptsDrop
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = preparedDraggingPayload,
              let destination = preparedDropDestination,
              let onDropRequest else {
            clearFileDrag()
            return false
        }
        let request = DockDropRequest(
            fileURLs: payload.fileURLs,
            sourceShortcutIDs: payload.sourceShortcutIDs,
            destination: requestDestination(
                destination,
                sourceShortcutIDs: payload.sourceShortcutIDs
            )
        )
        if case .shortcuts = request.destination {
            pendingShortcutDropHandoff = ShortcutDropHandoff(
                baselineRevision: snapshot.revision,
                baselineShortcutIDs: snapshot.items.compactMap(\.kind.shortcutID)
            )
        } else if case .trash = request.destination,
                  !payload.sourceShortcutIDs.isEmpty {
            pendingShortcutRemovalHandoff = ShortcutRemovalHandoff(
                baselineRevision: snapshot.revision,
                shortcutIDs: Set(payload.sourceShortcutIDs)
            )
        }
        let accepted = onDropRequest(request)
        if !accepted {
            pendingShortcutDropHandoff = nil
            pendingShortcutRemovalHandoff = nil
        }
        clearFileDrag()
        return accepted
    }

    override func rightMouseDown(with event: NSEvent) {
        presentBackgroundContextMenu(for: event)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        clearFileDrag()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearFileDrag()
    }

    override func layout() {
        super.layout()
        if !NSEqualRects(backgroundView.frame, bounds) {
            backgroundView.frame = bounds
        }
        let activeHeadroom = min(
            maximumActiveHeadroom,
            max(0, layoutSize.height - dockBodyHeight)
        )
        let stripHeight = max(0, dockBodyHeight - 8 + activeHeadroom)
        backgroundView.setHostedContentFrame(layoutPosition.viewRect(NSRect(
            x: 10,
            y: 4,
            width: max(0, layoutSize.width - 20),
            height: stripHeight
        ), in: layoutSize))
        stripView.frame = NSRect(
            x: 0,
            y: 0,
            width: position.isVertical ? stripHeight : max(stripView.requiredWidth, scrollView.contentSize.width),
            height: position.isVertical ? max(stripView.requiredWidth, scrollView.contentSize.height) : stripHeight
        )
        let dockBodyFrame = layoutPosition.viewRect(NSRect(
            x: 0,
            y: 0,
            width: layoutSize.width,
            height: min(dockBodyHeight, layoutSize.height)
        ), in: layoutSize)
        stripView.dockBodyFrame = convert(dockBodyFrame, to: stripView)
        stripView.needsLayout = true
        stripView.layoutSubtreeIfNeeded()
        updateBackgroundFrame()
    }

    var restingDockBodyFrame: NSRect {
        resolvedBackgroundBodyFrame(
            for: stripView.restingVisualContentFrame
        )
    }

    var currentDockVisualFrame: NSRect {
        var visualFrame = backgroundBodyFrame
        for iconFrame in stripView.visibleIconFrames {
            let convertedIconFrame = stripView.convert(iconFrame, to: self)
            visualFrame = visualFrame.width > 0 && visualFrame.height > 0
                ? visualFrame.union(convertedIconFrame)
                : convertedIconFrame
        }
        return visualFrame
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

    func cancelFileDrag() {
        clearFileDrag()
    }

    /// Reconciles AppKit tracking with the monitor's current global pointer.
    /// Window moves and tracking-area replacement do not always deliver a
    /// final mouseExited event, so this keeps a stale label from surviving.
    func reconcilePointer(
        screenLocation: NSPoint,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        allowsSyntheticEntry: Bool = false
    ) {
        guard !isFileDragActive else { return }
        guard let window, window.isVisible else {
            stripView.cancelPointerInteraction()
            onTooltipPresentation?(nil)
            return
        }

        let location = screenLocationNormalizer?(screenLocation) ?? screenLocation
        let pointInWindow = window.convertPoint(fromScreen: location)
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
        let location = screenLocationNormalizer?(screenLocation) ?? screenLocation
        let pointInWindow = window.convertPoint(fromScreen: location)
        let pointInContent = convert(pointInWindow, from: nil)
        let bodyFrame = backgroundBodyFrame
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
        if item.kind == .trash,
           isFileDragActive,
           dropDestination == .trash,
           !draggedShortcutIDs.isEmpty {
            text = L10n.text("dock.drop.removeFromEchoDock")
        } else if case let .failed(message) = item.transientState {
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
                backingScaleFactor: screen?.backingScaleFactor ?? window.backingScaleFactor,
                position: position
            )
        )
    }

    private func applyStrip(
        animatedInsertionIdentities: Set<ApplicationIdentity> = [],
        animatedRemovalIdentities: Set<ApplicationIdentity> = [],
        reconfigureExistingItems: Bool = true
    ) {
        var items = snapshot.items
        let insertionIdentities = animatedInsertionIdentities
        if !draggedShortcutIDs.isEmpty,
           dropPlaceholderShortcutIndex != nil {
            items.removeAll { item in
                guard let shortcutID = item.kind.shortcutID else { return false }
                return draggedShortcutIDs.contains(shortcutID)
            }
        }
        if let index = dropPlaceholderShortcutIndex,
           let trashIndex = items.firstIndex(where: { $0.kind == .trash }) {
            let shortcutIDs = snapshot.items.compactMap { $0.kind.shortcutID }
            let requestedIndex = min(max(0, index), shortcutIDs.count)
            let sourceCountBeforeTarget = isDraggedShortcutRemovedFromPresentation
                ? 0
                : shortcutIDs
                    .prefix(requestedIndex)
                    .filter { draggedShortcutIDs.contains($0) }
                    .count
            let visibleIndex = max(0, requestedIndex - sourceCountBeforeTarget)
            let shortcutStart = items.firstIndex(where: {
                if case .fileShortcut = $0.kind { return true }
                return false
            }) ?? trashIndex
            let shortcutCount = items.filter {
                if case .fileShortcut = $0.kind { return true }
                return false
            }.count
            let insertionIndex = min(
                shortcutStart + min(visibleIndex, shortcutCount),
                trashIndex
            )
            items.insert(Self.dropPlaceholderItem, at: insertionIndex)
        }

        stripView.apply(
            items: items,
            pinnedItemCount: snapshot.pinnedItemCount,
            iconSize: preferredIconSize,
            iconProvider: iconProvider,
            onAction: { [weak self] item in self?.onItemAction?(item) },
            onContextAction: { [weak self] item, action in
                self?.onItemContextAction?(item, action)
            },
            contextMenuStateProvider: { [weak self] item in
                self?.onItemContextMenuStateRequest?(item) ?? .unavailable
            },
            onContextMenuPresentationChange: { [weak self] presented in
                if presented { self?.onTooltipPresentation?(nil) }
                self?.onContextMenuPresentationChange?(presented)
            },
            onHover: { [weak self] button, item in
                self?.updateTooltip(button: button, item: item)
            },
            magnificationEnabled: magnificationEnabled,
            magnificationScale: magnificationScale,
            magnificationRange: magnificationRange,
            iconSpacing: preferredIconSpacing,
            animatedInsertionIdentities: insertionIdentities,
            animatedRemovalIdentities: animatedRemovalIdentities,
            reconfigureExistingItems: reconfigureExistingItems,
            launchBounceAnimationsEnabled: launchBounceAnimationsEnabled,
            runningIndicatorsEnabled: runningIndicatorsEnabled,
            maximumLayoutLength: position.isVertical ? maxWidth - 20 : nil
        )
        updateIconMetricsFromStrip()
    }

    private func updateIconMetricsFromStrip() {
        iconSize = stripView.iconSize
        iconSpacing = stripView.iconSpacing
        dockBodyHeight = iconSize + 24
        updateBackgroundCornerRadius()
        let baseStripHeight = max(0, dockBodyHeight - 8)
        let requiredStripHeight = 8 + iconSize * magnificationScale + 4
        maximumMagnificationHeadroom = max(0, requiredStripHeight - baseStripHeight)
        maximumLaunchBounceHeadroom = iconSize * DockLaunchBounceTransition.maximumAmplitudeScale
    }

    private func beginFileDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        return updateFileDrag(sender)
    }

    private func updateFileDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragExitRevision &+= 1
        preparedDraggingPayload = nil
        preparedDropDestination = nil
        guard let payload = payload(for: sender) else {
            clearFileDrag()
            return []
        }
        let sourceWindow = sender.draggingDestinationWindow ?? window
        let sampledScreenLocation = sourceWindow?.convertPoint(toScreen: sender.draggingLocation)
        setFileDragActive(true)
        let sourceShortcutIDs = Set(payload.sourceShortcutIDs)
        if sourceShortcutIDs != draggedShortcutIDs {
            draggedShortcutIDs = sourceShortcutIDs
            if case .shortcuts = dropDestination {
                applyStrip()
                stripView.layoutSubtreeIfNeeded()
            }
        }
        let pointInStrip = fileDragLocationInStrip(for: sender, sampledScreenLocation: sampledScreenLocation)
        let destination = resolvedDropDestination(at: pointInStrip)
        let operation = dragOperation(
            for: destination,
            sourceMask: sender.draggingSourceOperationMask
        )
        let acceptedDestination = operation == [] ? nil : destination
        setDropDestination(acceptedDestination)
        stripView.updateFileDragMagnification(at: pointInStrip)
        return operation
    }

    private func presentBackgroundContextMenu(for event: NSEvent) {
        let menu = NSMenu(title: "EchoDock")
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) {
            menu.automaticallyInsertsWritingToolsItems = false
        }

        menu.addItem(fileUndoAction.makeMenuItem(target: self, action: #selector(undoFileOperation)))
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: L10n.text("statusItem.settings"),
            action: #selector(openSettingsFromContextMenu),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        settingsItem.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: settingsItem.title
        )
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(
            title: L10n.text("statusItem.about"),
            action: #selector(showAboutFromContextMenu),
            keyEquivalent: ""
        )
        aboutItem.target = self
        aboutItem.image = NSImage(
            systemSymbolName: "info.circle",
            accessibilityDescription: aboutItem.title
        )
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.text("statusItem.quit"),
            action: #selector(quitFromContextMenu),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        quitItem.image = NSImage(
            systemSymbolName: "power",
            accessibilityDescription: quitItem.title
        )
        menu.addItem(quitItem)

        guard let window else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let body = window.convertToScreen(convert(backgroundBodyFrame, to: nil))
        let anchor = position.isVertical
            ? NSRect(x: body.minX, y: pointer.y, width: body.width, height: 0)
            : NSRect(x: pointer.x, y: body.minY, width: 0, height: body.height)
        let positionedEvent = DockContextMenuPlacement.positionedEvent(
            for: menu,
            sourceEvent: event,
            in: self,
            anchorScreenFrame: anchor,
            position: position
        )
        onContextMenuPresentationChange?(true)
        onTooltipPresentation?(nil)
        defer { onContextMenuPresentationChange?(false) }
        NSMenu.popUpContextMenu(menu, with: positionedEvent, for: self)
    }

    @objc private func undoFileOperation() {
        fileUndoAction.perform()
    }

    @objc private func openSettingsFromContextMenu() {
        NotificationCenter.default.post(
            name: .echoDockOpenSettingsRequest,
            object: self
        )
    }

    @objc private func showAboutFromContextMenu() {
        NotificationCenter.default.post(
            name: .echoDockShowAboutRequest,
            object: self
        )
    }

    @objc private func quitFromContextMenu() {
        NotificationCenter.default.post(
            name: .echoDockQuitRequest,
            object: self
        )
    }

    private func setDropDestination(_ destination: DockDropDestination?) {
        dropDestination = destination
        stripView.setTrashDropTargeted(destination == .trash)

        switch destination {
        case .trash:
            // Keep an existing shortcut placeholder alive while Trash is
            // targeted. Removing it would recenter the panel and move Trash
            // away from the stationary pointer.
            return

        case nil:
            removeDropPlaceholder()
            return

        case let .shortcuts(index):
            if dropPlaceholderShortcutIndex != nil {
                dropPlaceholderShortcutIndex = index
                stripView.moveDropPlaceholder(toShortcutIndex: index)
                return
            }

            dropPlaceholderShortcutIndex = index
            let insertionIdentities: Set<ApplicationIdentity> = draggedShortcutIDs.isEmpty
                ? [Self.dropPlaceholderItem.identity]
                : []
            applyStrip(
                animatedInsertionIdentities: insertionIdentities,
                reconfigureExistingItems: false
            )
            isDraggedShortcutRemovedFromPresentation = !draggedShortcutIDs.isEmpty
            synchronizePreferredGeometry()
        }
    }

    private func removeDropPlaceholder(animated: Bool = true) {
        guard dropPlaceholderShortcutIndex != nil else { return }
        dropPlaceholderShortcutIndex = nil
        isDraggedShortcutRemovedFromPresentation = false
        let shouldAnimateRemoval = animated && draggedShortcutIDs.isEmpty
        applyStrip(
            animatedRemovalIdentities: shouldAnimateRemoval
                ? [Self.dropPlaceholderItem.identity]
                : [],
            reconfigureExistingItems: false
        )
        synchronizePreferredGeometry()
    }

    private func clearFileDrag() {
        dragExitRevision &+= 1
        activeDraggingSequenceNumber = nil
        cachedDraggingPayload = nil
        preparedDraggingPayload = nil
        preparedDropDestination = nil
        let preservesCommittedPlaceholder = pendingShortcutDropHandoff != nil
            || pendingShortcutRemovalHandoff != nil
        let shouldPreserveCommittedPlaceholder = preservesCommittedPlaceholder
            && dropPlaceholderShortcutIndex != nil
        if !shouldPreserveCommittedPlaceholder {
            removeDropPlaceholder()
            draggedShortcutIDs.removeAll()
            isDraggedShortcutRemovedFromPresentation = false
        }
        setFileDragActive(false)
        dropDestination = nil
        stripView.setTrashDropTargeted(false)
    }

    private func setFileDragActive(_ active: Bool) {
        guard isFileDragActive != active else { return }
        isFileDragActive = active
        stripView.setFileDragActive(active)

        if active {
            let currentWidth = max(layoutSize.width, max(preferredWidth, targetPreferredWidth))
            let reservedWidth = min(maxWidth, currentWidth + iconSize + iconSpacing)
            let lockedSize = position.layoutSize(for: NSSize(
                width: reservedWidth,
                height: max(
                    layoutSize.height,
                    preferredHeight,
                    dockBodyHeight + maximumMagnificationHeadroom
                )
            ))
            fileDragLockedSize = lockedSize
            frame.size = lockedSize
        } else {
            fileDragLockedSize = nil
            preferredWidth = targetPreferredWidth
            preferredHeight = targetPreferredHeight
            frame.size = position.layoutSize(for: NSSize(width: preferredWidth, height: preferredHeight))
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        onFileDragActivityChange?(active)
        if active {
            onTooltipPresentation?(nil)
        }
    }

    private func synchronizePreferredGeometry() {
        let targetWidth = targetPreferredWidth
        let targetHeight = targetPreferredHeight
        let changed = abs(targetWidth - preferredWidth) > 0.01
            || abs(targetHeight - preferredHeight) > 0.01
        preferredWidth = targetWidth
        preferredHeight = targetHeight
        guard !isFileDragActive else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }
        frame.size = position.layoutSize(for: NSSize(width: targetWidth, height: targetHeight))
        needsLayout = true
        layoutSubtreeIfNeeded()
        if changed {
            onPreferredSizeChange?(frame.size)
        }
    }

    private func payload(for sender: NSDraggingInfo) -> DraggingPayload? {
        let sequenceNumber = sender.draggingSequenceNumber
        if activeDraggingSequenceNumber != sequenceNumber {
            if activeDraggingSequenceNumber != nil {
                clearFileDrag()
            }
            activeDraggingSequenceNumber = sequenceNumber
            cachedDraggingPayload = nil
        }
        if cachedDraggingPayload == nil {
            cachedDraggingPayload = draggingPayload(from: sender)
        }
        return cachedDraggingPayload
    }

    private func fileDragLocationInStrip(for sender: NSDraggingInfo, sampledScreenLocation: NSPoint? = nil) -> NSPoint {
        let pointInContent: NSPoint
        if let window {
            // The sender may belong to the separate receiver below the Dock.
            // Convert its event sample through that window rather than mixing
            // it with a newer NSEvent.mouseLocation sample.
            let destinationWindow = sender.draggingDestinationWindow ?? window
            let screenLocation = sampledScreenLocation ?? destinationWindow.convertPoint(
                toScreen: sender.draggingLocation
            )
            let interactionLocation = fileDragRegionProvider?()?
                .interactionLocation(for: screenLocation) ?? screenLocation
            let pointInWindow = window.convertPoint(fromScreen: interactionLocation)
            pointInContent = convert(pointInWindow, from: nil)
        } else {
            pointInContent = convert(sender.draggingLocation, from: nil)
        }
        return stripView.convert(pointInContent, from: self)
    }

    private func resolvedDropDestination(
        at pointInStrip: NSPoint,
        usesHoverHysteresis: Bool = true
    ) -> DockDropDestination? {
        return stripView.dropDestination(
            at: pointInStrip,
            preservesTrashTarget: usesHoverHysteresis && dropDestination == .trash,
            preservesShortcutTarget: usesHoverHysteresis
                && (dropPlaceholderShortcutIndex != nil || dropDestination == .trash)
        )
    }

    private func dragOperation(
        for destination: DockDropDestination?,
        sourceMask: NSDragOperation
    ) -> NSDragOperation {
        switch destination {
        case .trash:
            if sourceMask.contains(.delete) { return .delete }
            if sourceMask.contains(.move) { return .move }
            if sourceMask.contains(.generic) { return .generic }
            // Some external file sources only advertise copy. The receiver
            // still performs the requested recycle through NSWorkspace.
            if sourceMask.contains(.copy) { return .copy }
            return []

        case .shortcuts:
            if sourceMask.contains(.copy) { return .copy }
            if sourceMask.contains(.move) { return .move }
            return []

        case nil:
            return []
        }
    }

    private func requestDestination(
        _ destination: DockDropDestination,
        sourceShortcutIDs: [UUID]
    ) -> DockDropDestination {
        guard case let .shortcuts(visibleIndex) = destination,
              isDraggedShortcutRemovedFromPresentation,
              !sourceShortcutIDs.isEmpty else {
            return destination
        }

        let originalIDs = snapshot.items.compactMap(\.kind.shortcutID)
        let movingIDs = Set(sourceShortcutIDs).intersection(originalIDs)
        guard !movingIDs.isEmpty else { return destination }

        let remainingIDs = originalIDs.filter { !movingIDs.contains($0) }
        let clampedVisibleIndex = min(max(0, visibleIndex), remainingIDs.count)
        guard clampedVisibleIndex < remainingIDs.count else {
            return .shortcuts(index: originalIDs.count)
        }

        let targetID = remainingIDs[clampedVisibleIndex]
        let originalIndex = originalIDs.firstIndex(of: targetID)
            ?? originalIDs.count
        return .shortcuts(index: originalIndex)
    }

    private func scheduleFileDragExit(for sender: NSDraggingInfo?) {
        let sequenceNumber = sender?.draggingSequenceNumber
            ?? activeDraggingSequenceNumber
        dragExitRevision &+= 1
        let revision = dragExitRevision
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.dragExitRevision == revision,
                  self.activeDraggingSequenceNumber == sequenceNumber else { return }
            guard !self.isPointerWithinDragBounds else { return }
            self.clearFileDrag()
        }
    }

    private var isPointerWithinDragBounds: Bool {
        if let region = fileDragRegionProvider?() {
            return region.contains(NSEvent.mouseLocation)
        }
        guard let window else { return false }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInContent = convert(pointInWindow, from: nil)
        return bounds.contains(pointInContent)
    }

    private func draggingPayload(from sender: NSDraggingInfo) -> DraggingPayload? {
        let pasteboard = sender.draggingPasteboard
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        let internalPayloads = pasteboardItems.compactMap { item -> DockInternalShortcutDrag? in
            guard let data = item.data(forType: .echoDockInternalShortcut) else { return nil }
            return try? JSONDecoder().decode(DockInternalShortcutDrag.self, from: data)
        }
        let readURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { object -> URL? in
            if let url = object as? URL { return url }
            if let url = object as? NSURL { return url as URL }
            return nil
        } ?? []
        let itemURLs = pasteboardItems.compactMap { item -> URL? in
            guard let value = item.string(forType: .fileURL) else { return nil }
            return URL(string: value)
        }
        var seenPaths = Set<String>()
        let urls = (internalPayloads.map(\.fileURL) + readURLs + itemURLs).compactMap { url -> URL? in
            guard url.isFileURL else { return nil }
            let normalized = url.standardizedFileURL
            return seenPaths.insert(normalized.path).inserted ? normalized : nil
        }
        guard !urls.isEmpty else { return nil }
        return DraggingPayload(
            fileURLs: urls,
            sourceShortcutIDs: internalPayloads.map(\.shortcutID)
        )
    }

    private func mergedDraggingPayload(
        preferred: DraggingPayload?,
        fallback: DraggingPayload?
    ) -> DraggingPayload? {
        guard preferred != nil || fallback != nil else { return nil }

        var seenPaths = Set<String>()
        let fileURLs = ((preferred?.fileURLs ?? []) + (fallback?.fileURLs ?? []))
            .filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
        guard !fileURLs.isEmpty else { return nil }

        var seenShortcutIDs = Set<UUID>()
        let sourceShortcutIDs = (
            (preferred?.sourceShortcutIDs ?? [])
                + (fallback?.sourceShortcutIDs ?? [])
        ).filter { seenShortcutIDs.insert($0).inserted }
        return DraggingPayload(
            fileURLs: fileURLs,
            sourceShortcutIDs: sourceShortcutIDs
        )
    }

    private static let dropPlaceholderItem = DockItem(
        identity: ApplicationIdentity(rawValue: "system:drop-placeholder"),
        bundleIdentifier: nil,
        applicationURL: URL(fileURLWithPath: "/dev/null"),
        displayName: "",
        section: .files,
        kind: .dropPlaceholder,
        isRunning: false,
        isActive: false,
        isHidden: false,
        transientState: .normal
    )

    private struct DraggingPayload {
        let fileURLs: [URL]
        let sourceShortcutIDs: [UUID]
    }

    private struct ShortcutDropHandoff {
        let baselineRevision: UInt64
        let baselineShortcutIDs: [UUID]
    }

    private struct ShortcutRemovalHandoff {
        let baselineRevision: UInt64
        let shortcutIDs: Set<UUID>
    }

    private func updatePreferredHeight(forMagnification isActive: Bool) {
        isMagnificationHeadroomActive = isActive
        updatePreferredHeight()
    }

    private func updatePreferredHeight() {
        let targetHeight = targetPreferredHeight
        guard abs(targetHeight - preferredHeight) > 0.01 else { return }

        preferredHeight = targetHeight
        guard !isFileDragActive else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }
        frame.size = position.layoutSize(for: NSSize(width: preferredWidth, height: targetHeight))
        needsLayout = true
        onPreferredSizeChange?(frame.size)
    }

    private func updatePreferredWidthFromStrip() {
        updateIconMetricsFromStrip()
        synchronizePreferredGeometry()
    }

    private var targetPreferredWidth: CGFloat {
        min(maxWidth, max(160, stripView.requiredWidth + 20))
    }

    private var targetPreferredHeight: CGFloat {
        dockBodyHeight + maximumActiveHeadroom
    }

    private var maximumActiveHeadroom: CGFloat {
        // Keep the screen-facing edge stable while magnifying at the other
        // three edges. Resizing this canvas mid-hover shifts the icons before
        // the panel can catch up, especially at the top and right edges.
        let magnificationHeadroom = ((position != .bottom && magnificationEnabled)
            || isMagnificationHeadroomActive) ? maximumMagnificationHeadroom : 0
        if isLaunchBounceActive {
            return max(magnificationHeadroom, maximumMagnificationHeadroom)
                + maximumLaunchBounceHeadroom
        }
        return magnificationHeadroom
    }

    private func updateBackgroundFrame() {
        guard bounds.width > 0 else { return }
        if !NSEqualRects(backgroundView.frame, bounds) {
            backgroundView.frame = bounds
        }
        let targetBodyFrame = resolvedBackgroundBodyFrame(
            for: backgroundInteraction.visualContentFrame
        )
        backgroundBodyFrame = targetBodyFrame
        backgroundView.setVisibleBodyFrame(targetBodyFrame)
    }

    private func resolvedBackgroundBodyFrame(for visualFrame: NSRect) -> NSRect {
        let backgroundHeight = min(dockBodyHeight, layoutSize.height)
        guard layoutSize.width > 0, visualFrame.width > 0, visualFrame.height > 0 else {
            return layoutPosition.viewRect(NSRect(
                x: 0,
                y: 0,
                width: layoutSize.width,
                height: backgroundHeight
            ), in: layoutSize)
        }

        let converted = layoutPosition.layoutRect(stripView.convert(visualFrame, to: self), in: layoutSize)
        var originX = converted.minX - DockInteractiveRegion.backgroundHorizontalPadding
        var width = converted.width + DockInteractiveRegion.backgroundHorizontalPadding * 2
        if originX < 0 {
            width += originX
            originX = 0
        }
        width = min(max(0, width), layoutSize.width - originX)
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        return DockBackgroundFrameAlignment.pixelAligned(
            layoutPosition.viewRect(NSRect(x: originX, y: 0, width: width, height: backgroundHeight), in: layoutSize),
            backingScaleFactor: scale
        )
    }

    private func updateBackgroundAppearance() {
        backgroundView.configure(
            transparency: backgroundTransparency,
            blurStrength: backgroundBlur,
            bodyHeight: dockBodyHeight,
            style: backgroundStyle
        )
    }

    private func updateBackgroundCornerRadius() {
        backgroundView.configure(
            transparency: backgroundTransparency,
            blurStrength: backgroundBlur,
            bodyHeight: dockBodyHeight,
            style: backgroundStyle
        )
    }
}
