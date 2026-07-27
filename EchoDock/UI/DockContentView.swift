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
        var effectiveAnimatedRemovalIdentities = animatedRemovalIdentities
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

        applyStrip(
            animatedInsertionIdentities: animatedInsertionIdentities,
            animatedRemovalIdentities: effectiveAnimatedRemovalIdentities
        )

        isLaunchBounceActive = stripView.isLaunchBounceAnimationActive
        preferredWidth = targetPreferredWidth
        preferredHeight = targetPreferredHeight
        frame.size = fileDragLockedSize
            ?? NSSize(width: preferredWidth, height: preferredHeight)
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
        let dockBodyFrame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: min(dockBodyHeight, bounds.height)
        )
        stripView.dockBodyFrame = convert(dockBodyFrame, to: stripView)
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
                backingScaleFactor: screen?.backingScaleFactor ?? window.backingScaleFactor
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
                if presented { self?.onTooltipPresentation?(nil) }
                self?.onContextMenuPresentationChange?(presented)
            },
            onHover: { [weak self] button, item in
                self?.updateTooltip(button: button, item: item)
            },
            magnificationEnabled: magnificationEnabled,
            magnificationScale: magnificationScale,
            magnificationRange: magnificationRange,
            iconSpacing: iconSpacing,
            animatedInsertionIdentities: insertionIdentities,
            animatedRemovalIdentities: animatedRemovalIdentities,
            reconfigureExistingItems: reconfigureExistingItems,
            launchBounceAnimationsEnabled: launchBounceAnimationsEnabled,
            runningIndicatorsEnabled: runningIndicatorsEnabled
        )
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
        setFileDragActive(true)
        let sourceShortcutIDs = Set(payload.sourceShortcutIDs)
        if sourceShortcutIDs != draggedShortcutIDs {
            draggedShortcutIDs = sourceShortcutIDs
            if case .shortcuts = dropDestination {
                applyStrip()
                stripView.layoutSubtreeIfNeeded()
            }
        }
        let pointInStrip = fileDragLocationInStrip(for: sender)
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

        NSMenu.popUpContextMenu(menu, with: event, for: self)
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
            let currentWidth = max(frame.width, max(preferredWidth, targetPreferredWidth))
            let reservedWidth = min(maxWidth, currentWidth + iconSize + iconSpacing)
            let lockedSize = NSSize(
                width: reservedWidth,
                height: max(
                    frame.height,
                    preferredHeight,
                    dockBodyHeight + maximumMagnificationHeadroom
                )
            )
            fileDragLockedSize = lockedSize
            frame.size = lockedSize
        } else {
            fileDragLockedSize = nil
            preferredWidth = targetPreferredWidth
            preferredHeight = targetPreferredHeight
            frame.size = NSSize(width: preferredWidth, height: preferredHeight)
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
        frame.size = NSSize(width: targetWidth, height: targetHeight)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if changed {
            onPreferredSizeChange?(NSSize(width: targetWidth, height: targetHeight))
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

    private func fileDragLocationInStrip(for sender: NSDraggingInfo) -> NSPoint {
        let pointInContent: NSPoint
        if let window {
            let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
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
        frame.size.height = targetHeight
        needsLayout = true
        onPreferredSizeChange?(NSSize(width: preferredWidth, height: targetHeight))
    }

    private func updatePreferredWidthFromStrip() {
        let targetWidth = targetPreferredWidth
        guard abs(targetWidth - preferredWidth) > 0.01 else { return }

        preferredWidth = targetWidth
        guard !isFileDragActive else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }
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
    var onBackgroundContextMenu: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onBackgroundContextMenu?(event)
    }

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
    var onBackgroundContextMenu: ((NSEvent) -> Void)?

    private var itemButtons: [ApplicationIdentity: DockItemButton] = [:]
    private var orderedButtons: [DockItemButton] = []
    private var separatorViews: [NSView] = []
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
    private var isTrashDropTargeted = false
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
    private var isFileDragActive = false
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
        pointerX = point.x
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
        runningIndicatorsEnabled: Bool = true
    ) {
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
        self.iconSize = iconSize
        self.magnificationEnabled = magnificationEnabled
        self.maximumMagnification = min(1.80, max(1.0, magnificationScale))
        self.magnificationRange = min(3.50, max(1.25, magnificationRange))
        self.iconSpacing = min(28, max(4, iconSpacing))
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
        guard point.x >= bounds.minX - 8,
              point.x <= bounds.maxX + 8 else { return nil }
        guard let trashButton = orderedButtons.first(where: { $0.item?.kind == .trash }) else {
            return nil
        }

        // Trash and the shortcut section share a hard horizontal boundary.
        // Hover hysteresis may grow to the right, but never left into the
        // shortcut insertion slot.
        let trashIconFrame = trashButton.iconFrame(in: self)
        let trashRightPadding: CGFloat = preservesTrashTarget ? 8 : 4
        let trashEntryMaxX = max(trashIconFrame.maxX, trashButton.frame.maxX)
            + trashRightPadding
        let trashEntryMinX = trashButton.frame.minX
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
        let bootstrapStart = trashButton.frame.minX - shortcutTargetWidth
        let fileSectionHysteresis = preservesShortcutTarget ? slotWidth / 2 + 4 : 0
        let existingFileSectionStart = fileButtons
            .map(\.frame.minX)
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
                button.frame.minX - max(0, slotWidth - button.frame.width) / 2
            }
        let fileSectionStart = min(
            bootstrapStart,
            existingFileSectionStart ?? bootstrapStart,
            placeholderSectionStart ?? bootstrapStart
        )
        guard point.x >= fileSectionStart,
              point.x < trashButton.frame.minX else {
            return nil
        }

        let insertionIndex = fileButtons.firstIndex { button in
            point.x < button.frame.midX
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
        let verticalBodyFrame = dockBodyFrame ?? NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: min(bounds.height, iconSize + 20)
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
            iconFrames: visibleIconFrames
        )
    }

    private func renderMagnification() {
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
            finalDocumentWidth: bounds.width,
            finalViewportWidth: enclosingScrollView?.contentSize.width ?? bounds.width
        )
        let layout = DockMagnificationLayout.make(
            itemCount: orderedButtons.count,
            pinnedItemCount: pinnedItemCount,
            separatorIndices: separatorIndices,
            iconSize: iconSize,
            spacing: iconSpacing,
            maximumScale: magnificationEnabled ? maximumMagnification : 1,
            influenceRange: magnificationRange,
            containerWidth: bounds.width,
            height: bounds.height,
            pointerX: magnificationEnabled
                ? pointerX.map { $0 - initialHorizontalOffset }
                : nil,
            magnificationProgress: magnificationTransition.value,
            itemPresenceProgresses: presenceValues,
            separatorPresenceProgress: separatorPresence
        )
        let horizontalOffset = initialHorizontalOffset

        visibleIconFrames.removeAll(keepingCapacity: true)
        var tooltipSlotFrames = Array<NSRect?>(
            repeating: nil,
            count: orderedButtons.count
        )
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
            let excludesTooltip = identity.map(removingIdentities.contains) ?? false
                || orderedButtons[index].item?.kind == .dropPlaceholder
            if !excludesTooltip {
                visibleIconFrames.append(iconFrame)
                tooltipSlotFrames[index] = targetFrame
            }
        }
        let verticalHoverBounds = dockBodyFrame.map { bounds.union($0) } ?? bounds
        tooltipHoverBounds = NSRect(
            x: bounds.minX,
            y: verticalHoverBounds.minY,
            width: bounds.width,
            height: verticalHoverBounds.height
        )
        tooltipHoverFrames = DockHoverResolver.hoverFrames(
            slotFrames: tooltipSlotFrames,
            in: tooltipHoverBounds
        )
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
        }
        for separatorView in separatorViews.dropFirst(layout.separatorFrames.count) {
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
